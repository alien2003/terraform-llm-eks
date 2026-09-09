# The operator role, the permission boundary it carries, and the two policies
# attached to it.
#
# The boundary is the centre of the safety design. A permission boundary never
# grants anything: the effective permissions of the role are the intersection of
# its permissions policy and this boundary, and an explicit deny in either wins.
# So the boundary is written as a wide Allow surface plus narrow, specific Denies,
# and the Denies are the part that matters.
#
# Three policy documents, and the split between them is deliberate:
#
#   operator_boundary     the permission boundary. It constrains the operator AND
#                         every role the operator creates, because
#                         NewRolesMustCarryThisBoundary forces this same boundary
#                         onto each of them. A Deny belongs here when a role the
#                         operator creates during a normal build could otherwise
#                         reach the action: the EKS cluster role carries
#                         AmazonEKSClusterPolicy, the Karpenter controller role
#                         carries ec2:CreateFleet, ec2:RunInstances and
#                         ec2:CreateTags, and any of them could reach the safety
#                         net through the ceiling below.
#   operator_permissions  what the operator may do. Allow statements only.
#   operator_denies       Denies that only have to bind the operator itself,
#                         because the action is not inside the boundary's Allow
#                         ceiling at all and is therefore already an implicit deny
#                         for the operator and for every role it creates. Keeping
#                         them explicit means a later widening of the ceiling
#                         cannot hand them back by accident. This document exists
#                         because a customer managed policy is capped at 6,144
#                         characters and the boundary had run out of room; each of
#                         the three documents asserts its own rendered size in a
#                         plan-time precondition.
#
# Sources for every condition key used here:
#   ec2:InstanceType, ec2:InstanceMarketType (values capacity-block, on-demand, spot),
#     ec2:VolumeSize and ec2:VolumeIops (Numeric), ec2:VolumeType and
#     ec2:CreateAction (String), and the per-action, per-resource-type tables that
#     say which action evaluates which of them
#     https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html
#   RunInstances and CreateFleet do NOT evaluate the same keys. Both rows list
#     ec2:InstanceType on the instance resource type, so the whitelist covers both.
#     Only the RunInstances row lists ec2:InstanceMarketType; the CreateFleet
#     instance row is aws:RequestTag/${TagKey}, aws:TagKeys, ec2:AvailabilityZone,
#     ec2:AvailabilityZoneId, ec2:CpuOptionsAmdSevSnp, ec2:EbsOptimized,
#     ec2:InstanceBandwidthWeighting, ec2:InstanceID, ec2:InstanceProfile,
#     ec2:InstanceType, ec2:PlacementGroup, ec2:Region, ec2:RootDeviceType and
#     ec2:Tenancy, with no market key anywhere in it. A condition key an action
#     does not support is ignored, not honoured, so adding ec2:CreateFleet to
#     GpuSpotOnly would build a control that reads as enforcement and does
#     nothing. See ADR 0011 for what enforces Spot-only on the Karpenter path.
#   aws:TagKeys applies to ec2:CreateTags and ec2:DeleteTags as well as to the
#     resource-creating actions that support tagging
#     https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/supported-iam-actions-tagging.html
#   iam:PermissionsBoundary, and the NoBoundaryPolicyEdit pattern
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
#   iam:CreateRole offers aws:RequestTag/${TagKey}, aws:TagKeys,
#     iam:PermissionsBoundary, iam:ResourceTag/${TagKey} and iam:RoleTemplateARN,
#     and nothing that reads the trust policy in the request. ADR 0012 records
#     what is done about that instead.
#   eks:computeConfigEnabled is a Bool key on eks:CreateCluster and
#     eks:UpdateClusterConfig and is what turns EKS Auto Mode on. The EKS table
#     has no instance-type, capacity-type or scaling-size key at all, so
#     eks:CreateNodegroup and eks:UpdateNodegroupConfig cannot be size-filtered.
#     https://docs.aws.amazon.com/service-authorization/latest/reference/list_eks.html
#   sns:Subscribe, sns:SetSubscriptionAttributes and sns:Unsubscribe are all
#     authorized against the topic resource type, not a subscription resource
#     type, which is why the Deny that covers them is unscoped rather than
#     pointed at a subscription ARN.
#     https://docs.aws.amazon.com/service-authorization/latest/reference/list_sns.html
#   EventBridge Scheduler defines schedule and schedule-group as two separate
#     resource types, arn:...:schedule/${GroupName}/${ScheduleName} and
#     arn:...:schedule-group/${GroupName}. A Deny scoped to the group ARN does not
#     match an individual timer, which is why the window timer is constrained by
#     the shape of its own schedule ARN.
#     https://docs.aws.amazon.com/service-authorization/latest/reference/list_scheduler.html
#   freetier:UpgradeAccountPlan and the freetier read actions
#     https://docs.aws.amazon.com/service-authorization/latest/reference/list_freetier.html
#   organizations:DescribeOrganization is what tells you whether an SCP applies
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
#   AWS Control Tower service prefix controltower, IAM Identity Center prefix sso
#     https://docs.aws.amazon.com/service-authorization/latest/reference/list_controltower.html
#     https://docs.aws.amazon.com/service-authorization/latest/reference/list_iam-identity-center.html
#   EKS Pod Identity is a separate service, prefix eks-auth, one action. eks:* does not
#     reach it, and every role this operator creates carries this boundary, so the node
#     role cannot serve Pod Identity unless the action is inside the ceiling.
#     https://docs.aws.amazon.com/service-authorization/latest/reference/list_eks-auth.html
#   ec2:RequestSpotInstances has no instance resource type and no ec2:InstanceType
#     condition key, so the whitelist cannot be attached to it. It is denied outright.
#     https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html
#   arc-zonal-shift is deliberately NOT in the ceiling, and that removes one statement
#     from a pinned module. The karpenter submodule at 21.25.0 renders an
#     unconditional AllowZonalShiftReadActions granting
#     arc-zonal-shift:GetManagedResource to the controller role, that role carries
#     this boundary, and the intersection of the two is empty, so the action resolves
#     to an implicit deny. That is the intended outcome. Karpenter's own
#     documentation makes the permission useful only alongside the other half of the
#     feature: "Karpenter requires permissions to make arc-zonal-shift:GetManagedResource
#     calls and EKS Cluster must be enabled for Zonal Shift". This cluster does not
#     enable it - eks.tf passes no zonal_shift_config, the module gates the block on
#     that variable being non-null, and ADR 0034 pins the zones by GPU offering behind
#     a single NAT gateway, so there is no zonal shift for Karpenter to watch. The
#     action is a read: an implicit deny on it cannot fail a launch, an apply or a
#     teardown, it can only log AccessDenied in the controller. If zonal shift is ever
#     enabled on the cluster, admit the action to BuildSurface and re-check the size
#     precondition. ADR 0012 records the decision.
#     https://karpenter.sh/docs/concepts/scheduling/
#   gp3 delivers 3,000 IOPS as the baseline included in the price of storage, which
#     is the ceiling the volume bound uses
#     https://docs.aws.amazon.com/ebs/latest/userguide/general-purpose.html
#   A customer managed policy, which is what a permission boundary must be, is capped at
#     6,144 characters with whitespace excluded. All three documents here assert their
#     own rendered size in a precondition; see the bottom of this file.
#     https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html

locals {
  # The one-shot window timer is named llm-eks-window-<WINDOW_ID> inside the
  # llm-eks-windows group. Granting the schedule lifecycle against that shape
  # rather than against the whole group means the operator cannot park a
  # differently named schedule in the group where the audit would not look for it.
  window_timer_arns          = "arn:${local.partition}:scheduler:${var.region}:${local.account_id}:schedule/${local.name_prefix}-windows/${local.name_prefix}-window-*"
  window_group_schedule_arns = "arn:${local.partition}:scheduler:${var.region}:${local.account_id}:schedule/${local.name_prefix}-windows/*"

  # Third managed policy, attached alongside the permissions policy. It has to be
  # protected from the operator the same way the other two are: iam:DetachRolePolicy
  # is already denied because the operator role itself is protected, but
  # iam:CreatePolicyVersion plus iam:SetDefaultPolicyVersion would empty this
  # document out without ever touching the role.
  denies_policy_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${local.name_prefix}-operator-denies"

  guarded_iam_arns = concat(local.protected_iam_arns, [local.denies_policy_arn])

  # The failure-detection layer, by ARN. Built here rather than read off the
  # resources for the same reason as the ARNs in main.tf: every value the boundary
  # interpolates has to stay known at plan time, or the size precondition at the
  # bottom of this file cannot run before the window opens.
  #
  # The notices topic and the kill dead-letter queue live in var.region with the
  # Lambda and the four kill-path alarms. The two billing alarms live in us-east-1
  # with the metric. One wildcard covers all six alarms in both regions and costs
  # fewer characters than naming any two of them, and nothing else in this account
  # is called llm-eks-*: no alarm is created by the bootstrap stack, the cluster
  # stack, the platform layer or any chart in it.
  #
  # Resource ARN shapes from the authorization reference for each service:
  #   arn:${Partition}:sns:${Region}:${Account}:${TopicName}
  #   arn:${Partition}:sqs:${Region}:${Account}:${QueueName}
  #   arn:${Partition}:cloudwatch:${Region}:${Account}:alarm:${AlarmName}
  # https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonsns.html
  # https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonsqs.html
  # https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazoncloudwatch.html
  notices_topic_arn    = "arn:${local.partition}:sns:${var.region}:${local.account_id}:${local.name_prefix}-notices"
  kill_dlq_arn         = "arn:${local.partition}:sqs:${var.region}:${local.account_id}:${local.name_prefix}-kill-dlq"
  guardrail_alarm_arns = "arn:${local.partition}:cloudwatch:*:${local.account_id}:alarm:${local.name_prefix}-*"

  # The six alarms that wildcard has to cover, written out so that it can be
  # checked rather than believed. A wildcard that stops matching after a rename
  # fails silently and in the safe-looking direction: guard-status still reports
  # the alarm present, and nothing says the Deny no longer reaches it. The
  # precondition on aws_iam_policy.operator_boundary matches each of these against
  # the pattern at plan time. Every name is read from local.limits in main.tf,
  # which is the same list guard-status pulls out of SSM.
  safety_net_alarm_arns = concat(
    # The cumulative billing alarm. Its ARN is already built in main.tf.
    [local.billing_alarm_arn],
    # The burn-rate alarm sits beside it in us-east-1, with the billing metric.
    ["arn:${local.partition}:cloudwatch:us-east-1:${local.account_id}:alarm:${local.limits.billing_alarms.burn.name}"],
    # The four kill-path alarms live in var.region with the Lambda and the queue.
    [for name in local.limits.kill_path_alarms :
      "arn:${local.partition}:cloudwatch:${var.region}:${local.account_id}:alarm:${name}"
    ],
  )

  # What the two node volumes in this project actually are: 40 GiB gp3 for a system
  # node (infra/cluster system_node_disk_size) and 120 GiB gp3 for the GPU node
  # (infra/cluster/platform gpu_node_volume_size). Nothing here needs a provisioned
  # IOPS volume, an io2 volume or a volume larger than the GPU node's.
  volume_type_allowed  = "gp3"
  volume_max_size_gib  = 120
  volume_max_iops      = 3000
  volume_write_actions = ["ec2:CreateVolume", "ec2:ModifyVolume"]

  # The three EC2 resource types in this project that bill by the hour and are found
  # by tag: the nodes, their root volumes and the single NAT gateway. All three rows
  # of the CreateTags and DeleteTags tables list aws:TagKeys and
  # aws:RequestTag/${TagKey}, so the tag Denies below apply to all three.
  tagged_money_resources = [
    "arn:${local.partition}:ec2:*:*:instance/*",
    "arn:${local.partition}:ec2:*:*:natgateway/*",
    "arn:${local.partition}:ec2:*:*:volume/*",
  ]
}

# A permission boundary is a ceiling, not a grant. Naming services rather than
# individual actions is the point of the wide Allow below: the Deny statements after
# it, and the operator's own permissions policy, are what narrow it.
# s3:* is inside the ceiling on purpose: the only buckets that exist are the state
# bucket and the weights bucket, both created by this project. iam:PassRole is scoped
# to one role and one service by the condition on the statement that grants it.
#trivy:ignore:AWS-0345
#trivy:ignore:AWS-0342
data "aws_iam_policy_document" "operator_boundary" {
  # ---------------------------------------------------------------- allow surface

  statement {
    sid    = "BuildSurface"
    effect = "Allow"
    actions = [
      "application-autoscaling:*",
      # Reads only. An Auto Scaling group does not launch instances as the caller
      # that created it: it launches through the service-linked role
      # AWSServiceRoleForAutoScaling, which carries no permission boundary, so
      # InstanceTypeWhitelist, GpuSpotOnly and InstancesMustCarryProjectTag are
      # never evaluated for an ASG launch. The project needs no autoscaling write:
      # the cluster stack uses eks_managed_node_groups, whose Auto Scaling group is
      # created and owned by EKS itself, the eks module creates no
      # aws_autoscaling_* resource on that path, and the Karpenter controller
      # policy the karpenter submodule renders names no autoscaling action at all.
      # AmazonEKSClusterPolicy does carry autoscaling writes, and AWS documents
      # that they "aren't used by Amazon EKS but remain in the policy for backwards
      # compatibility", so leaving them outside this ceiling costs the cluster role
      # nothing.
      # https://docs.aws.amazon.com/eks/latest/userguide/security-iam-awsmanpol.html
      "autoscaling:Describe*",
      "cloudwatch:*",
      "ec2:*",
      "ecr:*",
      "eks:*",
      # EKS Pod Identity is served by eks-auth, not eks, and this is its only action.
      # ADR 0031/0041 make Pod Identity the credential mechanism, and every role the
      # operator creates inherits this boundary, so the node role needs it here.
      "eks-auth:AssumeRoleForPodIdentity",
      "elasticloadbalancing:*",
      "events:*",
      "iam:*",
      "kms:*",
      "logs:*",
      "s3:*",
      "secretsmanager:*",
      "sns:*",
      "sqs:*",
      "ssm:*",
      "sts:*",
      "tag:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadOnlyMoneyAndAccountVisibility"
    effect = "Allow"
    actions = [
      # guard-status has to be able to tell "not in an organization" apart from
      # "not allowed to ask". Without this the check is inconclusive forever.
      "organizations:DescribeOrganization",
      "freetier:GetAccountActivity",
      "freetier:GetAccountPlanState",
      "freetier:GetFreeTierUsage",
      "freetier:ListAccountActivities",
      "budgets:Describe*",
      "budgets:View*",
      "ce:Describe*",
      "ce:Get*",
      "ce:List*",
      "lambda:Get*",
      "lambda:List*",
      "pricing:Get*",
      "scheduler:Get*",
      "scheduler:List*",
      "servicequotas:Get*",
      "servicequotas:List*",
    ]
    resources = ["*"]
  }

  # The window tasks create and delete the one-shot kill timer. Nothing else in the
  # scheduler surface is granted, and scheduler:UpdateSchedule is deliberately not
  # in this list: a timer that can be edited in place can be postponed silently,
  # while one that can only be deleted and recreated leaves the audit path a
  # missing timer to notice. Nothing in scripts/ calls update-schedule.
  statement {
    sid    = "WindowTimerLifecycle"
    effect = "Allow"
    actions = [
      "scheduler:CreateSchedule",
      "scheduler:DeleteSchedule",
      "scheduler:TagResource",
      "scheduler:UntagResource",
    ]
    resources = [local.window_timer_arns]
  }

  # Redundant while iam:* is in the ceiling above, and deliberately kept: if that
  # ceiling is ever narrowed, the window tasks still need this one pass.
  statement {
    sid       = "PassSchedulerRoleToWindowTimer"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.scheduler_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["scheduler.${local.dns_suffix}"]
    }
  }

  # ---------------------------------------------------------------- the denies

  statement {
    sid    = "NoIdentityCreation"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:UpdateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
      "iam:CreateServiceSpecificCredential",
      "iam:ResetServiceSpecificCredential",
      "iam:UploadSigningCertificate",
    ]
    resources = ["*"]
  }

  # Rule 2a: the operator cannot weaken a guardrail. Every IAM write against the
  # boundary policy, the two policies attached to the operator role, the roles that
  # carry or execute the safety net, and the two identities above the operator is
  # denied outright. The action list is verb wildcards rather than the twenty
  # individual actions it replaces: scoped to nine named ARNs it denies strictly
  # more, it costs a third of the characters, and iam:PassRole, iam:Get* and
  # iam:List* are outside every one of them. iam:CreateServiceLinkedRole is also
  # outside, because a service-linked role ARN sits under role/aws-service-role/.
  statement {
    sid    = "NoGuardrailIamWrites"
    effect = "Deny"
    actions = [
      "iam:Attach*",
      "iam:Create*",
      "iam:Delete*",
      "iam:Detach*",
      "iam:Put*",
      "iam:Set*",
      "iam:Tag*",
      "iam:Untag*",
      "iam:Update*",
    ]
    resources = local.guarded_iam_arns
  }

  # A boundary cannot follow a role the operator creates, so the operator is made
  # to attach this same boundary to every role it creates. Without this statement
  # the whole design is one CreateRole away from an administrator.
  statement {
    sid    = "NewRolesMustCarryThisBoundary"
    effect = "Deny"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_policy_arn]
    }
  }

  statement {
    sid    = "NoBoundaryRemoval"
    effect = "Deny"
    actions = [
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "NoAdminAssumption"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = [local.admin_role_arn]
  }

  # The instance whitelist. Written as a Deny on everything outside the list rather
  # than an Allow of the list, so that a request with no instance type in it, or one
  # this policy has never heard of, is refused rather than permitted. StringNotEquals
  # is true when the key is absent, which is the direction that fails closed.
  # Both rows evaluate ec2:InstanceType on the instance resource type, so this one
  # statement covers the managed node group's launch path and Karpenter's.
  statement {
    sid    = "InstanceTypeWhitelist"
    effect = "Deny"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
    ]
    resources = ["arn:${local.partition}:ec2:*:*:instance/*"]

    condition {
      test     = "StringNotEquals"
      variable = "ec2:InstanceType"
      values   = local.allowed_instance_types
    }
  }

  # GPU capacity is Spot only. ec2:InstanceMarketType takes capacity-block, on-demand
  # or spot; the negated test also catches a request that carries no market at all.
  #
  # ec2:CreateFleet is absent from this statement on purpose, and that is the one
  # place in this stack where the rule the project states is wider than the rule IAM
  # can hold. The CreateFleet row of the EC2 authorization reference does not list
  # ec2:InstanceMarketType on any of its seven resource types, and an unsupported
  # condition key is ignored rather than enforced, so naming CreateFleet here would
  # produce a statement that passes a policy simulation and stops nothing. Karpenter
  # launches through CreateFleet. What actually keeps the GPU pool on Spot is the
  # "Running On-Demand G and VT instances" quota, held at a target of 0 in
  # var.quota_targets and re-checked by guard-status at window open, plus the
  # NodePool's own capacityTypes. ADR 0011 has the whole reasoning.
  statement {
    sid       = "GpuSpotOnly"
    effect    = "Deny"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:${local.partition}:ec2:*:*:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:InstanceType"
      values   = var.gpu_instance_types
    }

    condition {
      test     = "StringNotEquals"
      variable = "ec2:InstanceMarketType"
      values   = ["spot"]
    }
  }

  # An instance without the Project tag is invisible to the sweeper and to the audit
  # task, which both select on it. That is a worse failure than a launch that fails.
  dynamic "statement" {
    for_each = var.enforce_instance_project_tag ? [1] : []

    content {
      sid    = "InstancesMustCarryProjectTag"
      effect = "Deny"
      actions = [
        "ec2:RunInstances",
        "ec2:CreateFleet",
      ]
      resources = ["arn:${local.partition}:ec2:*:*:instance/*"]

      condition {
        test     = "StringNotEquals"
        variable = "aws:RequestTag/Project"
        values   = [var.project_tag]
      }
    }
  }

  # Forcing the tag on at launch is cosmetic unless it also cannot come off
  # afterwards: the sweeper's describe filter, the kill role's aws:ResourceTag
  # condition and every resource query in the audit select on Project, so one
  # delete-tags call makes a running instance unkillable by anything but the
  # administrator. Stack is included because the audit reports on it.
  # Nothing in this project removes either tag: the tags come from the provider's
  # default_tags block, so Terraform sets them on create and leaves them alone,
  # and no policy the operator creates carries ec2:DeleteTags at all.
  statement {
    sid       = "NoProjectTagRemoval"
    effect    = "Deny"
    actions   = ["ec2:DeleteTags"]
    resources = local.tagged_money_resources

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "aws:TagKeys"
      values   = ["Project", "Stack"]
    }
  }

  # ec2:DeleteTags with no Tags parameter at all deletes every user-defined tag on the
  # resource, and then aws:TagKeys is not in the request context, so the ForAnyValue
  # test above is false and denies nothing. Null with a value of true is the test for
  # "this key is absent", which is exactly that call and nothing else: every
  # DeleteTags a person or a provider issues on purpose names the keys it is removing.
  statement {
    sid       = "NoBlanketTagWipe"
    effect    = "Deny"
    actions   = ["ec2:DeleteTags"]
    resources = local.tagged_money_resources

    condition {
      test     = "Null"
      variable = "aws:TagKeys"
      values   = ["true"]
    }
  }

  # Repointing the key is the same bypass as removing it. The condition pair is
  # what keeps this from breaking a normal apply, and the order matters: the first
  # test is true only when Project is one of the keys in the request, the second
  # only when the value it is being set to is not this project's. Both have to hold,
  # so a create-time tag set of {Project, Stack, ManagedBy, Name}, a tag update that
  # rewrites Project to the value it already has, and any CreateTags that does not
  # mention Project at all are all untouched. Karpenter's own tagging is untouched
  # twice over: its create-time statement carries the NodeClass tags, Project among
  # them at this value, and its post-launch statement is capped by
  # ForAllValues:aws:TagKeys to eks:eks-cluster-name, karpenter.sh/nodeclaim and Name.
  statement {
    sid       = "NoProjectTagRepoint"
    effect    = "Deny"
    actions   = ["ec2:CreateTags"]
    resources = local.tagged_money_resources

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "aws:TagKeys"
      values   = ["Project"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.project_tag]
    }
  }

  # An instance type is fixed at launch as far as this account is concerned.
  # Resizing a stopped t3.medium into something enormous would walk straight around
  # the launch whitelist, and neither call is needed to build the cluster.
  statement {
    sid    = "NoResizeOrRelocate"
    effect = "Deny"
    actions = [
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyInstancePlacement",
    ]
    resources = ["*"]
  }

  # Capacity that is bought rather than rented: commitments, reservations, dedicated
  # hosts and Spot fleets all bill outside the launch path the whitelist covers.
  statement {
    sid    = "NoCommittedOrReservedSpend"
    effect = "Deny"
    actions = [
      "ec2:AcceptReservedInstancesExchangeQuote",
      "ec2:AllocateHosts",
      "ec2:CreateCapacityReservation",
      "ec2:CreateCapacityReservationBySplitting",
      "ec2:CreateCapacityReservationFleet",
      "ec2:CreateReservedInstancesListing",
      "ec2:ModifyReservedInstances",
      "ec2:Purchase*",
      "ec2:RunScheduledInstances",
    ]
    resources = ["*"]
  }

  # The launch paths the whitelist cannot filter. ec2:RequestSpotInstances acts on
  # image, key-pair, network-interface, placement-group, security-group, snapshot,
  # spot-instances-request and subnet: there is no instance resource type in its row
  # and ec2:InstanceType does not appear in it at all, so no condition can express the
  # whitelist for it. Scoping to spot-instances-request would not close it either,
  # because that resource is not evaluated when the request carries no tags on create.
  # The project launches only through the managed node group (RunInstances) and
  # Karpenter (CreateFleet), so both legacy Spot request APIs are denied outright.
  statement {
    sid    = "NoUnfilterableLaunchPath"
    effect = "Deny"
    actions = [
      "ec2:RequestSpotFleet",
      "ec2:RequestSpotInstances",
    ]
    resources = ["*"]
  }

  # EKS Auto Mode is a third way to reach running instances without the operator
  # calling an EC2 launch action: EKS provisions the nodes itself, so none of the
  # three launch Denies above is ever evaluated. It is switched on by the cluster's
  # compute config, and eks:computeConfigEnabled is the Bool key for exactly that
  # parameter on both the create and the update call. The cluster stack passes no
  # compute_config at all (the module's default is null), so the key is absent from
  # the legitimate request and a Bool test against absent does not match: this Deny
  # cannot fire on the window-1 apply.
  statement {
    sid    = "NoEksAutoModeCompute"
    effect = "Deny"
    actions = [
      "eks:CreateCluster",
      "eks:UpdateClusterConfig",
    ]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "eks:computeConfigEnabled"
      values   = ["true"]
    }
  }

  # The safety net itself. Three services that are inside the ceiling above need an
  # explicit Deny here to bind a role the operator creates as well as the operator:
  # sns:*, sqs:* and cloudwatch:*. lambda and scheduler writes are not in the
  # ceiling at all, so they are already implicitly denied for the operator and for
  # every role it creates; their explicit Denies live in operator_denies below.
  #
  # Everything the safety net is made of is named here, not only the parts that
  # raise the alarm. The alert topic and the two billing alarms are the spend
  # signal; the notices topic, the kill dead-letter queue and the four kill-path
  # alarms are the layer that says the kill path itself has stopped working, and a
  # layer nobody is denied is a layer the operator can delete while guard-status
  # keeps reporting green.
  #
  # sns:Publish is on this list because publishing to the alert topic IS a
  # teardown: the kill Lambda is subscribed to it and reads any envelope as stop
  # everything now, so one `aws sns publish` would scale the node groups to zero
  # and delete the hourly resources. Nothing in this project publishes to either
  # topic as an IAM principal - the budget action and both billing alarms publish
  # as service principals through the topic policy in sns.tf, which is a separate
  # evaluation this Deny does not touch.
  #
  # sqs:SetQueueAttributes is the quiet way to break the dead-letter queue: it
  # rewrites the queue policy and the retention period without deleting anything.
  # It is denied only on the DLQ, because the Karpenter interruption queue is a
  # different queue and the cluster stack's destroy calls SetQueueAttributes on it.
  statement {
    sid    = "NoSafetyNetTampering"
    effect = "Deny"
    actions = [
      "sns:AddPermission",
      "sns:DeleteTopic",
      "sns:Publish",
      "sns:RemovePermission",
      "sns:SetTopicAttributes",
      "sqs:DeleteQueue",
      "sqs:SetQueueAttributes",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DisableAlarmActions",
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:SetAlarmState",
    ]
    resources = [
      local.alert_topic_arn,
      local.notices_topic_arn,
      local.kill_dlq_arn,
      local.guardrail_alarm_arns,
    ]
  }

  # Deleting the topic is the loud way to break the alert path. The quiet way is a
  # filter policy: SetSubscriptionAttributes with AttributeName=FilterPolicy on the
  # kill Lambda's subscription drops every message, because Budgets, CloudWatch and
  # Cost Anomaly notifications carry no message attributes for a filter to match.
  # The topic still exists, the subscriptions still show as confirmed, and nothing
  # is ever invoked. Subscribe is here for the other direction: a new subscriber on
  # the topic that fans messages somewhere the author does not read.
  # Unscoped rather than pointed at the topic because all three actions authorize
  # against the topic resource type while the ARN a caller passes is a subscription
  # ARN, and because no stack outside this one creates an SNS subscription at all,
  # so there is nothing legitimate to deny.
  statement {
    sid    = "NoAlertSubscriptionTampering"
    effect = "Deny"
    actions = [
      "sns:SetSubscriptionAttributes",
      "sns:Subscribe",
      "sns:Unsubscribe",
    ]
    resources = ["*"]
  }

  # A resource in a region nobody looks at is a resource nobody turns off. Global
  # services are excluded because they carry no meaningful requested region.
  statement {
    sid    = "RegionLock"
    effect = "Deny"
    not_actions = [
      "budgets:*",
      "ce:*",
      "cloudfront:*",
      "freetier:*",
      "health:*",
      "iam:*",
      "organizations:*",
      "pricing:*",
      "route53:*",
      "sts:*",
      "support:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = local.allowed_regions
    }
  }
}

resource "aws_iam_policy" "operator_boundary" {
  name        = "${local.name_prefix}-operator-boundary"
  description = "Permission boundary for the operator role. Changing it requires the administrator profile."
  policy      = data.aws_iam_policy_document.operator_boundary.json

  # A boundary has to be a customer managed policy and a customer managed policy is
  # capped at 6,144 characters with whitespace excluded. Nothing in the local quality
  # bar renders or measures a policy body: fmt, validate, tflint and trivy all pass on
  # an oversized document and the failure only surfaces at apply time as
  # LimitExceeded. That is the one moment this stack must not fail, so the size is
  # asserted here instead. Every value the document interpolates is built from the
  # account ID and the partition in main.tf rather than read from a resource, which is
  # what keeps this checkable during `terraform plan`.
  lifecycle {
    precondition {
      condition     = length(replace(data.aws_iam_policy_document.operator_boundary.json, "/\\s/", "")) <= 6144
      error_message = "The operator boundary exceeds the 6,144 character managed-policy limit, whitespace excluded. Move Deny statements whose actions are outside the boundary's own Allow ceiling into the operator_denies document, which is where the rest of them already are."
    }

    # NoSafetyNetTampering names the alarms by wildcard. This is what says the
    # wildcard still reaches every one of them.
    precondition {
      condition = alltrue([
        for arn in local.safety_net_alarm_arns :
        length(regexall("^${replace(local.guardrail_alarm_arns, "*", ".*")}$", arn)) > 0
      ])
      error_message = "NoSafetyNetTampering no longer covers every alarm the safety net depends on. The pattern is ${local.guardrail_alarm_arns} and the alarms are ${join(", ", local.safety_net_alarm_arns)}. An alarm outside the pattern can be deleted by the operator with ordinary permissions, and guard-status will keep reporting it present until the moment it is needed."
    }
  }
}

# The operator's own permissions. A boundary only subtracts, so without this the role
# can do nothing at all. The narrowing lives in the boundary above; repeating it here
# would mean two places to get it wrong, and only one of them is the one an auditor
# reads. Same two acceptances as the boundary document, for the same reasons.
#trivy:ignore:AWS-0345
#trivy:ignore:AWS-0342
data "aws_iam_policy_document" "operator_permissions" {
  statement {
    sid    = "Build"
    effect = "Allow"
    actions = [
      "application-autoscaling:*",
      # Reads only, for the reason spelled out in the boundary's BuildSurface.
      "autoscaling:Describe*",
      "cloudwatch:*",
      "ec2:*",
      "ecr:*",
      "eks:*",
      # EKS Pod Identity is served by eks-auth, not eks, and this is its only action.
      # ADR 0031/0041 make Pod Identity the credential mechanism, and every role the
      # operator creates inherits this boundary, so the node role needs it here.
      "eks-auth:AssumeRoleForPodIdentity",
      "elasticloadbalancing:*",
      "events:*",
      "iam:*",
      "kms:*",
      "logs:*",
      "s3:*",
      "secretsmanager:*",
      "sns:*",
      "sqs:*",
      "ssm:*",
      "sts:*",
      "tag:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadMoneyAndQuotas"
    effect = "Allow"
    actions = [
      "budgets:Describe*",
      "budgets:View*",
      "ce:Describe*",
      "ce:Get*",
      "ce:List*",
      "freetier:GetAccountActivity",
      "freetier:GetAccountPlanState",
      "freetier:GetFreeTierUsage",
      "freetier:ListAccountActivities",
      "lambda:Get*",
      "lambda:List*",
      "organizations:DescribeOrganization",
      "pricing:Get*",
      "scheduler:Get*",
      "scheduler:List*",
      "servicequotas:Get*",
      "servicequotas:List*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "WindowTimerLifecycle"
    effect = "Allow"
    actions = [
      "scheduler:CreateSchedule",
      "scheduler:DeleteSchedule",
      "scheduler:TagResource",
      "scheduler:UntagResource",
    ]
    resources = [local.window_timer_arns]
  }

  statement {
    sid       = "PassSchedulerRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.scheduler_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["scheduler.${local.dns_suffix}"]
    }
  }
}

resource "aws_iam_policy" "operator_permissions" {
  name        = "${local.name_prefix}-operator-permissions"
  description = "What the operator may do, before the boundary subtracts from it."
  policy      = data.aws_iam_policy_document.operator_permissions.json

  # Same 6,144 character limit, same reason for asserting it here.
  lifecycle {
    precondition {
      condition     = length(replace(data.aws_iam_policy_document.operator_permissions.json, "/\\s/", "")) <= 6144
      error_message = "The operator permissions policy exceeds the 6,144 character managed-policy limit, whitespace excluded. Split it into a further managed policy and attach that to the role as well."
    }
  }
}

# The Denies that only have to bind the operator itself.
#
# Every action named below is outside the boundary's Allow ceiling, so it is already
# an implicit deny for the operator and for every role the operator creates: the
# ceiling grants only organizations:DescribeOrganization, budgets:Describe*/View*,
# ce:Describe*/Get*/List*, servicequotas:Get*/List*, lambda:Get*/List*, four freetier
# reads and, for scheduler, Get*/List* plus create and delete on the window timer's
# own ARN shape. Keeping them here as explicit Denies means a future widening of the
# permissions policy cannot hand any of them back by accident. If the boundary's
# ceiling is ever widened to include one of these services, move the matching
# statement back into the boundary, because only the boundary reaches the roles the
# operator creates.
data "aws_iam_policy_document" "operator_denies" {
  # Any of these expires the Free Tier credits the moment it succeeds, so all three
  # service surfaces are closed. organizations:DescribeOrganization is deliberately
  # absent from this list: it is allowed above, and an explicit Deny would win.
  statement {
    sid    = "NoOrganizationsControlTowerOrIdentityCenter"
    effect = "Deny"
    actions = [
      "controltower:*",
      "identitystore:*",
      "organizations:Accept*",
      "organizations:Attach*",
      "organizations:Cancel*",
      "organizations:Close*",
      "organizations:Create*",
      "organizations:Decline*",
      "organizations:Delete*",
      "organizations:Deregister*",
      "organizations:Detach*",
      "organizations:Disable*",
      "organizations:Enable*",
      "organizations:Invite*",
      "organizations:Leave*",
      "organizations:Move*",
      "organizations:Put*",
      "organizations:Register*",
      "organizations:Remove*",
      "organizations:Tag*",
      "organizations:Untag*",
      "organizations:Update*",
      "sso-directory:*",
      "sso:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "NoBudgetWrites"
    effect = "Deny"
    actions = [
      "budgets:Create*",
      "budgets:Delete*",
      "budgets:Execute*",
      "budgets:Modify*",
      "budgets:Update*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "NoServiceQuotaWrites"
    effect = "Deny"
    actions = [
      "servicequotas:Associate*",
      "servicequotas:Create*",
      "servicequotas:Delete*",
      "servicequotas:Disassociate*",
      "servicequotas:Put*",
      "servicequotas:Request*",
      "servicequotas:Update*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "NoAnomalyDetectionWrites"
    effect = "Deny"
    actions = [
      "ce:Create*",
      "ce:Delete*",
      "ce:Update*",
    ]
    resources = ["*"]
  }

  # freetier:UpgradeAccountPlan is a Write action that converts the account to a Paid
  # plan. Phase 0 found it missing from the original specification.
  statement {
    sid       = "NoFreeTierPlanUpgrade"
    effect    = "Deny"
    actions   = ["freetier:UpgradeAccountPlan"]
    resources = ["*"]
  }

  statement {
    sid       = "NoSavingsPlanPurchase"
    effect    = "Deny"
    actions   = ["savingsplans:Create*"]
    resources = ["*"]
  }

  # The rest of the safety net. The kill function and the always-on sweeper are
  # named directly. The window schedule group is named twice on purpose: the
  # schedule-group ARN is what a group-level call carries, and the schedule ARNs
  # under it are what an individual timer carries, and those are two different
  # resource types. scheduler:UpdateSchedule on the timers is what stops a live
  # window from being postponed rather than closed; the operator can still delete
  # its timer, which is the call `mise run down` makes and the one an audit that
  # expects a timer to exist can notice the absence of.
  statement {
    sid    = "NoKillPathTampering"
    effect = "Deny"
    actions = [
      "lambda:Add*",
      "lambda:Create*",
      "lambda:Delete*",
      "lambda:Put*",
      "lambda:Remove*",
      "lambda:Update*",
      "scheduler:DeleteScheduleGroup",
      "scheduler:UpdateSchedule",
    ]
    resources = [
      local.kill_function_arn,
      local.sweeper_schedule_arn,
      local.window_group_arn,
      local.window_group_schedule_arns,
    ]
  }

  statement {
    sid       = "NoSweeperScheduleDeletion"
    effect    = "Deny"
    actions   = ["scheduler:DeleteSchedule"]
    resources = [local.sweeper_schedule_arn]
  }

  # An EBS volume is the most expensive thing per API call that the ceiling permits,
  # and the one hourly-priced resource the safety net cannot remove: the kill role
  # holds ec2:DescribeInstances and ec2:TerminateInstances and nothing else, and the
  # audit sees a volume only if it carries the Project tag, which CreateVolume is
  # under no obligation to set. So the bound is on the call. Three statements rather
  # than one because conditions inside a statement are ANDed, and what is wanted is
  # "denied if the type is wrong OR the volume is too big OR the IOPS are provisioned",
  # which is three separate matches.
  #
  # Nothing in this project calls either action: the system node's 40 GiB root volume
  # and the GPU node's 120 GiB root volume are both block device mappings inside a
  # launch template, which authorize against the volume resource type of RunInstances
  # and CreateFleet, not against ec2:CreateVolume. There is no EBS CSI driver in the
  # addon set and ADR 0044 keeps no persistent volume, so no PersistentVolumeClaim
  # path reaches CreateVolume either. These are in this document rather than in the
  # boundary for that reason. If a CSI driver is ever added, the EKS cluster role
  # carries volume permissions through AmazonEKSClusterPolicy, and then these three
  # statements have to move into the boundary and the size bound has to be re-checked
  # against the largest claim the cluster is allowed to make.
  statement {
    sid       = "VolumeTypeMustBeGp3"
    effect    = "Deny"
    actions   = local.volume_write_actions
    resources = ["arn:${local.partition}:ec2:*:*:volume/*"]

    condition {
      test     = "StringNotEquals"
      variable = "ec2:VolumeType"
      values   = [local.volume_type_allowed]
    }
  }

  statement {
    sid       = "VolumeSizeCeiling"
    effect    = "Deny"
    actions   = local.volume_write_actions
    resources = ["arn:${local.partition}:ec2:*:*:volume/*"]

    condition {
      test     = "NumericGreaterThan"
      variable = "ec2:VolumeSize"
      values   = [local.volume_max_size_gib]
    }
  }

  statement {
    sid       = "NoProvisionedIops"
    effect    = "Deny"
    actions   = local.volume_write_actions
    resources = ["arn:${local.partition}:ec2:*:*:volume/*"]

    condition {
      test     = "NumericGreaterThan"
      variable = "ec2:VolumeIops"
      values   = [local.volume_max_iops]
    }
  }
}

resource "aws_iam_policy" "operator_denies" {
  name        = "${local.name_prefix}-operator-denies"
  description = "Denies that only have to bind the operator role itself, not the roles it creates."
  policy      = data.aws_iam_policy_document.operator_denies.json

  # Same 6,144 character limit, same reason for asserting it here.
  lifecycle {
    precondition {
      condition     = length(replace(data.aws_iam_policy_document.operator_denies.json, "/\\s/", "")) <= 6144
      error_message = "The operator denies policy exceeds the 6,144 character managed-policy limit, whitespace excluded. Split it into a further managed policy and attach that to the role as well."
    }
  }
}

data "aws_iam_policy_document" "operator_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.base_user_arn]
    }
  }
}

resource "aws_iam_role" "operator" {
  name                 = "${local.name_prefix}-operator"
  description          = "The only identity used for cloud work outside window 0 and the final teardown step."
  assume_role_policy   = data.aws_iam_policy_document.operator_trust.json
  permissions_boundary = aws_iam_policy.operator_boundary.arn
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "operator" {
  role       = aws_iam_role.operator.name
  policy_arn = aws_iam_policy.operator_permissions.arn
}

resource "aws_iam_role_policy_attachment" "operator_denies" {
  role       = aws_iam_role.operator.name
  policy_arn = aws_iam_policy.operator_denies.arn
}
