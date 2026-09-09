# infra/bootstrap

The stack everything else stands on: two S3 buckets, an ECR pull-through cache, the tagging baseline,
and a handful of SSM parameters that let the cluster stack find all of it without reading anyone's
Terraform state.

It is small on purpose. Nothing here runs, nothing here scales, and nothing here is interesting
except that the rest of the project cannot be applied until it exists.

## The chicken and the egg

`infra/cluster` keeps its state in S3 with native locking. The bucket that backend points at is
`aws_s3_bucket.this["tfstate"]`, created by this stack. So this stack cannot use that backend
itself: on a clean account the bucket does not exist yet, and Terraform will not create the thing
it needs in order to start.

There is no `backend` block in `versions.tf`. State is local, `terraform.tfstate` sits next to the
configuration, and it is gitignored. The same is true of `infra/guardrails`, for a different reason:
guardrails is destroyed last, after everything else including this stack, so putting its state in a
bucket that gets deleted before it does is the same circle drawn in the other direction.
Both decisions are written up in ADR 0020.

The practical consequence is that the local state file is the only copy. `scripts/` snapshots it to
`materials/guardrails/` after every apply. If you lose it you are importing two buckets, three or
four cache rules (depending on whether the Docker Hub rule has been applied), a secret and a fistful
of parameters by hand.

The cluster stack's backend uses `use_lockfile = true` and no DynamoDB table. ADR 0021 has the
version floor and the source.

## What it creates

Two buckets, hardened identically. Versioning on, server-side encryption on, all four public access
block settings on, and a bucket policy with two deny statements: one refusing plain HTTP through
`aws:SecureTransport`, one refusing TLS below 1.2 through `s3:TlsVersion`. Conditions in a single
statement are ANDed, which is why it is two statements and not one with two conditions.

Both statements additionally require `aws:PrincipalIsAWSService` to be false. AWS redacts the
network authorization context on service-to-service calls, and `aws:SecureTransport` and
`s3:TlsVersion` are among the keys redacted, so a Deny on those keys alone blocks AWS service
principals rather than exempting them. Excluding them is what AWS documents for this pattern. Nothing
in the project uses that path yet, but S3 Inventory output, a replication destination or CloudTrail
data-event delivery into the weights bucket would, and each would fail as an AccessDenied that looks
nothing like a TLS problem.

They differ only in their lifecycle rules.

The state bucket keeps history, because a state file is exactly the thing you want a previous
version of at three in the morning. Noncurrent versions expire after
`state_noncurrent_version_expiration_days`, except that the newest
`state_noncurrent_versions_retained` of them survive regardless of age.

The weights bucket keeps almost none. A superseded weights file is dead the moment it is superseded,
so noncurrent versions go after `weights_noncurrent_version_expiration_days` and delete markers with
nothing under them are cleaned up.

Both abort incomplete multipart uploads after `abort_incomplete_multipart_upload_days`. This is the
rule that actually matters for the weights bucket: a failed multi-gigabyte `s5cmd cp` leaves its
parts in the bucket, the parts are billed as storage, and they are invisible in the console object
listing. Without this rule they sit there until someone runs `list-multipart-uploads`, which nobody
does.

The ECR pull-through cache gets one rule per upstream registry, all of them under the
`ecr_cache_prefix` namespace. See below.

The SSM parameters are all plain strings under `/llm-eks/bootstrap/`.

## What it costs

No dollar figures appear here. This project has taken no measurements yet, and Rule 5 says a number
in prose has to trace to a file under `materials/`. What follows names the pricing dimensions so
that the numbers can be filled in from a real Cost Explorer export later.

The weights bucket stays in S3 Standard. The tempting move is S3 Standard-IA, and it is wrong here
for two reasons that AWS documents plainly. Standard-IA charges a per-GB retrieval fee, and every
cold GPU node start is a full retrieval of the weights. Standard-IA also bills a 30 day minimum
storage duration per object, so an object written and deleted inside a cloud window is billed for
30 days anyway. A project measured in hours of cluster uptime never reaches the crossover point.

S3 Intelligent-Tiering is the other tempting move, and the argument against it is narrower than the
one against Standard-IA. AWS gives Intelligent-Tiering no minimum storage duration, no minimum
billable object size and no retrieval fees, so none of the objections above apply to it. What it adds
is a per-object monitoring and automation fee, which is not charged on objects below 128 KB. This
bucket holds a small number of very large objects, read in full on every cold node start, which keeps
them in the Frequent Access tier, priced the same as S3 Standard. The fee is small at this object
count and it buys tiering that does not happen, which is a reason not to bother rather than a reason
it would be expensive. ADR 0023 has the reasoning and the sources.

Egress is the dimension that will actually bite, and it is not an S3 charge. Data transfer from S3
to EC2 in the same Region is not billed. Data transfer that leaves a private subnet through a NAT
gateway is billed twice over: an hourly NAT gateway charge and a per-GB NAT gateway data processing
charge, applied to every gigabyte regardless of where it is going, including gigabytes going to S3
in the same Region. Pulling a set of FP16 weights down to each new Spot node through a NAT gateway
is the single largest avoidable line item this project can generate.

The fix is an S3 gateway VPC endpoint, which has neither an hourly nor a data processing charge, and
routing the weights traffic through it instead. That endpoint belongs to `infra/cluster`, not here,
but it is this bucket's cost problem so it is written down here. The same argument applies to the
ECR pull-through cache: images pulled from the cache come from ECR inside the Region rather than
across the internet, which is half the point of having it.

The other dimensions to watch on these two buckets are storage per GB-month, PUT and GET request
counts (the weights bucket is read in multipart chunks, so the request count is not small), ECR
private registry storage per GB-month for whatever the cache pulls in, and the per-secret monthly
charge plus per-10,000-API-call charge for the one Secrets Manager secret.

## The ECR pull-through cache

ECR only caches from a fixed list of upstreams. ECR Public, the Kubernetes registry and Quay need no
credentials. Docker Hub, Azure Container Registry, GitHub Container Registry, GitLab (SaaS only) and
Chainguard all require credentials in a Secrets Manager secret. ECR-to-ECR requires an IAM role
instead. This stack configures the four upstreams the project pulls from:

| key | upstream | repository prefix | credentials |
| --- | --- | --- | --- |
| `ecr-public` | `public.ecr.aws` | `llm-eks-cache/ecr-public` | none |
| `kubernetes` | `registry.k8s.io` | `llm-eks-cache/kubernetes` | none |
| `quay` | `quay.io` | `llm-eks-cache/quay` | none |
| `docker-hub` | `registry-1.docker.io` | `llm-eks-cache/docker-hub` | Secrets Manager |

`ecr_repository_prefix` is capped at 30 characters, which is why `ecr_cache_prefix` is validated at
19 or fewer: the longest suffix this stack appends is `/kubernetes`.

### Cached repositories expire

ECR creates a repository on my behalf the first time something is pulled through a cache rule, and
the settings it applies by default include no lifecycle policy. Every tag ever pulled would then sit
in the private registry being billed per GB-month until deleted by hand.

`aws_ecr_repository_creation_template.cache` matches the `llm-eks-cache` prefix, applies only to the
pull-through cache path, and attaches a lifecycle policy that keeps the most recent
`ecr_cache_images_retained` images per repository. One rule, tag status `any`, count type
`imageCountMoreThan`. Rule priority and tag status interact in ways that are easy to get subtly
wrong, and a single bound on repository size is all this needs to do.

Tag mutability stays `MUTABLE`. Turning on immutability for a repository fed by a pull-through cache
stops ECR refreshing an image behind an existing tag, which is the whole mechanism.

The template sets no `resource_tags`, because that requires a `custom_role_arn` and therefore an IAM
role. Cached repositories are found by prefix instead.

### The secret, and why the Docker Hub rule is off by default

Rule 2c says registry credentials live in Secrets Manager and are referenced by ARN, never in code.
The question this stack had to answer is whether to create the secret container here or to take an
ARN as a variable.

It creates the container. Taking an ARN as a variable means the ARN is typed by a human into a
tfvars file, at which point it is a value that can be wrong, that has to be passed around, and that
makes this stack unappliable on a clean account until someone has clicked through the Secrets
Manager console first. Creating the container here makes the ARN a resource attribute: predictable,
referenced by expression, and destroyed with the stack. The secret value never enters this
repository, never enters Terraform state, and is never read by any code here. There is no
`aws_secretsmanager_secret_version` resource in this directory and there should never be one.

The cost is that the first apply creates an empty secret, and ECR refuses a pull-through cache rule
whose credential does not validate. So the Docker Hub rule is held behind `enable_dockerhub_cache`,
default false. The sequence is:

1. Apply with the default. Three cache rules and an empty secret are created.
2. Put the value into the secret by hand, inside a cloud window. It is an "other type of secret"
   with two key/value pairs, `username` and `accessToken`, the token being a Docker Hub access
   token rather than the account password. Keep the default `aws/secretsmanager` encryption key:
   ECR does not support a customer managed key for these secrets.
3. Apply again with `enable_dockerhub_cache = true`, which creates the fourth rule.

The secret name is fixed at `ecr-pullthroughcache/llm-eks-docker-hub`. The `ecr-pullthroughcache/`
prefix is mandatory, not cosmetic: without it ECR will not accept the ARN and the console will not
list the secret. ADR 0024 has the details.

## Cross-stack values

Everything the cluster stack needs from here is published as an SSM parameter under
`/llm-eks/bootstrap/`:

| parameter | value |
| --- | --- |
| `tfstate-bucket` | state bucket name |
| `weights-bucket` | weights bucket name |
| `ecr-cache-namespace` | `llm-eks-cache`, the namespace the per-upstream prefixes sit under |
| `ecr-registry-url` | `<account>.dkr.ecr.<region>.amazonaws.com` |
| `ecr-cache-repository-prefix/<key>` | full prefix per upstream, one per row of the table above |

The consumer reads them with `data "aws_ssm_parameter"`. It does not read this stack's state,
because this stack's state is a file on somebody's laptop. ADR 0022.

The per-registry prefixes are published for all four upstreams, including Docker Hub, whether or not
its rule has been created yet. The name is knowable before the rule exists and the cluster stack
should not have to care which apply it is on.

`ecr-cache-namespace` is named the way it is on purpose. `llm-eks-cache` is not a usable repository
prefix on its own: no cache rule is created with it, so an image reference built as
`<ecr-registry-url>/llm-eks-cache/<image>` resolves to nothing. The values a consumer wants are the
`ecr-cache-repository-prefix/<key>` entries, which already carry the `/`-suffixed form. The namespace
is published for the two things that legitimately need the bare value: the repository creation
template prefix and IAM resource patterns that have to cover every cached repository at once.

## Tags

`local.default_tags` carries `Project`, `Stack` and `ManagedBy`, applied through the provider's
`default_tags` block rather than resource by resource. `mise run audit` and the guardrails sweeper
both select on `Project=terraform-llm-eks`, so a resource that loses this tag is a resource the
safety net cannot see. Note that `aws_ecr_pull_through_cache_rule` takes no tags at all, in this
provider version or in the API, so the cache rules are found by their prefix instead.

## Applying it

Local state, so there is nothing to configure and nothing to migrate.

```sh
mise run up WINDOW_ID=<n> WINDOW_HOURS=<h>
```

Never by hand, and never outside a cloud window. `mise run up` arms the one-shot kill timer before it
applies anything, and `mise run down` will not disarm it until `mise run audit` reports zero orphans.
The buckets are empty at creation and the cache rules cost nothing until something pulls through
them, but the Secrets Manager secret starts billing the moment it exists.

Locally, with no credentials, the stack is checked with:

```sh
terraform init -backend=false
terraform validate
tflint
trivy config .
```

`-backend=false` is what makes the first of those work without reaching S3, and it matters more here
than in the other stacks: there is no backend block to initialise, and the bucket a backend would
point at is one this stack has not created yet. The waived `trivy` findings are inline
`#trivy:ignore` comments next to the resources they cover, not a `.trivyignore` file; every one of
them is listed at the bottom of this file with its reason.

## Tearing it down

`force_destroy_buckets` is false by default, so `terraform destroy` will refuse while either bucket
still holds objects. That is the intended behaviour for every window except the last one, where the
weights bucket holds real data and emptying it by hand first is a waste of the window. Set the
variable to true only in the final teardown, and only after you are sure the weights are either
disposable or copied somewhere else.

The Secrets Manager secret is created with `recovery_window_in_days = 7` rather than the default 30.
A deleted secret in its recovery window is still a resource, and a resource that outlives the final
audit is exactly what `mise run audit` exists to catch.

## Deliberate deviations from the scanners

Three `trivy config` checks are waived in place, each with a scoped `#trivy:ignore` comment.

`AVD-AWS-0132`, bucket does not encrypt with a customer managed key. Both buckets use SSE-S3
(`AES256`) with S3 Bucket Keys enabled. SSE-KMS bills per KMS request, and the weights bucket is
read in thousands of multipart chunks per node start. ADR 0025.

`AVD-AWS-0098`, secret explicitly uses the default key. ECR does not support a customer managed key
for pull-through cache credentials; the AWS documentation is explicit that the default
`aws/secretsmanager` key must be used. This one is not a trade-off, it is a constraint.

`AVD-AWS-0089`, bucket has logging disabled. Server access logging needs a third bucket, which
cannot itself be logged without another one, and it bills per log object written. CloudTrail
management events already record every configuration call made against these buckets at no charge.
Object-level access is not audited here, and that is an accepted gap rather than an oversight.
