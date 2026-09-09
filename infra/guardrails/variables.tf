variable "region" {
  description = "Region the operator is allowed to work in. Never hardcoded elsewhere; the region is still provisional."
  type        = string
  default     = "us-east-1"
}

variable "project_tag" {
  description = "Value of the Project tag. The sweeper, the audit task and the boundary all select on it."
  type        = string
  default     = "terraform-llm-eks"
}

variable "cluster_name" {
  description = <<-EOT
    Name of the EKS cluster the cluster stack creates. Fixed by the project contract. The kill
    Lambda addresses the cluster and its managed node groups by this name, and its IAM policy is
    scoped to those two ARNs, so a change here has to be made in both stacks at once.
  EOT
  type        = string
  default     = "llm-eks"
}

variable "admin_role_name" {
  description = "Name of the pre-existing administrator role. Not managed here; the boundary only refers to it."
  type        = string
  default     = "llm-eks-admin"
}

variable "base_user_name" {
  description = "Name of the pre-existing base IAM user that assumes the project roles. Not managed here."
  type        = string
  default     = "llm-eks-human"
}

variable "gpu_instance_types" {
  description = "GPU instance types the operator may launch. Spot only; on-demand launches of these are denied."
  type        = list(string)
  default     = ["g6.xlarge", "g6.2xlarge"]
}

variable "system_instance_types" {
  description = "System instance types for the managed node group. Either market."
  type        = list(string)
  default     = ["t3.medium", "m7i.large"]
}

variable "enforce_instance_project_tag" {
  description = <<-EOT
    Require every instance launch to carry the Project tag, so that nothing the operator
    starts is invisible to the sweeper and to the audit task. Turning this off leaves the
    safety net blind to untagged instances.
  EOT
  type        = bool
  default     = true
}

variable "alert_email" {
  description = <<-EOT
    Email address for every alert. Required: it is subscribed to the alert topic and it is
    also the direct subscriber of the budget's informational percentage and forecast
    notifications, which are deliberately kept off the topic because the topic invokes the
    kill Lambda. The apply fails with an explanation if it is empty.
  EOT
  type        = string
  default     = ""
}

variable "alert_phone" {
  description = <<-EOT
    E.164 phone number subscribed to the alert topic for SMS, for example +15550100. Empty, which
    is the default, means no SMS subscription is created and the email subscriber is the only path.

    SMS needs work outside Terraform before it delivers anything. A new account is in the SNS SMS
    sandbox, where a message reaches only destination numbers that have been added and verified;
    an unverified number receives nothing and the subscription still looks healthy, because an SMS
    subscription gets a real ARN with no confirmation handshake. So before setting this, verify the
    number with `aws sns create-sms-sandbox-phone-number --phone-number <E.164>` followed by
    `aws sns verify-sms-sandbox-phone-number --phone-number <E.164> --one-time-password <code>`,
    check `aws sns list-sms-sandbox-phone-numbers` reads Verified, and then set
    alert_sms_sandbox_verified to true. The plan refuses to create the subscription until you do.
    https://docs.aws.amazon.com/sns/latest/dg/sns-sms-sandbox.html
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.alert_phone == "" || can(regex("^\\+[1-9][0-9]{7,14}$", var.alert_phone))
    error_message = "alert_phone must be empty or an E.164 number: a plus sign, a country code and 8 to 15 digits in total."
  }
}

variable "alert_sms_sandbox_verified" {
  description = <<-EOT
    Set to true only once alert_phone has been verified in the SNS SMS sandbox, or once the account
    has been moved out of the sandbox. It is a hand-checked acknowledgement rather than something
    Terraform can prove, and its only job is to stop the stack from creating a subscription that
    would silently deliver nothing while guard-status reported two confirmed subscribers.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = var.alert_phone == "" || var.alert_sms_sandbox_verified
    error_message = "alert_phone is set but alert_sms_sandbox_verified is false. An SMS subscription to an unverified number in the SNS SMS sandbox delivers nothing and still looks confirmed, so the plan stops here: verify the number, or clear alert_phone and rely on the email subscriber."
  }
}

variable "budget_limit_usd" {
  description = "Monthly gross-spend budget in USD, credits excluded. Confirm with the author before the first apply."
  type        = number
  default     = 100
}

variable "budget_notification_percentages" {
  description = <<-EOT
    Percentages of the budget at which an actual-spend notification is emailed to alert_email.
    These are informational and are not delivered to the alert topic: every message on that
    topic invokes the kill Lambda, so a notification there would terminate the cluster at the
    first threshold rather than tell anybody about it. The thresholds that do stop spend are
    billing_alarm_threshold_usd and budget_action_threshold_usd.
  EOT
  type        = list(number)
  default     = [25, 50, 80, 100]
}

variable "budget_action_threshold_usd" {
  description = "Gross spend in USD at which the budget action attaches the deny policy to the operator role."
  type        = number
  default     = 120
}

variable "billing_alarm_threshold_usd" {
  description = <<-EOT
    Threshold in USD for the cumulative CloudWatch alarm on AWS/Billing EstimatedCharges. The
    metric is month-to-date and only rises within a month, so this alarm can cross once per
    calendar month and then stays in ALARM until the month rolls over. Read the header comment in
    billing_alarm.tf before treating it as a live signal.
  EOT
  type        = number
  default     = 60
}

variable "billing_burn_threshold_usd" {
  description = <<-EOT
    Dollars of gross spend added inside a single six-hour period, above which the burn-rate alarm
    fires. This is the half of the billing signal that can fire more than once a month: it alarms
    on DIFF of the same month-to-date metric, so it reads the change rather than the total.

    It has to sit above the whole of a deliberately approved window and below the monthly budget,
    or it becomes either useless or a teardown of work somebody asked for. Confirm it with the
    author before the first apply, the same as budget_limit_usd.
  EOT
  type        = number
  default     = 25
}

variable "anomaly_threshold_usd" {
  description = <<-EOT
    Absolute dollar impact at or above which a cost anomaly is emailed to alert_email. This is an
    informational path, not a teardown trigger, which is why the number is allowed to be small
    enough that a deliberate GPU window trips it: on an account whose baseline is zero, the first
    real window is an anomaly, and being told about it is useful. The thresholds that stop spend
    are billing_alarm_threshold_usd, billing_burn_threshold_usd and budget_action_threshold_usd.
  EOT
  type        = number
  default     = 10
}

variable "max_window_hours" {
  description = <<-EOT
    Longest cloud window the approval protocol can grant. This is the single source of truth for
    that number: the sweeper's age threshold is derived from it, and `mise run up` reads it out of
    the SSM parameter this stack publishes rather than carrying its own copy. They used to be set
    by hand in two places and disagreed by a factor of two, which meant the always-on sweeper
    terminated the cluster at the four-hour mark of an approved eight-hour window.
  EOT
  type        = number
  default     = 8

  validation {
    condition     = var.max_window_hours > 0 && var.max_window_hours <= 24
    error_message = "max_window_hours must be greater than 0 and no more than 24."
  }
}

variable "sweeper_interval_minutes" {
  description = "How often the always-on sweeper runs."
  type        = number
  default     = 15
}

variable "sweeper_age_margin_minutes" {
  description = <<-EOT
    Margin added to max_window_hours to get the sweeper's age threshold. It covers the gap between
    the timer being armed and the first instance launching, so that an instance started at the very
    end of a full-length window is not swept while the window is still legitimately open. The
    sweeper age itself is not a variable: it is derived, so the two cannot drift apart again.
  EOT
  type        = number
  default     = 30
}

variable "orphan_grace_minutes" {
  description = <<-EOT
    How long an hourly resource may exist with no project-tagged instance running and no window
    timer pending before the sweeper treats it as abandoned and runs a full stop on it. It exists
    because a cluster is legitimately node-less for the first few minutes of an apply, and because
    a window in which a node launch is being debugged can be node-less for much longer than that.
    The window-timer test is the real guard; this is the second one.
  EOT
  type        = number
  default     = 60
}

variable "kill_dry_run" {
  description = "When true the kill Lambda reports what it would terminate and terminates nothing. Drills only."
  type        = bool
  default     = false
}

variable "kill_dlq_retention_days" {
  description = <<-EOT
    How long a failed kill event stays on the dead-letter queue. It has to outlast a weekend: the
    queue is the evidence that the kill path did not run, and an alarm nobody read on Friday is
    still worth reading on Monday.
  EOT
  type        = number
  default     = 14
}

variable "log_retention_days" {
  description = "Retention for the kill Lambda log group."
  type        = number
  default     = 30
}

variable "quota_targets" {
  description = <<-EOT
    Service-quota targets, keyed by a short identifier and carrying the quota NAME rather than
    its L- code. The codes are undocumented and are discovered at apply time with
    `aws service-quotas list-aws-default-service-quotas`; nothing here hardcodes one. The map is
    published to SSM so that guard-status and the quota request path read one source of truth.

    Only g_vt_spot is above its documented default and therefore the only increase request
    window 0 has to raise. Every other entry records the default that must still be in force:
    zero for the accelerator and FPGA families, five for the two Standard families. Defaults
    per https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-quotas.html

    Each target also says which way it binds. g_vt_spot is the one floor, because the project
    cannot run until it is raised; everything else is a ceiling, because the design relies on
    those quotas staying small. That distinction is what stops `guard-status` reporting PASS on
    a quota AWS has quietly raised, which matters most for the two Standard families: the EKS
    node group calls that would spend it carry no condition key IAM can filter on, so the quota
    is their only bound.
  EOT
  type = map(object({
    service_code = string
    quota_name   = string
    target       = number
    # Which way the target binds. `guard-status` reads this and refuses to guess:
    #   floor    the applied quota must be at least the target. Exactly one quota is a
    #            floor, the GPU Spot one, which starts at zero and has to be raised or
    #            the project cannot run at all.
    #   ceiling  the applied quota must be no more than the target. Everything the
    #            design relies on staying small.
    #   exact    both. The default when a target does not say, because a floor-only
    #            test passes an applied value above the target, and for the Standard
    #            families that is the difference between a two-node system group and a
    #            node group large enough to matter. That gap cannot be closed in IAM:
    #            neither eks:CreateNodegroup nor eks:UpdateNodegroupConfig carries an
    #            instance-type, capacity-type or scaling-size condition key, so the
    #            quota is the only ceiling those two calls have.
    direction = optional(string, "exact")
    note      = string
  }))

  validation {
    condition     = alltrue([for k, v in var.quota_targets : contains(["floor", "ceiling", "exact"], v.direction)])
    error_message = "Every quota target's direction must be floor, ceiling or exact; guard-status fails closed on anything else."
  }
  default = {
    g_vt_spot = {
      service_code = "ec2"
      quota_name   = "All G and VT Spot Instance Requests"
      target       = 8
      direction    = "floor"
      note         = "vCPUs for the GPU node. g6.2xlarge is 8 vCPUs; default is 0 and this is the only quota that must be raised."
    }
    g_vt_ondemand = {
      service_code = "ec2"
      quota_name   = "Running On-Demand G and VT instances"
      target       = 0
      direction    = "ceiling"
      note         = "Stays at the default of 0. On-demand GPU is denied by the boundary and unfunded by the quota."
    }
    standard_spot = {
      service_code = "ec2"
      quota_name   = "All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests"
      target       = 5
      direction    = "ceiling"
      note         = "System nodes when they run on Spot. Stays at the documented default of 5; two 2-vCPU nodes need 4."
    }
    standard_ondemand = {
      service_code = "ec2"
      quota_name   = "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances"
      target       = 5
      direction    = "ceiling"
      note         = "System nodes carrying Karpenter, CoreDNS and monitoring. Default of 5 covers two 2-vCPU nodes."
    }
    p_spot = {
      service_code = "ec2"
      quota_name   = "All P Spot Instance Requests"
      target       = 0
      direction    = "ceiling"
      note         = "Accelerator family that must stay at zero."
    }
    trn_spot = {
      service_code = "ec2"
      quota_name   = "All Trn Spot Instance Requests"
      target       = 0
      direction    = "ceiling"
      note         = "Accelerator family that must stay at zero."
    }
    inf_spot = {
      service_code = "ec2"
      quota_name   = "All Inf Spot Instance Requests"
      target       = 0
      direction    = "ceiling"
      note         = "Accelerator family that must stay at zero."
    }
    dl_spot = {
      service_code = "ec2"
      quota_name   = "All DL Spot Instance Requests"
      target       = 0
      direction    = "ceiling"
      note         = "Accelerator family that must stay at zero."
    }
    f_spot = {
      service_code = "ec2"
      quota_name   = "All F Spot Instance Requests"
      target       = 0
      direction    = "ceiling"
      note         = "FPGA family. Added after Phase 0 found it missing from the original specification."
    }
    x_spot = {
      service_code = "ec2"
      quota_name   = "All X Spot Instance Requests"
      target       = 0
      direction    = "ceiling"
      note         = "Memory-optimised family. Added after Phase 0 found it missing from the original specification."
    }
  }
}
