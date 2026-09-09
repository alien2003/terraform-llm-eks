# Two schedules with different jobs, and one queue that catches what neither of
# them managed to deliver.
#
# The sweeper is always on. It does not know or care whether a window is open. It
# stops project compute when it finds an instance older than the derived age, and
# it escalates to a full stop when it finds an hourly resource that has been
# running with no instances and no pending window timer. It is the control that
# survives a session ending badly, and it is also what finishes a full stop that
# could not complete in one pass, because a cluster cannot be deleted until its
# node groups have finished deleting.
#
# The window group holds the one-shot timers that `mise run up` creates at now plus
# WINDOW_HOURS and `mise run down` deletes. Terraform creates the group and the
# execution role; the timers themselves are made at window time, because their fire
# time is only known then. `mise run up` reads the dead-letter queue's ARN out of
# the SSM parameter this stack publishes and puts the same DeadLetterConfig on the
# timer it creates.

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.${local.dns_suffix}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name_prefix}-scheduler"
  description        = "Assumed by EventBridge Scheduler to invoke the kill Lambda."
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "InvokeKillLambda"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.kill.arn]
  }

  # Without this the dead-letter queue is decoration: the scheduler writes the
  # undelivered event itself, so it needs to be allowed to.
  statement {
    sid       = "WriteToDeadLetterQueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.kill_dlq.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${local.name_prefix}-scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

# Server-side encryption with the SQS-managed key, which is free and needs no key
# policy. The messages are scheduler envelopes carrying a mode and a window ID.
resource "aws_sqs_queue" "kill_dlq" {
  name                      = "${local.name_prefix}-kill-dlq"
  message_retention_seconds = var.kill_dlq_retention_days * 24 * 60 * 60
  sqs_managed_sse_enabled   = true
}

resource "aws_scheduler_schedule" "sweeper" {
  name        = "${local.name_prefix}-sweeper"
  group_name  = "default"
  description = "Stops project compute past the derived age and finishes any full stop left half done. Always on."
  state       = "ENABLED"

  schedule_expression = "rate(${var.sweeper_interval_minutes} minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.kill.arn
    role_arn = aws_iam_role.scheduler.arn

    input = jsonencode({
      mode            = "sweep"
      max_age_minutes = local.sweeper_max_age_minutes
    })

    retry_policy {
      maximum_retry_attempts = 3
    }

    # After the retries, the event lands here instead of disappearing. A sweep
    # that was dropped is indistinguishable from a sweep that found nothing
    # unless something keeps the evidence.
    dead_letter_config {
      arn = aws_sqs_queue.kill_dlq.arn
    }
  }
}

resource "aws_scheduler_schedule_group" "windows" {
  name = "${local.name_prefix}-windows"
}
