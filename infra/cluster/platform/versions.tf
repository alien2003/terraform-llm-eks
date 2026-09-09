# Provider pins for the platform layer.
#
# This is a child module. It declares the providers it uses and their version
# constraints; the root cluster stack configures them. `terraform validate` runs
# here on its own, which is how the chart values, the CRD field names and the
# provider arguments in this directory are checked with no cluster and no
# credentials.
#
# The AWS provider pin is the one the whole repository carries. The helm and
# kubernetes provider versions were read from the public registry on 2026-09-08.
#
# There is deliberately no `kubernetes_manifest` resource anywhere in this
# module. That resource opens a connection to the API server during plan, which
# would make `terraform plan` and CI fail whenever no cluster exists. Everything
# custom is delivered as a Helm chart instead. See ADR 0040.

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
