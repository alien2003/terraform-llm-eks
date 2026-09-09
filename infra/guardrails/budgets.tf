# The budget watches gross spend with credits excluded.
#
# This account holds Free Tier credits and the project treats credits as cash, so
# a budget that netted them off would read zero right up to the moment the credits
# ran out. cost_types.include_credit = false is what expresses that: AWS documents
# cost budgets as able to "either include or exclude refunds, credits, upfront
# reservation fees, recurring reservation charges, non-reservation subscription
# costs, taxes, and support charges".
# https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html
# https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_budgets_CostTypes.html
#
# Whether Budgets observes gross pre-credit usage on a Free Plan account is still an
# open question (STATE.md, open question 2). Until it is answered the sweeper and the
# one-shot window timer are the controls that actually stop spend, and the budget is
# a second opinion.
#
# The two signal paths are kept apart on purpose. Everything published to
# llm-eks-alerts invokes the kill Lambda, and the Lambda reads any SNS envelope as
# stop everything now. So a percentage notification sent to that topic is not a
# notification at all, it is a teardown: with the default limit and percentages,
# gross spend crossing 25 dollars would have killed a running window without anybody
# asking for it and without the action at 120 dollars ever firing. The informational
# thresholds therefore go straight to the email subscriber, and the only publishers
# left on the topic are the three signals that do mean stop now: the budget action,
# the cumulative billing alarm in ALARM state, and the burn-rate alarm. The cost
# anomaly subscription used to be on it too and is now an email digest, for the
# reason at the top of anomaly.tf.
# https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-sns-policy.html

resource "aws_budgets_budget" "gross_spend" {
  provider = aws.billing

  name         = "${local.name_prefix}-gross-spend"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit             = false
    include_refund             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_subscription       = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    use_amortized              = false
    use_blended                = false
  }

  # Informational, to the human, never to the topic. Read the comment at the top of
  # this file before adding subscriber_sns_topic_arns to any of these.
  dynamic "notification" {
    for_each = toset(var.budget_notification_percentages)

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }

  # A forecast is a prediction, so it is informational for the same reason.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  # A notification with no subscriber is not a notification. Budgets needs at least
  # one subscriber per notification and these deliberately do not use the topic, so
  # the apply fails loudly rather than silently dropping the informational tier.
  lifecycle {
    precondition {
      condition     = var.alert_email != ""
      error_message = "alert_email is required: the budget percentage and forecast notifications are delivered to it directly, because the alert topic invokes the kill Lambda and must carry only signals that mean stop spending now."
    }
  }
}

# The automatic action. It attaches this policy to the operator role at the action
# threshold, which stops the account from growing while somebody works out what
# happened. Only the administrator can take it back off: the boundary denies the
# operator iam:DetachRolePolicy against its own role.
#
# It used to be Deny on Action "*", and that was worse than the problem it solved.
# The things that grow the account at that point are an Auto Scaling group, the EKS
# control plane and the Karpenter controller role, none of which is the operator.
# What a blanket deny actually stopped was the only identity that can run
# `terraform destroy`, `mise run down` and `mise run audit` - it covered the reads
# too, so even the audit that Rule 2b makes the only permitted activity failed. A
# spending problem became a spending problem that could not be fixed without
# uncommenting the admin profile, while the meter kept running.
#
# So this is a Deny with NotAction: everything is denied except the reads and the
# deletes that the teardown path and the pre-flight checks need. Creating anything
# is gone - RunInstances, CreateFleet, CreateVolume, CreateCluster, CreateNodegroup,
# CreateRole, PassRole, CreateBucket are all on the denied side, so the account
# cannot grow. Destroying everything is not.
#
# The list is a ceiling on damage, not a grant: the permissions policy and the
# boundary still apply, and the intersection is what the operator can do.
#
# Twice now this list has been short by one service, and both times it was found by
# reading it rather than by checking it, which is the same as not finding it. So the
# list below is no longer the only artefact. local.teardown_api_calls enumerates the
# API operations the paths this policy has to leave open actually issue, and the
# precondition on aws_iam_policy.budget_stop fails the plan, by name, for any call
# this document would deny. Adding a resource to a stack now means adding its calls
# to that list, and a NotAction entry that never gets written stops the plan instead
# of stopping the teardown.

locals {
  # What the operator issues while the stop policy is attached. Three paths, and the
  # frame matters as much as the list:
  #
  #   1. `terraform destroy` of infra/cluster, which is `mise run down`. This is
  #      where every hourly charge lives, so it is the path that must not fail.
  #   2. `mise run audit` and `mise run guard-status`, which Rule 2b makes the only
  #      permitted activity while something is wrong, plus the state access every
  #      Terraform run needs.
  #   3. the deletes in infra/bootstrap that cannot grow the account.
  #
  # Two things are deliberately outside the frame. Deleting the state bucket is not
  # here and s3:DeleteBucket is not in the NotAction list: an S3 bucket carries no
  # hourly charge, and removing the state bucket while the account is stopped would
  # remove the ability to destroy anything else. `mise run guard-drill` is not here
  # either: iam:SimulatePrincipalPolicy rehearses the boundary before a window opens,
  # and a window does not open while this policy is attached.
  #
  # The check this list feeds is one-directional. Every call here must be covered;
  # an extra NotAction entry that cannot create a billable resource is allowed to
  # stay. That is the direction the failure runs in: a false denial strands the
  # author with a running cluster, and that is the failure this is guarding.
  #
  # Operation names come from each service's own API reference. Where a name is a
  # provider implementation detail rather than a documented call - the tag reads on
  # refresh - the covering NotAction entry is a verb wildcard, so an SDK that renames
  # ListTagsLogGroup to ListTagsForResource does not silently open a hole.
  teardown_api_calls = [
    # Identity, and Terraform state in the S3 backend with a lock file.
    "sts:AssumeRole",
    "sts:GetCallerIdentity",

    # scripts/guard-status.sh: the credit-preservation check. Enumerated here so the
    # coverage precondition below fails the plan if the NotAction list ever stops
    # permitting it.
    "organizations:DescribeOrganization",
    "s3:ListBucket",
    "s3:GetObject",
    "s3:PutObject",
    "s3:DeleteObject",

    # module.vpc: the VPC, its subnets, the single NAT gateway and its Elastic IP,
    # the route tables, the security groups and the S3 gateway endpoint.
    "ec2:DescribeVpcs",
    "ec2:DescribeVpcAttribute",
    "ec2:DeleteVpc",
    "ec2:DescribeSubnets",
    "ec2:DeleteSubnet",
    "ec2:DescribeInternetGateways",
    "ec2:DetachInternetGateway",
    "ec2:DeleteInternetGateway",
    "ec2:DescribeNatGateways",
    "ec2:DeleteNatGateway",
    "ec2:DescribeAddresses",
    "ec2:DisassociateAddress",
    "ec2:ReleaseAddress",
    "ec2:DescribeRouteTables",
    "ec2:DisassociateRouteTable",
    "ec2:DeleteRoute",
    "ec2:DeleteRouteTable",
    "ec2:DescribeSecurityGroups",
    "ec2:DescribeSecurityGroupRules",
    "ec2:RevokeSecurityGroupIngress",
    "ec2:RevokeSecurityGroupEgress",
    "ec2:DeleteSecurityGroup",
    "ec2:DescribeVpcEndpoints",
    "ec2:DeleteVpcEndpoints",
    "ec2:DescribeFlowLogs",
    "ec2:DeleteFlowLogs",
    "ec2:DescribeTags",

    # module.eks: the control plane, the managed node group and its launch
    # template, the addons, the access entries and the log group. The access
    # policy association is the one that is neither a Delete nor a Describe.
    "eks:DescribeCluster",
    "eks:DeleteCluster",
    "eks:ListNodegroups",
    "eks:DescribeNodegroup",
    "eks:DeleteNodegroup",
    "eks:ListAddons",
    "eks:DescribeAddon",
    "eks:DeleteAddon",
    "eks:ListAccessEntries",
    "eks:DescribeAccessEntry",
    "eks:DeleteAccessEntry",
    "eks:ListAssociatedAccessPolicies",
    "eks:DisassociateAccessPolicy",
    "ec2:DescribeLaunchTemplates",
    "ec2:DescribeLaunchTemplateVersions",
    "ec2:DeleteLaunchTemplate",
    "logs:DescribeLogGroups",
    "logs:ListTagsForResource",
    "logs:DeleteLogGroup",

    # module.karpenter: the interruption queue with its policy, the five Spot
    # interruption rules and their targets, and the Pod Identity association.
    "sqs:GetQueueUrl",
    "sqs:GetQueueAttributes",
    "sqs:ListQueueTags",
    "sqs:SetQueueAttributes",
    "sqs:DeleteQueue",
    "events:DescribeRule",
    "events:ListTargetsByRule",
    "events:ListTagsForResource",
    "events:RemoveTargets",
    "events:DeleteRule",
    "eks:ListPodIdentityAssociations",
    "eks:DescribePodIdentityAssociation",
    "eks:DeletePodIdentityAssociation",

    # Every role, policy, instance profile and OIDC provider the cluster stack and
    # the platform layer create. No iam:Create and no iam:Attach: a destroy only
    # ever detaches and deletes.
    "iam:GetRole",
    "iam:ListRolePolicies",
    "iam:ListAttachedRolePolicies",
    "iam:ListInstanceProfilesForRole",
    "iam:DeleteRolePolicy",
    "iam:DetachRolePolicy",
    "iam:DeleteRole",
    "iam:GetPolicy",
    "iam:ListPolicyVersions",
    "iam:DeletePolicyVersion",
    "iam:DeletePolicy",
    "iam:GetInstanceProfile",
    "iam:RemoveRoleFromInstanceProfile",
    "iam:DeleteInstanceProfile",
    "iam:GetOpenIDConnectProvider",
    "iam:DeleteOpenIDConnectProvider",

    # The cluster stack's cross-stack SSM parameters.
    "ssm:GetParameters",
    "ssm:DescribeParameters",
    "ssm:ListTagsForResource",
    "ssm:DeleteParameter",

    # infra/bootstrap. The buckets themselves are not destroyed on this path; see
    # the note about s3:DeleteBucket above.
    "ecr:DescribePullThroughCacheRules",
    "ecr:DeletePullThroughCacheRule",
    "ecr:DescribeRepositoryCreationTemplates",
    "ecr:DeleteRepositoryCreationTemplate",
    "ecr:DescribeRepositories",
    "ecr:DescribeImages",
    "ecr:BatchDeleteImage",
    "secretsmanager:DescribeSecret",
    "secretsmanager:DeleteSecret",

    # `mise run audit`: what is still running, what still bills, and the one write
    # it prescribes as a fix.
    "ec2:DescribeInstances",
    "ec2:DescribeVolumes",
    "elasticloadbalancing:DescribeLoadBalancers",
    "elasticloadbalancing:DescribeTags",
    "tag:GetResources",
    "s3:ListAllMyBuckets",
    "logs:PutRetentionPolicy",

    # `mise run guard-status`: every guardrail, and the money.
    "cloudwatch:DescribeAlarms",
    "cloudwatch:DescribeAlarmHistory",
    "cloudwatch:ListMetrics",
    "budgets:DescribeBudget",
    "budgets:DescribeBudgetActionsForBudget",
    "ce:GetAnomalyMonitors",
    "ce:GetAnomalySubscriptions",
    "ce:GetCostAndUsage",
    "freetier:GetAccountPlanState",
    "freetier:GetFreeTierUsage",
    "freetier:ListAccountActivities",
    "servicequotas:GetServiceQuota",
    "servicequotas:ListServiceQuotas",
    "lambda:GetFunction",
    "sns:GetTopicAttributes",
    "sns:ListSubscriptionsByTopic",

    # `mise run down` disarms the one-shot window timer after a clean audit.
    "scheduler:GetSchedule",
    "scheduler:GetScheduleGroup",
    "scheduler:ListSchedules",
    "scheduler:DeleteSchedule",
  ]

  # The NotAction list as IAM will see it, read back out of the rendered document
  # rather than out of a second copy of it. An IAM policy wildcard is a `*` standing
  # for any run of characters, so turning each entry into an anchored regular
  # expression is what "does this pattern cover this call" means. `replace` treats
  # its second argument as a literal string unless it is written between slashes, so
  # the `*` being replaced here is the character, not a repetition operator.
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_notaction.html
  budget_stop_not_actions = jsondecode(data.aws_iam_policy_document.budget_stop.json).Statement[0].NotAction

  budget_stop_uncovered = [
    for call in local.teardown_api_calls : call
    if !anytrue([
      for pattern in local.budget_stop_not_actions :
      length(regexall("^${replace(pattern, "*", ".*")}$", call)) > 0
    ])
  ]
}

data "aws_iam_policy_document" "budget_stop" {
  statement {
    sid       = "DenyEverythingExceptTeardownAndReads"
    effect    = "Deny"
    resources = ["*"]

    not_actions = [
      # Assume the role and prove who you are.
      "sts:*",
      # Terraform state: read it, write it back after a destroy, take and release
      # the S3 lock file.
      "s3:Get*",
      "s3:List*",
      "s3:PutObject",
      "s3:DeleteObject",
      # Read anything, delete what the operator created. No Create, no Modify, no
      # Run, no Request, no Purchase.
      "ec2:Describe*",
      "ec2:Get*",
      "ec2:Delete*",
      "ec2:Terminate*",
      "ec2:Release*",
      "ec2:Disassociate*",
      "ec2:Detach*",
      "ec2:Revoke*",
      # eks:Disassociate* is not decoration. Destroying an
      # aws_eks_access_policy_association calls eks:DisassociateAccessPolicy, and
      # the operator's own cluster-admin access entry is one of those, so without
      # this the cluster stack cannot be destroyed at all.
      "eks:Describe*",
      "eks:Disassociate*",
      "eks:List*",
      "eks:Delete*",
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:Delete*",
      "autoscaling:Describe*",
      "autoscaling:Delete*",
      # The EventBridge rules and targets the karpenter submodule creates for Spot
      # interruption handling. Five rules and five targets, and a destroy reads
      # each rule and its tags, removes the target and deletes the rule.
      "events:Describe*",
      "events:List*",
      "events:Delete*",
      "events:Remove*",
      # logs:List* is the tag read on a log group refresh; without it the refresh
      # that precedes the destroy fails before it deletes anything.
      # logs:PutRetentionPolicy is the one write here that is not a delete: it is
      # the fix `mise run audit` prints for a log group with no retention, and
      # Rule 2b makes fixing what the audit reports the only permitted activity.
      # It cannot create anything.
      "logs:Describe*",
      "logs:Get*",
      "logs:List*",
      "logs:Delete*",
      "logs:PutRetentionPolicy",
      # ssm:List* for the same reason as logs:List*: the parameter refresh reads
      # ssm:ListTagsForResource.
      "ssm:Describe*",
      "ssm:Get*",
      "ssm:List*",
      "ssm:Delete*",

      # organizations:DescribeOrganization is guard-status's credit-preservation
      # check: the account joining an organization expires the Free Tier credits, and
      # the check cannot distinguish "not in one" from "not allowed to ask". While the
      # stop policy is attached, Rule 2b makes fixing the overspend the only permitted
      # activity, and that starts with running guard-status. A read that answers a
      # question about the credits must not be the thing the overspend policy blocks.
      "organizations:Describe*",
      "secretsmanager:Describe*",
      "secretsmanager:Get*",
      "secretsmanager:List*",
      "secretsmanager:Delete*",
      "ecr:Describe*",
      "ecr:Get*",
      "ecr:List*",
      "ecr:Delete*",
      "ecr:BatchDelete*",
      # Destroying aws_sqs_queue_policy on the Karpenter interruption queue calls
      # sqs:SetQueueAttributes with an empty policy, before the queue itself goes.
      # The kill dead-letter queue is protected from it separately: the boundary
      # denies both sqs:SetQueueAttributes and sqs:DeleteQueue on that one queue
      # by ARN, and a Deny in the boundary beats an absence of Deny here.
      "sqs:Get*",
      "sqs:List*",
      "sqs:Receive*",
      "sqs:Delete*",
      "sqs:SetQueueAttributes",
      "kms:Describe*",
      "kms:List*",
      # IAM: read, and delete or detach what the operator created. Create and
      # attach stay denied, so no new identity and no new permission.
      "iam:Get*",
      "iam:List*",
      "iam:Delete*",
      "iam:Detach*",
      "iam:Remove*",
      # `mise run down` disarms the one-shot window timer after a clean audit.
      "scheduler:*",
      # The pre-flight and the audit: guard-status, audit and the cost review are
      # the activities Rule 2b permits while something is wrong.
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "lambda:Get*",
      "lambda:List*",
      "sns:Get*",
      "sns:List*",
      "budgets:Describe*",
      "budgets:View*",
      "ce:Describe*",
      "ce:Get*",
      "ce:List*",
      "freetier:Get*",
      "freetier:List*",
      "servicequotas:Get*",
      "servicequotas:List*",
      "tag:Get*",
    ]
  }
}

resource "aws_iam_policy" "budget_stop" {
  name        = "${local.name_prefix}-budget-stop"
  description = "Attached to the operator role by the budget action when gross spend crosses the action threshold. Denies everything except the reads and deletes the teardown path needs."
  policy      = data.aws_iam_policy_document.budget_stop.json

  # A customer managed policy is capped at 6,144 characters with whitespace
  # excluded, and nothing in the local quality bar measures that: the only thing
  # that objects is the apply, with LimitExceeded. Same assertion as the three
  # policies in iam_operator.tf, for the same reason.
  #
  # The second precondition is the one that stops this list going stale. It fails
  # the plan, naming the calls, if the NotAction list would deny anything on the
  # teardown, audit or pre-flight path. Both run during `terraform plan`, because
  # every value they read is a literal.
  lifecycle {
    precondition {
      condition     = length(replace(data.aws_iam_policy_document.budget_stop.json, "/\\s/", "")) <= 6144
      error_message = "The budget stop policy is over IAM's 6,144-character managed-policy limit with whitespace excluded. Shorten the NotAction list before applying."
    }

    precondition {
      condition     = length(local.budget_stop_uncovered) == 0
      error_message = "The budget stop policy would deny calls the teardown path makes: ${join(", ", local.budget_stop_uncovered)}. Once this policy is attached only the administrator can detach it, so a call missing from the NotAction list is a cluster that bills and cannot be destroyed. Add a NotAction entry covering each one, or take it out of local.teardown_api_calls and say in the comment why that path no longer runs."
    }
  }
}

data "aws_iam_policy_document" "budget_action_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["budgets.${local.dns_suffix}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "budget_action" {
  name               = "${local.name_prefix}-budget-action"
  description        = "Assumed by AWS Budgets to apply and reverse the stop policy on the operator role."
  assume_role_policy = data.aws_iam_policy_document.budget_action_trust.json
}

data "aws_iam_policy_document" "budget_action" {
  statement {
    sid    = "AttachAndDetachStopPolicy"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = [aws_iam_role.operator.arn]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = [aws_iam_policy.budget_stop.arn]
    }
  }

  statement {
    sid    = "ReadWhatItChanges"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetRole",
      "iam:ListAttachedRolePolicies",
    ]
    resources = [
      aws_iam_role.operator.arn,
      aws_iam_policy.budget_stop.arn,
    ]
  }
}

resource "aws_iam_role_policy" "budget_action" {
  name   = "${local.name_prefix}-budget-action"
  role   = aws_iam_role.budget_action.id
  policy = data.aws_iam_policy_document.budget_action.json
}

resource "aws_budgets_budget_action" "stop_operator" {
  provider = aws.billing

  budget_name        = aws_budgets_budget.gross_spend.name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action.arn

  action_threshold {
    action_threshold_type  = "ABSOLUTE_VALUE"
    action_threshold_value = var.budget_action_threshold_usd
  }

  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.budget_stop.arn
      roles      = [aws_iam_role.operator.name]
    }
  }

  subscriber {
    address           = aws_sns_topic.alerts.arn
    subscription_type = "SNS"
  }

  depends_on = [aws_sns_topic_policy.alerts]
}
