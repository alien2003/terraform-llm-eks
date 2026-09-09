# Two alarms on one metric, because AWS/Billing EstimatedCharges answers two
# different questions and only one of them is "is spend running away right now".
#
# Billing metric data is stored in us-east-1 and represents worldwide charges, so
# both the metric and the alarms have to live there whatever var.region says. The
# metric carries a Currency dimension and is published only in USD. Statistic
# Maximum over a six hour period, and missing data treated as missing, are the
# settings AWS documents for this alarm.
# https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/monitor_estimated_charges_with_cloudwatch.html
#
# The metric only appears once charges accrue and AWS publishes it on a several-hour
# cadence, so a fresh account can create these alarms and see INSUFFICIENT_DATA for
# a while. Neither is considered armed until `aws cloudwatch list-metrics
# --namespace AWS/Billing` returns something.
#
# Only ALARM-state actions are configured, which is also all the AWS procedure
# configures. There is deliberately no ok_actions on either: everything on the
# alert topic invokes the kill Lambda, and the first datapoint below the threshold
# on a fresh account is an INSUFFICIENT_DATA to OK transition, which would have
# terminated the cluster a few hours into the first window for the sole reason that
# spend was fine.

# ---------------------------------------------------------------------------
# 1. The cumulative tripwire. "Has gross spend crossed the line this month?"
#
# EstimatedCharges is month-to-date and resets at the start of each month, so
# within a month it only rises. CloudWatch invokes alarm actions on the transition
# into ALARM, so this alarm crosses the threshold once, publishes once, and then
# sits in ALARM until the month rolls over. Two consequences, both of which the
# stack now says out loud rather than leaving to be discovered:
#
#   - it is not a live signal. After it has fired, spend can double and this alarm
#     will not fire again. That is what the burn-rate alarm below is for.
#   - a sticky ALARM is not a reason to refuse every window for the rest of the
#     month. `guard-status` reads the semantics out of the SSM parameter this stack
#     publishes: this alarm in ALARM is a warning carrying the month-to-date
#     figure unless it entered ALARM since the last closed window, which
#     `describe-alarm-history --history-item-type StateUpdate` answers.
resource "aws_cloudwatch_metric_alarm" "estimated_charges" {
  provider = aws.billing

  alarm_name          = "${local.name_prefix}-estimated-charges"
  alarm_description   = "Month-to-date gross estimated charges crossed the billing alarm threshold. Cumulative and sticky: it fires at most once per calendar month and stays in ALARM until the month rolls over."
  namespace           = "AWS/Billing"
  metric_name         = "EstimatedCharges"
  statistic           = "Maximum"
  period              = 21600
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.billing_alarm_threshold_usd
  treat_missing_data  = "missing"

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# 2. The burn rate. "Is money being spent right now?"
#
# DIFF returns "the difference between each value in the time series and the
# preceding value from that time series", so DIFF of a month-to-date total over a
# six-hour period is the dollars added in the last six hours. That can cross, clear
# and cross again as often as it likes, which is exactly what the cumulative alarm
# cannot do.
# https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/using-metric-math.html
#
# The month boundary is safe in the direction that matters: the metric resets to
# near zero, so the first DIFF of a new month is negative and GreaterThanThreshold
# does not fire.
#
# This one does publish to the alert topic, because a threshold above a whole
# approved window's spend inside six hours means something is running that nobody
# approved. Missing data is treated as missing rather than breaching, because AWS
# publishes this metric on its own cadence and a gap is not evidence of spend.
resource "aws_cloudwatch_metric_alarm" "burn_rate" {
  provider = aws.billing

  alarm_name          = "${local.name_prefix}-burn-rate"
  alarm_description   = "Gross estimated charges rose by more than the burn threshold inside one six-hour period. Unlike the cumulative alarm this can fire repeatedly, so ALARM here means spend is being added now."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.billing_burn_threshold_usd
  treat_missing_data  = "missing"

  metric_query {
    id          = "charges"
    return_data = false

    metric {
      namespace   = "AWS/Billing"
      metric_name = "EstimatedCharges"
      period      = 21600
      stat        = "Maximum"

      dimensions = {
        Currency = "USD"
      }
    }
  }

  metric_query {
    id          = "added"
    expression  = "DIFF(charges)"
    label       = "USD added since the previous datapoint"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}
