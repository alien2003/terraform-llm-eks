# Providers, shared data sources and locals for the money-safety stack.

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# Cost Explorer and the AWS/Billing metric namespace only exist in us-east-1: billing
# metric data is stored there and represents worldwide charges, so the alarm on it has
# to live there too. AWS Budgets is a global service reached at budgets.amazonaws.com
# rather than a us-east-1 regional endpoint; it is placed on this same aliased provider
# only so that the budget, its action and the alert topic stay together with the alarm.
# https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/monitor_estimated_charges_with_cloudwatch.html
# https://docs.aws.amazon.com/cost-management/latest/userguide/ce-api.html
# https://docs.aws.amazon.com/general/latest/gr/billing.html
provider "aws" {
  alias  = "billing"
  region = "us-east-1"

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  tags = {
    Project   = var.project_tag
    Stack     = "guardrails"
    ManagedBy = "terraform"
  }

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix

  name_prefix = "llm-eks"

  # Every instance type the boundary will let the operator launch, in any market.
  allowed_instance_types = concat(var.system_instance_types, var.gpu_instance_types)

  # ARNs the boundary refers to by name. They are built rather than referenced so
  # that the boundary document does not depend on the resources it protects, which
  # would be a cycle: the role carries the boundary, the boundary names the role.
  operator_role_arn    = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-operator"
  admin_role_arn       = "arn:${local.partition}:iam::${local.account_id}:role/${var.admin_role_name}"
  base_user_arn        = "arn:${local.partition}:iam::${local.account_id}:user/${var.base_user_name}"
  boundary_policy_arn  = "arn:${local.partition}:iam::${local.account_id}:policy/${local.name_prefix}-operator-boundary"
  operator_policy_arn  = "arn:${local.partition}:iam::${local.account_id}:policy/${local.name_prefix}-operator-permissions"
  budget_stop_arn      = "arn:${local.partition}:iam::${local.account_id}:policy/${local.name_prefix}-budget-stop"
  kill_role_arn        = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-kill"
  budget_role_arn      = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-budget-action"
  scheduler_role_arn   = "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-scheduler"
  kill_function_arn    = "arn:${local.partition}:lambda:${var.region}:${local.account_id}:function:${local.name_prefix}-kill"
  sweeper_schedule_arn = "arn:${local.partition}:scheduler:${var.region}:${local.account_id}:schedule/default/${local.name_prefix}-sweeper"
  window_group_arn     = "arn:${local.partition}:scheduler:${var.region}:${local.account_id}:schedule-group/${local.name_prefix}-windows"
  billing_alarm_arn    = "arn:${local.partition}:cloudwatch:us-east-1:${local.account_id}:alarm:${local.name_prefix}-estimated-charges"

  # Built rather than read from aws_sns_topic.alerts.arn for the same reason as the
  # ARNs above, plus one more: it keeps every value in the boundary document known at
  # plan time, which is what lets the policy-size precondition in iam_operator.tf fail
  # during `terraform plan` instead of part-way through the window-0 apply. The topic
  # is created by the aws.billing provider, so the region is us-east-1.
  alert_topic_arn = "arn:${local.partition}:sns:us-east-1:${local.account_id}:${local.name_prefix}-alerts"

  # Roles and policies whose modification would weaken the guardrail. The operator
  # is denied every IAM write against this list.
  protected_iam_arns = [
    local.operator_role_arn,
    local.admin_role_arn,
    local.base_user_arn,
    local.boundary_policy_arn,
    local.operator_policy_arn,
    local.budget_stop_arn,
    local.kill_role_arn,
    local.budget_role_arn,
    local.scheduler_role_arn,
  ]

  # Regions the operator may touch. Global services are excluded from the region
  # lock separately, in the boundary document. The kill Lambda is given the same
  # list, because a control that terminates instances in one region while the
  # boundary permits two is blind in exactly the region a mis-set AWS_REGION
  # lands things in.
  allowed_regions = distinct([var.region, "us-east-1"])

  # The sweeper's age threshold is derived, never set by hand. It has to be
  # longer than the longest window the approval form can grant, or the always-on
  # sweeper terminates a cluster that somebody is legitimately using; and the
  # only way to guarantee that permanently is to compute one from the other.
  sweeper_max_age_minutes = var.max_window_hours * 60 + var.sweeper_age_margin_minutes

  # Published to SSM so that the scripts read the guardrail's own numbers rather
  # than carrying copies. See the second half of quotas.tf.
  limits = {
    max_window_hours           = var.max_window_hours
    sweeper_max_age_minutes    = local.sweeper_max_age_minutes
    sweeper_interval_minutes   = var.sweeper_interval_minutes
    sweeper_age_margin_minutes = var.sweeper_age_margin_minutes
    orphan_grace_minutes       = var.orphan_grace_minutes
    kill_regions               = local.allowed_regions
    kill_function_name         = "${local.name_prefix}-kill"
    kill_dlq_name              = "${local.name_prefix}-kill-dlq"
    notices_topic_name         = "${local.name_prefix}-notices"
    # Built rather than read off the resources, for the same reason as the ARNs
    # above: every value in this parameter stays known at plan time.
    # https://docs.aws.amazon.com/general/latest/gr/aws-arns-and-namespaces.html
    kill_dlq_arn      = "arn:${local.partition}:sqs:${var.region}:${local.account_id}:${local.name_prefix}-kill-dlq"
    notices_topic_arn = "arn:${local.partition}:sns:${var.region}:${local.account_id}:${local.name_prefix}-notices"
    sms_enabled       = var.alert_phone != ""
    kill_path_alarms = [
      "${local.name_prefix}-kill-errors",
      "${local.name_prefix}-kill-throttles",
      "${local.name_prefix}-kill-dlq-not-empty",
      "${local.name_prefix}-sweeper-silent",
    ]
    billing_alarms = {
      cumulative = {
        name      = "${local.name_prefix}-estimated-charges"
        threshold = var.billing_alarm_threshold_usd
        semantics = "Month-to-date total on AWS/Billing EstimatedCharges. Rises only, so it crosses at most once per calendar month and then stays in ALARM until the month rolls over. ALARM means gross spend has crossed the threshold at some point this month, not that it is crossing now. Treat as a warning with the month-to-date figure unless it entered ALARM since the last closed window in materials/costs/windows.md, which describe-alarm-history --history-item-type StateUpdate answers."
      }
      burn = {
        name      = "${local.name_prefix}-burn-rate"
        threshold = var.billing_burn_threshold_usd
        semantics = "DIFF of the same metric over one six-hour period: dollars added since the previous datapoint. Can fire repeatedly and resets on its own, so ALARM here means spend is being added now. Treat as a failure and do not open a window."
      }
    }
  }
}
