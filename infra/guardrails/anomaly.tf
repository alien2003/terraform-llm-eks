# Cost Anomaly Detection. The budget catches a slow leak against a monthly number;
# this catches a step change on a single service within a day, which is the shape a
# forgotten GPU node actually has.
#
# It reports to the author by email and it is not on the alert topic. That is a
# change from the first version of this file, and the reason is worth stating
# plainly: everything on the alert topic invokes the kill Lambda, and on an account
# whose baseline is zero the first deliberate GPU window IS the anomaly. A
# ten-dollar impact is not an emergency here, it is one afternoon of the work the
# project exists to do. An immediate SNS subscription at that threshold would have
# torn down a running benchmark and called it a guardrail, which is the same defect
# the budget's percentage notifications had and the same lesson recorded at the top
# of budgets.tf.
#
# Frequency is DAILY because that is what an email subscriber requires: AWS
# documents notifications as sent "either over email (for DAILY and WEEKLY
# frequencies) or SNS (for IMMEDIATE frequency)". So this is a daily digest, and
# the controls that stop spend inside a window are the timer, the sweeper, the two
# billing alarms and the budget action.
# https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_AnomalySubscription.html
#
# Whether Cost Anomaly Detection is available at all on a Free Plan account is open
# (STATE.md, open question 3). If the apply fails here, that is the answer.

resource "aws_ce_anomaly_monitor" "services" {
  provider = aws.billing

  name              = "${local.name_prefix}-service-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "alerts" {
  provider = aws.billing

  name             = "${local.name_prefix}-anomaly-alerts"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "EMAIL"
    address = var.alert_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }

  lifecycle {
    precondition {
      condition     = var.alert_email != ""
      error_message = "alert_email is required: the anomaly subscription delivers to it directly, because the alert topic invokes the kill Lambda and a cost anomaly on a zero-baseline account is not a reason to tear down a window."
    }
  }
}
