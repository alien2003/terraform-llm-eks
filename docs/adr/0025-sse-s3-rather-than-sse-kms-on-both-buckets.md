# 0025. Both buckets use SSE-S3, not SSE-KMS

Date: 2026-09-08

## Status

Accepted.

## Context

`trivy config` raises AVD-AWS-0132, "Bucket does not encrypt data with a customer managed key", at
HIGH severity against any bucket whose default encryption is `AES256`. The suggested fix is a KMS
key and `sse_algorithm = "aws:kms"`.

The two buckets in this stack hold Terraform state and model weights. Neither holds personal data,
neither is shared with another account, and neither has a compliance regime attached to it. What a
customer managed key buys over SSE-S3 in this situation is key rotation on my own schedule, a key
policy as a second layer of access control, and CloudTrail visibility of individual key use.

What it costs is a per-request charge on every KMS operation. The weights bucket is read in multipart
chunks on every cold GPU node start, so the request count scales with node churn rather than with
object count. It also costs a KMS key, which is billed monthly whether or not anything uses it, and
which would have to be added to the teardown order and to the audit.

Rule 2 puts cost safety above everything except not destroying the author's data, and this is a
project deliberately run on a Free Tier credit balance.

## Decision

Both buckets use SSE-S3 (`sse_algorithm = "AES256"`) with `bucket_key_enabled = true`.

AVD-AWS-0132 is waived in place, on the encryption resource, with a scoped `#trivy:ignore` comment
naming this ADR. The check is not disabled globally and not disabled for any other resource.

## Consequences

Data at rest is encrypted, which is the property that actually matters here, and it is encrypted with
a key I do not manage, pay for, rotate or have to remember to delete.

There is no key policy in front of these buckets. Access control is the bucket policy, the public
access block and the operator's IAM boundary, and nothing else. If either bucket ever holds something
that needs a second lock, this decision is the first one to revisit.

`bucket_key_enabled` has no effect under SSE-S3; it is set so that flipping the algorithm to
`aws:kms` later is a one line change that does not also silently multiply the request bill.

## Sources

- `aws_s3_bucket_server_side_encryption_configuration`, valid `sse_algorithm` values `AES256`,
  `aws:kms`, `aws:kms:dsse`:
  <https://registry.terraform.io/providers/hashicorp/aws/6.63.0/docs/resources/s3_bucket_server_side_encryption_configuration>
- Trivy check AVD-AWS-0132: <https://avd.aquasec.com/misconfig/aws-0132>
