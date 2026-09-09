output "operator_role_arn" {
  description = "ARN of the operator role. This is what the llm-eks-operator profile assumes."
  value       = aws_iam_role.operator.arn
}

output "operator_boundary_policy_arn" {
  description = "ARN of the permission boundary carried by the operator role and by every role it creates."
  value       = aws_iam_policy.operator_boundary.arn
}

output "alert_topic_arn" {
  description = "ARN of the single topic every alert arrives on."
  value       = aws_sns_topic.alerts.arn
}

output "budget_name" {
  description = "Name of the gross-spend budget."
  value       = aws_budgets_budget.gross_spend.name
}

output "budget_stop_policy_arn" {
  description = "Policy the budget action attaches to the operator role. Only the administrator can detach it."
  value       = aws_iam_policy.budget_stop.arn
}

output "billing_alarm_name" {
  description = "Name of the CloudWatch alarm on AWS/Billing EstimatedCharges."
  value       = aws_cloudwatch_metric_alarm.estimated_charges.alarm_name
}

output "anomaly_monitor_arn" {
  description = "ARN of the Cost Anomaly Detection monitor."
  value       = aws_ce_anomaly_monitor.services.arn
}

output "kill_function_arn" {
  description = "ARN of the kill Lambda. The one-shot window timer targets this."
  value       = aws_lambda_function.kill.arn
}

output "kill_function_name" {
  description = "Name of the kill Lambda."
  value       = aws_lambda_function.kill.function_name
}

output "sweeper_schedule_name" {
  description = "Name of the always-on sweeper schedule."
  value       = aws_scheduler_schedule.sweeper.name
}

output "window_schedule_group_name" {
  description = "Schedule group that mise run up creates the one-shot window timer in."
  value       = aws_scheduler_schedule_group.windows.name
}

output "scheduler_role_arn" {
  description = "Role the one-shot window timer must be created with. mise run up passes this."
  value       = aws_iam_role.scheduler.arn
}

output "notices_topic_arn" {
  description = "Topic carrying the alarms that say the kill path itself is broken. Email only; the kill Lambda is deliberately not subscribed."
  value       = aws_sns_topic.notices.arn
}

output "burn_alarm_name" {
  description = "Name of the burn-rate alarm. Unlike the cumulative one it can fire more than once a month."
  value       = aws_cloudwatch_metric_alarm.burn_rate.alarm_name
}

output "kill_dlq_arn" {
  description = "Dead-letter queue for undelivered kill events. mise run up puts this on the one-shot window timer it creates."
  value       = aws_sqs_queue.kill_dlq.arn
}

output "kill_dlq_url" {
  description = "URL of the kill dead-letter queue, for reading what was dropped."
  value       = aws_sqs_queue.kill_dlq.url
}

output "sweeper_max_age_minutes" {
  description = "Derived age at which the sweeper stops project compute: max_window_hours plus the margin. Not a variable; it cannot be set by hand."
  value       = local.sweeper_max_age_minutes
}

output "limits_parameter" {
  description = "SSM parameter holding the window and sweeper limits, the kill-path resource names and the billing-alarm semantics. The scripts read this rather than holding copies."
  value       = aws_ssm_parameter.limits.name
}

output "quota_targets_parameter" {
  description = "SSM parameter holding the quota targets, keyed by quota name."
  value       = aws_ssm_parameter.quota_targets.name
}
