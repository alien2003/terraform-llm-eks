# Remote state for the cluster stack.
#
# The bucket is created by infra/bootstrap, which keeps its own state locally
# precisely so that this circular dependency does not exist. See ADR 0020.
#
# Locking is S3 native (`use_lockfile`), so there is no DynamoDB table anywhere in
# this project. See ADR 0021.
#
# The bucket name is hardcoded because a backend block cannot take variables or
# expressions. It matches `state_bucket_name` in infra/bootstrap.
#
# Locally, without credentials, this stack is validated with
# `terraform init -backend=false`, which skips the backend entirely.

terraform {
  backend "s3" {
    bucket       = "llm-eks-tfstate-288497659215"
    key          = "cluster/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
