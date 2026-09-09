# infra/cluster

The VPC, the EKS control plane, one small managed node group, and the AWS half of Karpenter.

This is the only stack in the project that creates something with a meaningful hourly price. It is
applied inside a cloud window and destroyed before that window closes. Nothing here is meant to
survive between windows.

## What it creates

A VPC with three private subnets and three public subnets, one of each per Availability Zone, a single
NAT gateway, and a gateway endpoint for S3. The zones are the ones EC2 actually offers the GPU
instance types in; see below.

An EKS cluster named `llm-eks`, `authentication_mode = "API"`, with four addons: `vpc-cni` and
`eks-pod-identity-agent` before the first node exists, then `coredns` and `kube-proxy`.

One EKS managed node group, `system`, on demand, carrying the label `llm-eks.io/role=system`. It runs
the Karpenter controller, CoreDNS and whatever the platform layer puts on it. Karpenter cannot
schedule the node that Karpenter runs on, which is the whole reason this node group exists. ADR 0035.

The AWS side of Karpenter, from the eks module's own `karpenter` submodule: the controller role and
its policy, an EKS Pod Identity association for `kube-system/karpenter`, the node role, an instance
profile, an access entry for the node role, the SQS queue `llm-eks-karpenter-interruption`, and five
EventBridge rules that feed it. ADR 0033 lists them and says where the list came from.

An access entry for the operator role with `AmazonEKSClusterAdminPolicy` scoped to the cluster, so
that `aws eks update-kubeconfig` works from the operator profile and nothing has to be added to an
`aws-auth` ConfigMap.

A set of SSM parameters under `/llm-eks/cluster/` that the platform layer reads.

It does not create a KMS key. The cluster keeps the envelope encryption EKS applies by default, with a
key AWS owns, rather than the customer-managed key the eks module creates if left alone. That takes two
explicit arguments in `eks.tf`, and it is why AVD-AWS-0039 is suppressed. ADR 0036 has the trade-off
and names the pricing dimensions a customer-managed key would add.

And, in the second half of the apply, everything inside the cluster: `platform/` is a child module of
this stack, called from `platform.tf`, and the `kubernetes` and `helm` providers it uses are
configured in `providers.tf`. It was a separate root stack until the review before window 0 found that
nothing could apply it: it has no backend, no provider blocks and seven inputs with no defaults, and
`mise run up` was pointing at it as though it were a stack. One state file, one backend and one place
where those two providers are configured is the shape that works. ADR 0037.

The module is behind `platform_enabled`, which is what makes the apply two-phase. That is the next
section, and it matters more than a flag usually would.

## Applying it

```sh
mise run up WINDOW_ID=<n> WINDOW_HOURS=<h>
```

Never by hand, and never outside a cloud window. `mise run up` arms the one-shot kill timer before it
applies anything, and `mise run down` will not disarm it until `mise run audit` reports zero orphans.

Locally, with no credentials, the stack is checked with:

```sh
terraform init -backend=false
terraform validate
tflint
trivy config .
```

`-backend=false` is what makes the first of those work without reaching S3. Run `trivy` with this
directory as the working directory so it picks up the `.trivyignore` next to this file; every entry in
there is an accepted finding with the reason written out.

`platform/` still holds its own `versions.tf` and its own lock file, so `terraform -chdir=platform init
-backend=false && terraform -chdir=platform validate` keeps working on its own. `mise run lint`
discovers stacks by looking for directories containing `.tf` files, so it finds and validates both this
directory and `platform/`, and gives each its own `trivy` pass against its own `.trivyignore`. Terraform
ignores a lock file in a child module, so `platform/.terraform.lock.hcl` exists only to pin that
standalone check to the same three providers this directory pins.

## Two applies, not one

**A first apply of an empty state runs twice, and the second command is not optional.**

```sh
terraform apply -var platform_enabled=false   # VPC, cluster, node group, Karpenter's AWS side
terraform apply                               # everything inside the cluster
```

The reason is a property of the `kubernetes` provider, not a choice. A provider block can only be
configured from values that are already known, and on a first apply the cluster endpoint and CA
certificate are not: they are created by the same apply. HashiCorp's own documentation says so under
"Stacking with managed Kubernetes cluster resources": resources exposing cluster credentials "SHOULD
NOT be created in the same Terraform module where Kubernetes provider resources are also used", and
"The most reliable way to configure the Kubernetes provider is to ensure that the cluster itself and
the Kubernetes provider resources can be managed with separate apply operations."

I measured what that means for the exact versions this repository pins rather than taking the warning
on faith. On Terraform 1.16.1 with kubernetes 3.2.1 and helm 3.3.0, a throwaway configuration whose
provider host was a value only known after apply fails during `terraform plan`, before anything is
created, with:

```text
Error: Provider configuration: cannot load Kubernetes client config
invalid configuration: default cluster has no server defined
```

Three details from that run are why the code looks the way it does. The `helm` provider planned the
same configuration without complaint, so this is the `kubernetes` provider specifically, and the
platform module needs it for its namespaces and dashboard ConfigMaps. Putting `count = 0` on the module
does not avoid it: the module still declares the provider, Terraform still configures it, and the plan
still fails in the same words. And a placeholder host with no CA certificate configures cleanly and
never invokes the `aws eks get-token` exec plugin, so the first phase talks to no API server and to no
cluster that does not exist.

The flag defaults to true, so it is only ever typed on that first apply. Everything afterwards, every
later plan and the `terraform destroy` inside `mise run down`, runs with the default and works, because
the endpoint is a known value once the cluster is in state. A destroy with the flag off would try to
remove in-cluster resources through a provider pointed at a host that does not resolve, and a teardown
that cannot finish is the worst thing that can happen to a window.

Two consequences for the window protocol. `mise run up` has to run two applies for this stack, the
first with `-var platform_enabled=false`, and both belong in the rehearsed command list in
`WINDOW-<n>-PLAN.md` before approval is asked for, because a surprise second apply inside a timed
window is exactly what that rehearsal exists to prevent. And a change that *replaces* the EKS cluster
makes the endpoint unknown again, which puts the stack back into phase one; if a plan ever fails with
the error above on a cluster that already exists, that is what happened.

The second apply also needs `grafana_admin_secret_arn`. The secret is created by hand inside the
window and its ARN cannot be derived, because Secrets Manager appends a hyphen and six random
characters to the name so that a delete and recreate produce different ARNs. A plan without it stops at
a variable validation rather than at an IAM policy with an empty resource.

## The network, and why it costs what it costs

The cost decision in this stack is the NAT gateway, not the cluster.

A NAT gateway bills per NAT Gateway-hour whether or not anything is behind it, plus a data-processing
charge per gigabyte through it, plus standard data transfer, and its Elastic IP carries the public
IPv4 address hourly charge. Partial hours bill as full hours. Three zones with one gateway each would
be three of every one of those meters running from the moment the VPC exists to the moment it is
destroyed, with a GPU node present for only part of that.

An interface VPC endpoint bills per endpoint-hour in every zone it has a network interface in, plus a
data-processing charge per gigabyte. Replacing the NAT gateway with endpoints means six or seven of
them, times three zones.

A gateway endpoint, which exists only for S3 and DynamoDB, has no hourly charge and no
data-processing charge.

So: one NAT gateway (`single_nat_gateway = true`), an S3 gateway endpoint always, and interface
endpoints off unless `interface_endpoint_services` names some. The S3 endpoint matters more than its
size suggests, because the two largest flows in this project, model weights out of the weights bucket
and container layers behind ECR, both come out of S3 and now skip the NAT gateway's data-processing
meter entirely.

What that buys is paid for twice. Nodes in the two zones the gateway is not in pay cross-zone data
transfer to reach it. And there is one zone of egress failure for the whole VPC. Both are acceptable
for something that lives for hours; neither would be for a production cluster.

No dollar figures appear above on purpose. Rule 5: every number in this repository traces to a file in
`materials/`, and Phase 1 has measured nothing. The per-window figures go in
`materials/costs/windows.md` after the first window closes. ADR 0030 has the full reasoning and the
sources.

Subnets are tagged three ways. `kubernetes.io/role/elb` on the public ones and
`kubernetes.io/role/internal-elb` on the private ones, which is how the AWS Load Balancer Controller
discovers where it may put a load balancer. And `karpenter.sh/discovery = llm-eks` on the private
subnets and on the node security group, which is what the platform layer's EC2NodeClass selects on.

The private subnets are a `/20` per zone and the public ones a `/24` per zone, cut out of the same
`/16`. The public block starts high, at `10.42.240.0/24` with the default `vpc_cidr`, so that it
cannot land inside a private `/20` at the higher end of the `az_count` range.

That fixed offset is why `vpc_cidr` is validated to a prefix between `/16` and `/20`. A narrower block
either makes `cidrsubnet` fail, which happens during `terraform plan` and therefore inside a window, or
produces public subnets below the `/28` minimum AWS will create, which does not fail until
`CreateSubnet`. The validation moves both to `terraform validate`, which runs with no credentials.

## Tagging

`Project`, `Stack` and `ManagedBy` come from the provider's `default_tags` block in `providers.tf`,
not from per-resource `tags` arguments. `mise run audit` and the guardrails sweeper both select on
`Project=terraform-llm-eks`, so a resource that misses the tag is a resource the safety net cannot
see.

`default_tags` does not cover everything. It reaches a resource's own tags, including the launch
template's, but not the launch template's `tag_specifications` blocks, and those are what tag the
instances, the root volumes and the network interfaces the managed node group launches. EKS node group
tags do not cover it either; AWS documents that they do not propagate to the node group's EC2
instances. So `eks.tf` passes the same baseline into the eks module as `tags`, which is what the module
merges into those blocks. Without it the system nodes would run carrying nothing but a `Name` tag,
which is precisely the case `scripts/audit.sh` fails on.

## Availability Zones

A subnet in a zone that does not offer `g6.xlarge` is a subnet the GPU NodePool can never use. So the
zones are not the first three the account can see; they are the intersection of the zones offering
every type in `gpu_instance_types`, minus the zone IDs in `excluded_zone_ids`, minus Local Zones.

`use1-az3` is in that exclusion list because AWS documents it as a zone EKS cluster subnets cannot
reside in. It is excluded by zone ID rather than by name, because zone names are per account and zone
IDs are not.

There is a trap here and the stack is built around it. If the zone list is recomputed from the API on
every plan, then a change in EC2's offering table renumbers the subnets, and Terraform replaces the
VPC, the cluster and everything in it during what looked like a no-op plan. So:

**After window 0, pin `availability_zones`.** The discovery run prints the candidates as the
`gpu_capable_availability_zones` output. Copy them into the variable. From that point the zone set is
a decision in the repository, and a `check` block warns, rather than acting, if EC2's offering
changes underneath it. ADR 0034.

Two things are hard stops rather than warnings. Fewer than two usable zones: EKS needs subnets in at
least two, and a one-zone VPC builds fine and then fails inside `CreateCluster`, in a window that is
already being billed. And a pinned `availability_zones` entry that this account cannot use at all,
whether that is a typo, a zone from another region, a Local Zone, or a zone `excluded_zone_ids` rules
out, all of which fail at `CreateSubnet` part way through building the VPC.

Both of those are `lifecycle` preconditions rather than `check` blocks, because a failed `check`
assertion is only a warning: Terraform prints it and carries on planning and applying. A precondition
stops the plan. They sit on a `terraform_data` resource, which creates nothing and calls no API.

## Things that are deliberately not pinned yet, and must be

Rule 4 says pin every version. Two things here are floating, because a valid value for either cannot
be written without asking the API, and there are no credentials in Phase 1.

`addon_versions` is empty, so each addon resolves to the most recent version at apply time. In window
0, run `aws eks describe-addon-versions --kubernetes-version 1.35` and fill the map in.

`system_node_ami_release_version` is null, so the node group tracks the latest EKS optimized AMI
release for its AMI type. In window 0, read the release version the node group resolved and pin it.

Both are variables with a null or empty default rather than a plausible-looking string, which is the
point. A version invented from memory is worse than an obvious gap.

## Identity

Everything uses EKS Pod Identity, not IRSA. The Karpenter controller's role trusts
`pods.eks.amazonaws.com` and is bound to `kube-system/karpenter` by an association resource; the
`eks-pod-identity-agent` addon is installed before compute so the agent is on the node before anything
asks it for credentials. The cluster's IAM OIDC provider is still created, because it costs nothing
and some upstream charts still only document the IRSA annotation. ADR 0031.

Every IAM role this stack creates carries the operator permission boundary, `llm-eks-operator-boundary`.
That is not decoration. The boundary denies `iam:CreateRole` outright unless the new role's
`iam:PermissionsBoundary` is that exact policy ARN, so an apply that forgets it fails rather than
quietly creating an unbounded role. The ARN is derived in `locals.tf` from the account ID and the
policy name, because `infra/guardrails` keeps local state and cannot be read with a remote state data
source.

## What the platform layer gets from here

The module call in `platform.tf` passes it directly: the cluster name and endpoint, the boundary ARN,
`window_id`, Karpenter's namespace, service account, queue name and node instance profile, the GPU and
system instance type lists, the system node label, the weights bucket name read from
`/llm-eks/bootstrap/weights-bucket`, and `grafana_admin_secret_arn`. The argument list is the one
`platform/README.md` writes out, because the module's variables were written against it.

`window_id` is the one worth naming twice. The platform module builds its own tag map and adds
`Window` only when that value is non-empty, and its EC2NodeClass `spec.tags` is what carries the map
onto a GPU node and its volume. Provider `default_tags` cannot reach those, because Karpenter creates
them and Terraform never sees them. `mise run up` passes `-var window_id=<n>` to every stack that
declares the variable, this one included, so the chain is closed; with it empty a GPU node would still
be visible to the sweeper and the audit by `Project`, but no window could be billed against it.

The same values are also published as Terraform outputs and as SSM parameters under
`/llm-eks/cluster/`. Those are not how the module reads them any more, but they earn their keep twice
over: they are what I read with the CLI in the middle of a window without running Terraform, and they
are what a reader of `platform/` sees as the documented interface when that directory is validated on
its own. ADR 0022.

| Parameter | What it is for |
| --- | --- |
| `cluster-name`, `cluster-endpoint`, `cluster-arn`, `cluster-version` | building a kubeconfig and the Helm values |
| `cluster-security-group-id`, `cluster-primary-security-group-id`, `node-security-group-id` | security group references |
| `oidc-provider-arn` | empty unless `enable_irsa` is on |
| `vpc-id`, `vpc-cidr`, `private-subnet-ids`, `public-subnet-ids`, `availability-zones` | network references |
| `karpenter-queue-name` | the Karpenter Helm chart's interruption queue setting |
| `karpenter-controller-role-arn`, `karpenter-namespace`, `karpenter-service-account` | the Pod Identity association already made here |
| `karpenter-node-role-name`, `karpenter-node-role-arn`, `karpenter-node-instance-profile-name` | the EC2NodeClass identity |
| `karpenter-discovery-tag-key`, `karpenter-discovery-tag-value` | the EC2NodeClass subnet and security group selectors |
| `system-node-label-key`, `system-node-label-value` | the nodeSelector that keeps system workloads on the managed node group |
| `gpu-instance-types` | the requirement list on the GPU NodePool |
| `region` | everything |

The EC2NodeClass should set `spec.instanceProfile` to `karpenter-node-instance-profile-name`, not
`spec.role`. The reason is in ADR 0033: an instance profile Karpenter generates for itself does not
carry this project's tags, which makes it invisible to `mise run audit` and to the guardrails sweeper,
and it can outlive a teardown that removes the controller first.

## Teardown

Karpenter creates nodes outside Terraform's state, so `terraform destroy` on its own can leave
instances running. The order is: delete the workload, let Karpenter reap its nodes, then destroy. This
is what `mise run down` does, and `mise run audit` is what proves it worked.

If the audit finds anything, fixing it is the only permitted activity until it comes back clean.
Rule 2b.

The destroy runs with `platform_enabled` at its default, which is why the default is true. The cluster
endpoint is in state by then, so the `kubernetes` and `helm` providers configure against the real API
server and can remove what they created. Passing `-var platform_enabled=false` to a destroy would point
them at a host that does not resolve and leave the in-cluster half undeletable.

## Layout

| File | What is in it |
| --- | --- |
| `versions.tf` | Terraform and AWS provider pins |
| `backend.tf` | S3 backend with native locking |
| `providers.tf` | the `default_tags` baseline and where it does not reach, and the `kubernetes` and `helm` configuration |
| `variables.tf` | every input, with the cost reasoning in the descriptions |
| `data.tf` | caller identity, zone discovery, the two zone preconditions, the offering-drift `check`, the weights bucket lookup |
| `locals.tf` | tags, zone and subnet arithmetic, discovery tags, the published values |
| `vpc.tf` | the VPC module, the S3 gateway endpoint, optional interface endpoints |
| `eks.tf` | the EKS module and the system node group |
| `karpenter.tf` | the karpenter submodule |
| `platform.tf` | the `platform` child module call, behind `platform_enabled` |
| `ssm.tf` | the `/llm-eks/cluster/` parameters |
| `outputs.tf` | the same values as outputs, plus the module's own |
| `.trivyignore` | accepted findings, each with its reason |

`platform/` has a separate owner and its own README, its own `versions.tf`, its own lock file and its
own `.trivyignore`. Nothing in this directory writes into it; `platform.tf` only calls it.
