locals {
  # Rule 2a: the sweeper and `mise run audit` select on Project. A resource that
  # loses this tag stops being visible to the safety net.
  default_tags = {
    Project   = "terraform-llm-eks"
    Stack     = "bootstrap"
    ManagedBy = "terraform"
  }

  # The two buckets share their hardening: versioning, SSE, a full public access
  # block and a TLS-only policy. Only their lifecycle rules differ, so those live
  # in their own resources below.
  buckets = {
    tfstate = {
      name = var.state_bucket_name
    }
    weights = {
      name = var.weights_bucket_name
    }
  }

  # Upstream registries for the pull-through cache.
  #
  # ECR supports pull-through cache rules only for a fixed set of upstreams.
  # ECR Public, the Kubernetes registry and Quay need no credentials; Docker Hub,
  # Azure Container Registry, GitHub Container Registry, GitLab (SaaS only) and
  # Chainguard all need a Secrets Manager secret; ECR-to-ECR needs an IAM role.
  # Source: https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html
  #
  # The four below are the ones this project pulls from. The registry URLs are the
  # values AWS documents for `create-pull-through-cache-rule`:
  # https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache-creating-rule.html
  pull_through_cache = {
    "ecr-public" = {
      upstream_registry_url = "public.ecr.aws"
      needs_credentials     = false
    }
    "kubernetes" = {
      upstream_registry_url = "registry.k8s.io"
      needs_credentials     = false
    }
    "quay" = {
      upstream_registry_url = "quay.io"
      needs_credentials     = false
    }
    "docker-hub" = {
      upstream_registry_url = "registry-1.docker.io"
      needs_credentials     = true
    }
  }

  # A rule that needs credentials is only created once the operator has put a
  # value into the secret. Until then the apply would fail ECR's own validation
  # of the credential, so the rule is held back behind a variable.
  cache_rules = {
    for name, rule in local.pull_through_cache :
    name => rule
    if !rule.needs_credentials || var.enable_dockerhub_cache
  }

  # The default private registry URL, documented at
  # https://docs.aws.amazon.com/AmazonECR/latest/userguide/Registries.html
  ecr_registry_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # Cross-stack values. The cluster stack reads these with an SSM data source
  # rather than a remote state data source, because this stack keeps local state
  # and cannot be read that way. See ADR 0022.
  #
  # `ecr-cache-namespace` is deliberately not called `ecr-cache-prefix`. No cache
  # rule in this stack uses the bare namespace as its `ecr_repository_prefix`;
  # every rule uses `<namespace>/<key>`, so a consumer that built an image
  # reference out of a parameter named "prefix" would produce a path that matches
  # no rule and no repository. The usable values are the per-upstream entries
  # below, and the namespace is published only for the things that legitimately
  # want it: the repository creation template prefix and IAM resource patterns.
  ssm_parameters = merge(
    {
      "tfstate-bucket"      = var.state_bucket_name
      "weights-bucket"      = var.weights_bucket_name
      "ecr-cache-namespace" = var.ecr_cache_prefix
      "ecr-registry-url"    = local.ecr_registry_url
    },
    {
      for name, rule in local.pull_through_cache :
      "ecr-cache-repository-prefix/${name}" => "${var.ecr_cache_prefix}/${name}"
    }
  )
}
