# 0021. The cluster backend locks with S3, not DynamoDB

Date: 2026-09-08

## Status

Accepted.

## Context

The S3 backend has locked state through a DynamoDB table for most of Terraform's life. That table is
a second resource in a second service, with its own IAM permissions, its own tags, its own line in
the teardown order and its own way of being left behind after a failed destroy. `mise run audit`
would have to know about it. The permission boundary would have to allow it.

Terraform has since grown a lock mechanism that uses S3 itself, writing a lock file next to the state
object and relying on S3's conditional writes.

## Decision

`infra/cluster` configures its backend with `use_lockfile = true` and no `dynamodb_table`. No
DynamoDB table is created anywhere in this project.

The repository's floor is `required_version = "~> 1.16"`, comfortably above what the feature needs.

## Consequences

One fewer service in the blast radius, one fewer resource for the audit and the sweeper to know
about, and one fewer set of IAM actions in the operator boundary.

The `dynamodb_table` argument is documented as deprecated and slated for removal in a future minor
version of the backend, so this is also the direction the backend is going anyway.

Anyone running this repository with a Terraform older than 1.10 gets an unrecognised argument rather
than an unlocked apply, which is the failure mode I want.

## Sources

- Terraform S3 backend documentation. `use_lockfile` is "(Optional) Whether to use a lockfile for
  locking the state file. Defaults to `false`", and `dynamodb_table` is marked Deprecated with the
  note that DynamoDB-based locking "is deprecated and will be removed in a future minor version":
  <https://developer.hashicorp.com/terraform/language/backend/s3>
- Terraform 1.10.0 CHANGELOG, upgrade notes: "The s3 backend now supports S3 native state locking.
  When used with DynamoDB-based locking, locks will be acquired from both sources."
  <https://github.com/hashicorp/terraform/blob/v1.10.0/CHANGELOG.md>
- Terraform 1.11.0 CHANGELOG: "S3 native state locking is now generally available. The
  `use_lockfile` argument enables users to adopt the S3-native mechanism for state locking."
  <https://github.com/hashicorp/terraform/blob/v1.11.0/CHANGELOG.md>
