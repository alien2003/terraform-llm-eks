# State and weights buckets.
#
# Both are private, versioned, encrypted at rest and reachable over TLS only.
# They differ in what they hold and therefore in how their lifecycle rules are
# tuned: state files are small and I want their history; weights are large and
# their history is worthless.

# No server access logging. It needs a third bucket that cannot itself be
# logged, and it bills per log object written; CloudTrail management events
# already record every configuration call against these two buckets at no
# charge. Accepted deliberately, see README.
#trivy:ignore:AVD-AWS-0089 access logging needs a third bucket and bills per log object; CloudTrail management events cover the API calls
resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket = each.value.name

  # Default false. Destroying a bucket that still holds objects is refused, which
  # is the behaviour I want everywhere except the final teardown window.
  force_destroy = var.force_destroy_buckets
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES256) rather than SSE-KMS. KMS bills per request and the weights
# bucket is read in thousands of multipart chunks; SSE-S3 carries no separate
# charge. See ADR 0025 for the reasoning and the trivy check this waives.
#trivy:ignore:AVD-AWS-0132 SSE-S3 is deliberate: KMS request charges on a multi-GB weights bucket, see ADR 0025
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# TLS-only access.
#
# Two separate statements because conditions inside one statement are ANDed:
# the first refuses plain HTTP, the second refuses TLS below 1.2. Condition keys
# from
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingEncryptionInTransit.html
#
# Both statements also require `aws:PrincipalIsAWSService` to be false. AWS
# redacts the network authorization context on service-to-service calls made on
# my behalf, and the redacted keys include `aws:SecureTransport` and
# `s3:TlsVersion`. A Deny written on those keys alone therefore blocks AWS
# service principals instead of exempting them. Nothing in this project relies on
# that path today, but S3 Inventory output, a replication destination and
# CloudTrail data-event delivery into the weights bucket all would, and each would
# fail as an opaque AccessDenied that looks nothing like a TLS problem. Excluding
# service principals is the remedy AWS documents for exactly this pattern, under
# "Example 6: Requiring a minimum TLS version":
# https://docs.aws.amazon.com/AmazonS3/latest/userguide/amazon-s3-policy-keys.html
#
# The principal renders as {"AWS": "*"}, which AWS documents as equivalent to
# "*" for anonymous users:
# https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_principal.html
data "aws_iam_policy_document" "tls_only" {
  for_each = aws_s3_bucket.this

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }

    condition {
      test     = "Bool"
      variable = "aws:PrincipalIsAWSService"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyOutdatedTLS"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]

    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }

    condition {
      test     = "Bool"
      variable = "aws:PrincipalIsAWSService"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id
  policy = data.aws_iam_policy_document.tls_only[each.key].json

  # The policy denies everything over plain HTTP, including the PutBucketPolicy
  # that would replace it. Applying it before the public access block is in place
  # is harmless, but ordering it after keeps the bucket from ever being briefly
  # policy-bearing and unblocked.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# State bucket lifecycle.
#
# Terraform writes a new object version on every apply. Keeping the ten most
# recent noncurrent versions gives a usable rollback history; anything older than
# a month is dead weight. Incomplete multipart uploads are aborted because their
# parts are billed as storage until they are.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.this["tfstate"].id

  # Noncurrent version rules only do anything once versioning is on.
  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = var.state_noncurrent_version_expiration_days
      newer_noncurrent_versions = var.state_noncurrent_versions_retained
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }
  }
}

# Weights bucket lifecycle.
#
# No storage class transition. Weights are written once and read on every cold
# node start, so they are not infrequently accessed in the sense S3 Standard-IA
# means; IA also charges a per-GB retrieval fee and bills a 30-day minimum
# duration, which a project measured in cloud windows would pay in full without
# ever reaching the crossover. See ADR 0023.
#
# What the rules do instead is stop paying for data nobody wants: aborted
# multipart uploads (a failed multi-GB push leaves its parts behind and they are
# billed), noncurrent versions of replaced files, and delete markers left over
# once every version under them has expired.
resource "aws_s3_bucket_lifecycle_configuration" "weights" {
  bucket = aws_s3_bucket.this["weights"].id

  depends_on = [aws_s3_bucket_versioning.this]

  rule {
    id     = "expire-superseded-weights"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.weights_noncurrent_version_expiration_days
    }

    expiration {
      expired_object_delete_marker = true
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }
  }
}
