# ECR pull-through cache.
#
# Every image the cluster pulls comes through here, which does three things at
# once: it survives Docker Hub rate limiting, it keeps repeated node starts off
# the public internet, and it makes the bytes come from inside the Region.
#
# The secret container is created here without a value. Rule 2c says registry
# credentials live in Secrets Manager and are referenced by ARN, and creating the
# container in Terraform is what makes that ARN stable and predictable; the value
# is put in by hand inside a window and never passes through this repository or
# through Terraform state. See ADR 0024.
#
# ECR requires the name prefix `ecr-pullthroughcache/` and refuses a customer
# managed KMS key for this secret, so `kms_key_id` is deliberately unset and the
# account's `aws/secretsmanager` key is used.
# https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache-creating-secret.html
#trivy:ignore:AVD-AWS-0098 ECR does not support a customer managed key for pull-through cache secrets, see ADR 0024
resource "aws_secretsmanager_secret" "dockerhub" {
  name        = "ecr-pullthroughcache/llm-eks-docker-hub"
  description = "Docker Hub username and access token for the llm-eks pull-through cache. Value is set by hand."

  # Shortest window Secrets Manager allows other than immediate deletion. The
  # teardown audit has to come back clean, and a secret sitting in a 30-day
  # recovery window is a resource that outlives the project.
  recovery_window_in_days = 7
}

resource "aws_ecr_pull_through_cache_rule" "this" {
  for_each = local.cache_rules

  ecr_repository_prefix = "${var.ecr_cache_prefix}/${each.key}"
  upstream_registry_url = each.value.upstream_registry_url

  # Only the authenticated upstream carries a credential ARN. Docker Hub is the
  # only one of the four this project uses that needs one.
  credential_arn = each.value.needs_credentials ? aws_secretsmanager_secret.dockerhub.arn : null
}

# Repository creation template.
#
# ECR creates a repository on my behalf the first time an image is pulled
# through a cache rule, and the defaults it applies include no lifecycle policy
# at all. Left alone, every tag this project has ever pulled stays in the private
# registry, billed per GB-month, until somebody deletes it by hand. The template
# is what stops that from happening.
#
# `prefix` matches the same namespace the cache rules write under, and
# `applied_for` restricts it to the pull-through cache path so it does not also
# govern repositories created any other way.
#
# Tag mutability stays MUTABLE. This is not a preference: AWS documents that
# turning on tag immutability for a repository fed by a pull-through cache
# prevents ECR from refreshing an image behind an existing tag, which is the
# entire mechanism.
#
# No `resource_tags`. Setting them requires `custom_role_arn`, which means an IAM
# role this stack would have to create, and the operator boundary is not the
# place to find out whether it can. Cache repositories are therefore found by
# prefix rather than by the project tag, same as the cache rules themselves.
resource "aws_ecr_repository_creation_template" "cache" {
  prefix               = var.ecr_cache_prefix
  description          = "Applied to repositories ECR creates for the llm-eks pull-through cache."
  applied_for          = ["PULL_THROUGH_CACHE"]
  image_tag_mutability = "MUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }

  # One rule, not two. Rule priority interacts with tag status in ways that are
  # easy to get subtly wrong, and a single bound on repository size is all this
  # needs to do. Parameter names from
  # https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html
  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the most recently pushed images in each cached repository."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_cache_images_retained
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
