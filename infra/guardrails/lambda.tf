# The kill Lambda. It is the only thing in this stack that can actually stop money
# being spent, as opposed to telling somebody that it is being spent.
#
# Its role is scoped by a rule rather than by taste: every mutating action is
# restricted to the project's own resource, and reads are granted account-wide
# where the action's resource-level support is not something I could confirm from
# primary documentation. Reads cannot cost anything and a read that is denied by
# accident breaks the kill path, which is the failure this whole file exists to
# prevent.

data "archive_file" "kill" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/build/${local.name_prefix}-kill.zip"
}

data "aws_iam_policy_document" "kill_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.${local.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "kill" {
  name               = "${local.name_prefix}-kill"
  description        = "Execution role for the kill Lambda. Stops project compute and deletes the project's hourly resources; nothing else."
  assume_role_policy = data.aws_iam_policy_document.kill_trust.json
}

data "aws_iam_policy_document" "kill" {
  # Reads. None of these can create, modify or delete anything. Several of the
  # actions here (ec2:Describe*, eks:ListNodegroups) take no resource-level
  # permissions at all, and the handler is what narrows the result set: it
  # filters on the Project tag, on the configured cluster name, and on the
  # project VPCs.
  statement {
    sid    = "FindWhatIsRunning"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeNatGateways",
      "ec2:DescribeAddresses",
      "ec2:DescribeVpcs",
      "eks:DescribeCluster",
      "eks:ListNodegroups",
      "eks:DescribeNodegroup",
      "elasticloadbalancing:DescribeLoadBalancers",
      "scheduler:ListSchedules",
    ]
    resources = ["*"]
  }

  # The sweeper asks whether a one-shot window timer is still in the future
  # before it treats a node-less cluster as abandoned. Reading the timer is the
  # difference between collecting an orphan and deleting a cluster somebody is
  # in the middle of debugging.
  # https://docs.aws.amazon.com/scheduler/latest/UserGuide/security_iam_id-based-policy-examples.html
  statement {
    sid       = "ReadWindowTimers"
    effect    = "Allow"
    actions   = ["scheduler:GetSchedule"]
    resources = ["arn:${local.partition}:scheduler:*:${local.account_id}:schedule/${local.name_prefix}-windows/*"]
  }

  # Termination is scoped by the same tag the sweeper selects on, so a bug in the
  # handler cannot reach anything outside the project.
  statement {
    sid       = "TerminateProjectInstances"
    effect    = "Allow"
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:${local.partition}:ec2:*:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project_tag]
    }
  }

  # Scaling the managed node group to zero is what stops the Auto Scaling group
  # replacing the nodes that were just terminated, and it takes the Karpenter
  # controller down with the only nodes it can run on. Deleting the node group is
  # what lets the cluster be deleted afterwards.
  #
  # Both are scoped to the nodegroup ARN of one cluster. AWS documents
  # eks:DeleteNodegroup and eks:DescribeNodegroup against exactly this ARN shape;
  # eks:UpdateNodegroupConfig acts on the same nodegroup resource, but I could not
  # find a primary statement that it supports resource-level permissions, so it is
  # a window-0 drill case. If it turns out not to, the scale call comes back
  # AccessDenied, the handler records the failure and carries on to the node group
  # deletion, and the error alarm says so out loud.
  # https://docs.aws.amazon.com/step-functions/latest/dg/connect-eks.html
  statement {
    sid    = "StopProjectNodeGroups"
    effect = "Allow"
    actions = [
      "eks:UpdateNodegroupConfig",
      "eks:DeleteNodegroup",
    ]
    resources = ["arn:${local.partition}:eks:*:${local.account_id}:nodegroup/${var.cluster_name}/*/*"]
  }

  # The control plane hour. Scoped to the one cluster this project creates.
  statement {
    sid       = "DeleteProjectCluster"
    effect    = "Allow"
    actions   = ["eks:DeleteCluster"]
    resources = ["arn:${local.partition}:eks:*:${local.account_id}:cluster/${var.cluster_name}"]
  }

  # The NAT gateway hour and the in-use public IPv4 hour. These two are granted
  # account-wide because I could not confirm from primary documentation that
  # ec2:DeleteNatGateway and ec2:ReleaseAddress accept resource-level permissions,
  # and a condition on a key an action does not support is a deny in disguise:
  # the key would be absent, StringEquals would fail, and the kill path would
  # stop working in the one moment it matters. What scopes them instead is the
  # handler, which only ever passes IDs that came back from a describe filtered
  # on tag:Project. This is the one place in the stack where the code is the
  # boundary rather than IAM, and it is written down here for that reason.
  statement {
    sid    = "DeleteProjectNetworkCharges"
    effect = "Allow"
    actions = [
      "ec2:DeleteNatGateway",
      "ec2:ReleaseAddress",
    ]
    resources = ["*"]
  }

  # Load balancer hours. Both generations share the elasticloadbalancing prefix
  # and both ARNs begin with loadbalancer/, so one pattern covers a Kubernetes
  # Service's classic ELB and an application load balancer alike. It is scoped to
  # the account rather than to a tag on purpose: a load balancer created by a
  # Service carries the kubernetes.io tags and never the project tag, which is
  # why the handler selects on the project VPC instead.
  statement {
    sid       = "DeleteProjectLoadBalancers"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:DeleteLoadBalancer"]
    resources = ["arn:${local.partition}:elasticloadbalancing:*:${local.account_id}:loadbalancer/*"]
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.kill.arn}:*"]
  }
}

resource "aws_iam_role_policy" "kill" {
  name   = "${local.name_prefix}-kill"
  role   = aws_iam_role.kill.id
  policy = data.aws_iam_policy_document.kill.json
}

# No customer managed key. The log group holds instance IDs and counts, and a key the
# safety net depends on is one more thing that can be deleted out from under it.
#trivy:ignore:AWS-0017
resource "aws_cloudwatch_log_group" "kill" {
  name              = "/aws/lambda/${local.name_prefix}-kill"
  retention_in_days = var.log_retention_days
}

# X-Ray tracing is off deliberately: this function runs every few minutes for the life
# of the project, and tracing it would add cost to the thing whose job is to remove it.
#trivy:ignore:AWS-0066
resource "aws_lambda_function" "kill" {
  function_name = "${local.name_prefix}-kill"
  description   = "Stops project compute and deletes the project's hourly resources on a schedule, on a window timer, or on a spend alert."
  role          = aws_iam_role.kill.arn
  handler       = "handler.handler"
  runtime       = "python3.13"
  # A full stop is a dozen or so API calls per region and none of them are
  # waited on, so this is generous. It exists so that a slow control-plane
  # response cannot leave the job half done and then be retried from the top.
  timeout     = 120
  memory_size = 256

  filename         = data.archive_file.kill.output_path
  source_code_hash = data.archive_file.kill.output_base64sha256

  environment {
    variables = {
      PROJECT_TAG          = var.project_tag
      CLUSTER_NAME         = var.cluster_name
      WINDOW_GROUP         = aws_scheduler_schedule_group.windows.name
      REGIONS              = join(",", local.allowed_regions)
      MAX_AGE_MINUTES      = tostring(local.sweeper_max_age_minutes)
      ORPHAN_GRACE_MINUTES = tostring(var.orphan_grace_minutes)
      DRY_RUN              = var.kill_dry_run ? "true" : "false"
    }
  }

  depends_on = [
    aws_iam_role_policy.kill,
    aws_cloudwatch_log_group.kill,
  ]
}

# Every message on the topic is also a trigger, because the handler reads an SNS
# envelope as stop everything now without parsing it. That is why only the budget
# action and the two billing alarms publish there, and why the budget's
# informational notifications and the anomaly subscription do not. Adding a
# publisher to that topic is the same act as adding a teardown trigger.
resource "aws_lambda_permission" "alerts" {
  statement_id  = "AllowAlertTopicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.kill.function_name
  principal     = "sns.${local.dns_suffix}"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "kill" {
  provider = aws.billing

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.kill.arn

  depends_on = [aws_lambda_permission.alerts]
}

# ---------------------------------------------------------------------------
# Does the kill path still work?
#
# Nothing here publishes to the alert topic. That topic invokes the kill Lambda,
# so alarming on the kill Lambda's own failures into it would answer a broken
# teardown by asking the broken teardown to run again. These go to the notices
# topic in sns.tf, which has one email subscriber and no Lambda.

# Any invocation that raises. The handler raises only after it has attempted
# everything it could, so an error here means part of a stop did not happen.
resource "aws_cloudwatch_metric_alarm" "kill_errors" {
  alarm_name          = "${local.name_prefix}-kill-errors"
  alarm_description   = "The kill Lambda raised. Part of a stop did not happen; read /aws/lambda/${local.name_prefix}-kill and check for orphans before opening a window."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.kill.function_name
  }

  alarm_actions = [aws_sns_topic.notices.arn]
  ok_actions    = [aws_sns_topic.notices.arn]
}

resource "aws_cloudwatch_metric_alarm" "kill_throttles" {
  alarm_name          = "${local.name_prefix}-kill-throttles"
  alarm_description   = "The kill Lambda was throttled. The teardown it was asked to perform may not have run."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.kill.function_name
  }

  alarm_actions = [aws_sns_topic.notices.arn]
}

# The sweeper is the control that survives everything else, so silence from it is
# a failure. Missing data is breaching here because Lambda publishes no zero: a
# function that is never invoked produces no datapoints at all, which is exactly
# the state worth alarming on.
resource "aws_cloudwatch_metric_alarm" "sweeper_silent" {
  alarm_name          = "${local.name_prefix}-sweeper-silent"
  alarm_description   = "The kill Lambda has not been invoked often enough in the last two hours. The always-on sweeper is the last control; if it is not running, no window may open."
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  statistic           = "Sum"
  period              = 7200
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "LessThanThreshold"
  # Half the invocations two hours of the sweeper's interval should produce, so a
  # single skipped run is not an alarm and a stopped schedule is.
  threshold          = max(1, floor(120 / var.sweeper_interval_minutes / 2))
  treat_missing_data = "breaching"

  dimensions = {
    FunctionName = aws_lambda_function.kill.function_name
  }

  alarm_actions = [aws_sns_topic.notices.arn]
  ok_actions    = [aws_sns_topic.notices.arn]
}

# The dead-letter queue holds the events EventBridge Scheduler could not deliver
# after its retries. A message on it means a timer or a sweep was dropped.
resource "aws_cloudwatch_metric_alarm" "kill_dlq_not_empty" {
  alarm_name          = "${local.name_prefix}-kill-dlq-not-empty"
  alarm_description   = "A kill event is sitting on ${aws_sqs_queue.kill_dlq.name}. A scheduled teardown was dropped after its retries; assume nothing was stopped."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.kill_dlq.name
  }

  alarm_actions = [aws_sns_topic.notices.arn]
}
