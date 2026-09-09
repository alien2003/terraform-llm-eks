# Two topics, and the difference between them is the whole point.
#
# `llm-eks-alerts` is a trigger. The kill Lambda is subscribed to it, so everything
# published there ends the window. Three publishers qualify: the budget action, the
# cumulative billing alarm and the burn-rate alarm. The budget's informational
# percentage and forecast notifications and the cost anomaly subscription
# deliberately go to the email address instead; see the comment at the top of
# budgets.tf. It lives in us-east-1 because that is where the billing metric and
# the budget service publish from, and a CloudWatch alarm can only notify a topic
# in its own region.
#
# `llm-eks-notices` is a mailing list. It carries the alarms that say the kill path
# itself is broken: the Lambda's errors and throttles, a silent sweeper, and a
# message on the dead-letter queue. Those cannot go to the alert topic, because the
# alert topic invokes the kill Lambda, and answering "the teardown failed" by
# running the teardown again is not a control. It lives in var.region with the
# Lambda, the queue and those alarms.

# Server-side encryption is deliberately off on both. Budgets, Cost Anomaly
# Detection and CloudWatch can only publish to an encrypted topic through a
# customer managed KMS key whose key policy names each service principal, and a key
# that can be deleted would silence the alerts these topics exist to deliver.
# Nothing here is a secret: the messages carry thresholds, instance IDs and alarm
# names.
#trivy:ignore:AWS-0095
resource "aws_sns_topic" "alerts" {
  provider = aws.billing

  name         = "${local.name_prefix}-alerts"
  display_name = "llm-eks"
}

#trivy:ignore:AWS-0095
resource "aws_sns_topic" "notices" {
  name         = "${local.name_prefix}-notices"
  display_name = "llm-eks notices"
}

data "aws_iam_policy_document" "alerts" {
  statement {
    sid     = "AllowCostServicesToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type = "Service"
      identifiers = [
        "budgets.${local.dns_suffix}",
        "costalerts.${local.dns_suffix}",
        "cloudwatch.${local.dns_suffix}",
      ]
    }

    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # SNS:Publish is deliberately absent from this statement, and the notices topic
  # below has never carried it. The principal here is every identity in the
  # account, and a publish to this topic is a teardown: the kill Lambda is
  # subscribed to it and reads any envelope as stop everything now. Granting
  # Publish account-wide meant one `aws sns publish` from an unprivileged caller
  # scaled the node groups to zero and deleted the hourly resources.
  #
  # Nothing legitimate loses anything. The three publishers that matter are
  # service principals and are granted above, in their own statement: Budgets for
  # the action notification, CloudWatch for the two billing alarms, and Cost
  # Anomaly Detection. The operator is denied sns:Publish on this topic by
  # NoSafetyNetTampering in the boundary as well, so the identity-based and the
  # resource-based path are both closed rather than one covering for the other.
  #
  # Subscribe stays. This document replaces the default topic policy rather than
  # adding to it, and the guardrails stack is applied with the administrator
  # profile, which is what creates the Lambda and email subscriptions. Taking
  # Subscribe out here would put the window-0 apply behind the question of whether
  # an identity policy alone authorizes a same-account subscribe, and a failed
  # window-0 apply is not worth a second lock on a door the boundary already
  # bolts: NoAlertSubscriptionTampering denies the operator sns:Subscribe,
  # sns:Unsubscribe and sns:SetSubscriptionAttributes on every resource.
  statement {
    sid    = "AllowOwnerAccountManagement"
    effect = "Allow"
    actions = [
      "SNS:GetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Subscribe",
    ]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [aws_sns_topic.alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  provider = aws.billing

  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

data "aws_iam_policy_document" "notices" {
  statement {
    sid     = "AllowCloudWatchToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.${local.dns_suffix}"]
    }

    resources = [aws_sns_topic.notices.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid    = "AllowOwnerAccountManagement"
    effect = "Allow"
    actions = [
      "SNS:GetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Subscribe",
    ]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [aws_sns_topic.notices.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "notices" {
  arn    = aws_sns_topic.notices.arn
  policy = data.aws_iam_policy_document.notices.json
}

# Subscriptions are driven by variables and no address and no number is written
# into the repository. The email address is subscribed to both topics: it is the
# one path that works without anything being verified out of band.
resource "aws_sns_topic_subscription" "email" {
  provider = aws.billing
  count    = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "notices_email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.notices.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# SMS is off unless two things are true: a number is supplied, and somebody has
# confirmed that the number is verified in the SNS SMS sandbox.
#
# A new account is in the sandbox, where a message reaches only verified
# destination numbers. An SMS subscription is created with a real ARN and no
# confirmation handshake, so an unverified number produces a subscription that
# looks confirmed to `aws sns list-subscriptions-by-topic`, reports as healthy in
# guard-status, and delivers nothing. The failure is silent on every surface
# except the phone that was supposed to ring, which is the whole reason the SMS
# path was wanted. So the gate is a validation on alert_sms_sandbox_verified: a
# number supplied without an acknowledgement fails the plan rather than quietly
# producing no subscription, and clearing alert_phone is the clean way to say
# that email is the only path.
# https://docs.aws.amazon.com/sns/latest/dg/sns-sms-sandbox.html
resource "aws_sns_topic_subscription" "sms" {
  provider = aws.billing
  count    = var.alert_phone != "" && var.alert_sms_sandbox_verified ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "sms"
  endpoint  = var.alert_phone
}
