# Service-quota targets.
#
# No L- code appears anywhere in this stack or in the scripts that read it. Phase 0
# established that the codes are undocumented, that they must be discovered at run
# time with `aws service-quotas list-aws-default-service-quotas` rather than
# list-service-quotas (which omits quotas with no applied value), and that a quota
# is therefore addressed by NAME. The names below are the ones AWS publishes:
# https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-quotas.html
#
# The targets are data, not resources. Raising a quota is an administrator action
# taken once, in window 0, through the request path in README.md; Terraform does not
# own the request because a quota increase is a ticket with a lead time, not a thing
# that converges on apply.

resource "aws_ssm_parameter" "quota_targets" {
  name        = "/llm-eks/guardrails/quota-targets"
  description = "Quota targets keyed by name. Read by guard-status; the L- codes are resolved at run time."
  type        = "String"
  # Standard tier, which is free and holds 4 KB. The encoded map is well under that,
  # and a guardrail stack that bills for its own configuration would be a poor joke.
  tier  = "Standard"
  value = jsonencode(var.quota_targets)
}

# ---------------------------------------------------------------------------
# The guardrail's own numbers, published for the scripts.
#
# `mise run up` used to carry its own MAX_WINDOW_HOURS and this stack used to carry
# its own sweeper age, and the two disagreed by a factor of two: an approved
# eight-hour window was terminated by the always-on sweeper at the four-hour mark.
# Numbers that have to agree cannot be typed twice, so the sweeper age is derived
# from max_window_hours in main.tf and both are published here. The scripts read
# this parameter instead of holding copies:
#
#   window-up.sh    max_window_hours as the ceiling on WINDOW_HOURS, and
#                   kill_dlq_name to put the same DeadLetterConfig on the one-shot
#                   timer that schedules.tf puts on the sweeper.
#   guard-status.sh sweeper_max_age_minutes to check against the live Lambda's
#                   MAX_AGE_MINUTES, kill_regions to check against the boundary's
#                   allowed regions, kill_path_alarms to check that each alarm
#                   exists and is not itself in ALARM, sms_enabled to decide
#                   whether the SNS SMS sandbox status is worth checking, and
#                   billing_alarms for which of the two alarms is a warning and
#                   which is a refusal.
resource "aws_ssm_parameter" "limits" {
  name        = "/llm-eks/guardrails/limits"
  description = "Window and sweeper limits, kill-path resource names and billing-alarm semantics. One source of truth for the scripts."
  type        = "String"
  tier        = "Standard"
  value       = jsonencode(local.limits)
}
