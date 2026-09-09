# Terraform and provider pins for the bootstrap stack.
#
# There is deliberately no `backend` block here. This stack creates the S3 bucket
# that every other stack's backend points at, so it cannot itself live in that
# bucket. State stays local and is snapshotted out of band. See ADR 0020.
#
# `use_lockfile` in the cluster stack's S3 backend needs Terraform 1.10 or later
# (S3 native state locking landed there, and became generally available in 1.11).
# The floor below is well above that. See ADR 0021.

terraform {
  required_version = "~> 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.63.0"
    }
  }
}
