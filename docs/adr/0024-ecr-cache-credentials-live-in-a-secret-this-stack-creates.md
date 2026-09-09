# 0024. The pull-through cache secret is created here, empty, and the Docker Hub rule waits for it

Date: 2026-09-08

## Status

Accepted.

## Context

Every image the cluster pulls goes through an ECR pull-through cache. ECR supports a fixed list of
upstream registries and splits them by how they authenticate: ECR Public, the Kubernetes registry and
Quay need nothing; Docker Hub, Azure Container Registry, GitHub Container Registry, GitLab (SaaS
only) and Chainguard each need credentials in an AWS Secrets Manager secret; ECR-to-ECR needs an IAM
role. This project pulls from the first three plus Docker Hub, so exactly one secret is needed.

Rule 2c says a secret that must exist lives in Secrets Manager and is referenced by ARN. That leaves
one design question: does this stack create the secret container, or does it take the ARN of a secret
someone else made as an input variable?

Taking an ARN as a variable means the ARN is a string typed by a human into a tfvars file. It can be
wrong, it has to be carried between machines, and it makes the stack unappliable on a clean account
until someone has clicked through a console first. It also leaves an orphan: a secret nobody's
Terraform owns, which the teardown audit will find and nobody will remember creating.

Creating the container here makes the ARN a resource attribute. It is predictable, it is referenced
by expression rather than by transcription, and it is destroyed with the stack.

The cost of creating it here is that on the first apply the secret exists with no value, and ECR
validates the credential when a pull-through cache rule referencing it is created. A rule pointing at
an empty secret fails.

## Decision

This stack creates `aws_secretsmanager_secret.dockerhub`, named
`ecr-pullthroughcache/llm-eks-docker-hub`, with no value. There is no `aws_secretsmanager_secret_version`
resource in this directory and there must never be one: the value is put in by hand, inside a cloud
window, and never passes through this repository or through Terraform state.

The three unauthenticated cache rules are created unconditionally. The Docker Hub rule is held behind
`enable_dockerhub_cache`, default false, and is created on a second apply once the secret has a
value.

The secret uses the account's default `aws/secretsmanager` key. This is not a choice: AWS documents
that ECR does not support a customer managed key for pull-through cache secrets. The
`trivy config` check AVD-AWS-0098 is waived in place with a scoped ignore comment for that reason.

`recovery_window_in_days` is 7, the shortest Secrets Manager allows short of immediate deletion. A
secret sitting in a 30 day recovery window after the project ends is a resource that outlives the
final audit.

## Consequences

Standing up the cache is a two-phase operation, and the README says so in order. Anyone who applies
once and expects Docker Hub images to resolve will be confused for exactly as long as it takes to
read `enable_dockerhub_cache`.

The `ecr-pullthroughcache/` name prefix is mandatory. Without it ECR rejects the ARN and the console
will not list the secret at all. It is hardcoded rather than made configurable so that it cannot be
overridden into something that fails at apply time.

The per-registry repository prefixes are published to SSM for all four upstreams, including Docker
Hub, whether or not its rule exists yet. The prefix is knowable before the rule is created and the
cluster stack should not have to care which phase it is looking at.

`aws_ecr_pull_through_cache_rule` accepts no tags, in this provider version or in the underlying API,
so the cache rules do not carry the project tags. They are found by their prefix instead. Anything
that audits by tag needs to know this.

The same stack also carries an `aws_ecr_repository_creation_template` matched on the cache prefix.
ECR applies no lifecycle policy to repositories it creates through a cache rule, so without a
template every image ever pulled accumulates in the private registry at the per-GB-month rate. The
template keeps a bounded number of images per repository and leaves tag mutability alone, because
immutability would stop ECR refreshing an image behind an existing tag.

## Sources

- Sync an upstream registry with an Amazon ECR private registry, for the supported upstream list and
  which of them need a secret:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html>
- Creating a pull through cache rule in Amazon ECR, for the exact upstream registry URLs
  (`public.ecr.aws`, `registry.k8s.io`, `quay.io`, `registry-1.docker.io`):
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache-creating-rule.html>
- Storing your upstream repository credentials in an AWS Secrets Manager secret, for the mandatory
  `ecr-pullthroughcache/` name prefix, the `username` and `accessToken` key names, and "You must use
  the default `aws/secretsmanager` encryption key to encrypt your secret. Amazon ECR doesn't support
  using a customer managed key (CMK) for this":
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache-creating-secret.html>
- `aws_ecr_repository_creation_template` resource, `custom_role_arn` "Required if using repository
  tags or KMS encryption":
  <https://registry.terraform.io/providers/hashicorp/aws/6.63.0/docs/resources/ecr_repository_creation_template>
- Automate the cleanup of images by using lifecycle policies in Amazon ECR, for the `tagStatus`,
  `countType` and `imageCountMoreThan` parameter names:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html>
- `aws_ecr_pull_through_cache_rule` resource arguments, which include no `tags`:
  <https://registry.terraform.io/providers/hashicorp/aws/6.63.0/docs/resources/ecr_pull_through_cache_rule>
- `aws_secretsmanager_secret` resource, `recovery_window_in_days` accepts 0 or 7 to 30:
  <https://registry.terraform.io/providers/hashicorp/aws/6.63.0/docs/resources/secretsmanager_secret>
