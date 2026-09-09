# The tagging baseline.
#
# Every taggable resource in every stack carries Project, Stack and ManagedBy.
# `mise run audit` and the guardrails sweeper both select on
# Project=terraform-llm-eks, so an untagged resource is invisible to the safety
# net. The tags are set once here through `default_tags` rather than resource by
# resource.
#
# One place default_tags does not reach is a launch template's
# `tag_specifications` blocks, which are what tag the EC2 instances, volumes and
# ENIs a managed node group launches. The same baseline is therefore also passed
# into the eks module as `tags`; see the comment on that argument in eks.tf.
#
# Resources this stack creates inside a cloud window also carry Window, which is
# passed in as a variable by `mise run up`.

provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }
}

# ------------------------------------------------------------ the in-cluster half

# The two providers the `platform` child module uses. They are configured here and
# only here: a provider configuration is a root-module concern, and a child module
# declares what it needs and inherits the default configuration.
#
# Authentication is the documented exec-plugin pattern for EKS. `aws eks get-token`
# prints an ExecCredential whose apiVersion is `client.authentication.k8s.io/v1beta1`,
# which is the version both blocks below decode; the CLI reference shows that
# response verbatim. The helm provider takes its Kubernetes settings as a single
# `kubernetes` attribute at 3.x, with `exec` nested inside it as an attribute too,
# while the kubernetes provider takes `exec` as a block. That asymmetry is real and
# both shapes come from the providers' own documentation.
#
# https://docs.aws.amazon.com/cli/latest/reference/eks/get-token.html
# https://registry.terraform.io/providers/hashicorp/kubernetes/3.2.1/docs
# https://registry.terraform.io/providers/hashicorp/helm/3.3.0/docs
#
# Why the host comes out of a conditional instead of straight out of `module.eks`:
# the kubernetes provider cannot be configured from a value this same apply
# creates. HashiCorp's own documentation says so, under "Stacking with managed
# Kubernetes cluster resources": resources exposing cluster credentials "SHOULD NOT
# be created in the same Terraform module where Kubernetes provider resources are
# also used", and "The most reliable way to configure the Kubernetes provider is to
# ensure that the cluster itself and the Kubernetes provider resources can be
# managed with separate apply operations."
#
# I measured what that means for this exact pin set rather than taking it on faith.
# On Terraform 1.16.1 with kubernetes 3.2.1 and helm 3.3.0, a throwaway
# configuration whose provider host was a value only known after apply fails during
# `terraform plan` with:
#
#   Error: Provider configuration: cannot load Kubernetes client config
#   invalid configuration: default cluster has no server defined
#
# Three things came out of that run and all three shape the code below. The helm
# provider planned the same configuration without complaint, so this is the
# kubernetes provider specifically, and the platform module needs it for its
# namespaces and its dashboard ConfigMaps. Putting `count = 0` on the module does
# not avoid it: the module still declares the provider, Terraform still configures
# it, and the plan still fails identically. And a placeholder host with
# `cluster_ca_certificate = null` configures cleanly and invokes no exec plugin, so
# a phase-one plan makes no call of any kind against a cluster that does not exist.
#
# Hence `var.platform_enabled`: phase one applies with it false and these providers
# pointed at a host that cannot resolve, phase two applies with the default and
# `module.eks.cluster_endpoint` known from state. The README section "Two applies,
# not one" is the operator-facing version of this, and ADR 0037 has the decision.

provider "kubernetes" {
  host                   = local.platform_kube_host
  cluster_ca_certificate = local.platform_kube_ca_certificate

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.platform_kube_cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.platform_kube_host
    cluster_ca_certificate = local.platform_kube_ca_certificate

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.platform_kube_cluster_name, "--region", var.region]
    }
  }
}
