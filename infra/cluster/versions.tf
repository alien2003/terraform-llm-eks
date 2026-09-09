# Terraform and provider pins for the cluster stack.
#
# The version floor is the same one the rest of the repository carries. It is well
# above the 1.11 that S3 native state locking needs; see backend.tf and ADR 0021.
#
# Three providers are declared. `aws` is the one this directory's own resources
# use. `helm` and `kubernetes` are declared because this root stack *configures*
# them for the `platform` child module, which declares the same two at the same
# pinned versions in platform/versions.tf. A child module inherits the default
# configuration of a provider it declares, so the pins have to agree; if they ever
# drift, `terraform init` fails on the constraint rather than resolving something
# neither directory asked for.
#
# The eks and vpc modules pull `time`, `tls`, `null` and `cloudinit` in themselves
# and declare their own constraints, so repeating those at the root would only give
# me a second place to get them wrong.

terraform {
  required_version = "~> 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.63.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }
  }
}
