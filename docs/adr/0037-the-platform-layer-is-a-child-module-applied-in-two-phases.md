# 0037. The platform layer is a child module, and its apply is a second phase

Date: 2026-09-09

## Status

Accepted.

## Context

`infra/cluster/platform` was written as a child module: no backend, no provider blocks, seven inputs
with no defaults, and a README that spells out the `module "platform"` call the parent was supposed to
make. The parent never made it, and `mise run up` listed the directory as a stack and applied it as a
root module. That cannot work. With no `providers.tf` the `helm` and `kubernetes` providers fall back
to a kubeconfig outside the workspace, with no backend the state lands in a local file, and
`terraform apply -input=false -auto-approve` has no way to supply seven required variables. The review
before window 0 found this and called it a blocker: the failure lands after the kill timer is armed,
with a control plane and a NAT gateway already billing.

Two shapes were on the table. Finish it as a child module, or finish it as a root stack with its own
backend key, its own provider configuration and SSM lookups for its seven inputs.

The second shape has a real attraction, which is that it makes the phase separation physical: apply
one stack, then apply the other. It also doubles the state, doubles the init, and puts a second S3
object in the teardown path. And it does not remove the problem it looks like it removes, because the
same provider still has to be configured from the same cluster's endpoint; it only moves the moment
that value becomes known into a different state file.

Underneath both shapes is one constraint. A provider block can only be configured from values that are
already known, and on a first apply the cluster endpoint and CA certificate are not: the same apply
creates them. HashiCorp's own documentation warns about exactly this arrangement and says the reliable
answer is separate applies.

I measured the behaviour for the versions this repository pins rather than reasoning from the warning.
On Terraform 1.16.1 with `hashicorp/kubernetes` 3.2.1 and `hashicorp/helm` 3.3.0, a throwaway
configuration whose provider host was a value only known after apply fails during `terraform plan`,
before creating anything:

```text
Error: Provider configuration: cannot load Kubernetes client config
invalid configuration: default cluster has no server defined
```

Three results from that run shaped the decision. The `helm` provider planned the same configuration
without complaint, so the constraint belongs to the `kubernetes` provider, which the platform module
needs for its namespaces and its dashboard ConfigMaps. Putting `count = 0` on the module does not
avoid it: the module still declares the provider, Terraform still configures it, and the plan fails in
the same words. And a placeholder host with `cluster_ca_certificate` unset configures cleanly and never
invokes the exec plugin, so a phase-one plan reaches no API server at all.

## Decision

`platform/` stays a child module and is called from `infra/cluster/platform.tf`, with the `kubernetes`
and `helm` providers configured once in `infra/cluster/providers.tf`. `infra/cluster/platform` is not a
stack and is not in any stack list.

The call is behind `var.platform_enabled`, which defaults to true. A first apply of an empty state runs
twice: once with `-var platform_enabled=false`, which builds the VPC, the cluster, the node group,
Karpenter's AWS resources and the SSM parameters, and once with the default, which installs everything
inside the cluster. While the flag is false the two providers point at `https://kubernetes.invalid`, a
name RFC 2606 reserves so that it can never resolve, and carry no CA certificate.

The default is true rather than false because of the destroy. `mise run down` runs
`terraform destroy` with no extra variables, and the in-cluster resources can only be removed through a
provider configured against the real API server. A default of false would produce a teardown that
cannot finish, which is a worse failure than a first apply that needs a documented second command.

`platform/` keeps its own `versions.tf` and its own lock file so that
`terraform -chdir=platform init -backend=false && validate` still runs on its own, which is what CI and
`mise run lint` do for that directory.

## Consequences

`mise run up` has to run two applies for `infra/cluster`, the first with `-var platform_enabled=false`.
That is a change in `scripts/`, and both commands belong in the rehearsed list in
`materials/journal/WINDOW-<n>-PLAN.md` before approval is asked for. Rule 2b exists to keep a second
apply from being a surprise inside a timed window; this is one of the things it was written for.

Anything that replaces the EKS cluster makes the endpoint unknown again and puts the configuration back
into phase one. The symptom is the error above on a cluster that already exists, and the answer is the
same two commands.

The second apply needs `grafana_admin_secret_arn`, because the Grafana administrator secret is created
by hand inside a window and its ARN cannot be derived: Secrets Manager appends a hyphen and six random
characters to the name. A variable validation stops the plan when it is missing, rather than letting an
IAM policy be built with an empty resource. Publishing that ARN as an SSM parameter from whatever
creates the secret would make the second apply flagless, and is worth doing if the secret ever stops
being hand-made.

One state file now holds the cluster and everything in it, so a corrupted state or a stuck lock affects
both halves. That is the price of not having a second backend in the teardown path, and it is the
smaller risk for something that is created and destroyed inside a few hours.

## Sources

- Kubernetes provider, "Stacking with managed Kubernetes cluster resources": credentials-exposing
  resources "SHOULD NOT be created in the same Terraform module where Kubernetes provider resources are
  also used", and "The most reliable way to configure the Kubernetes provider is to ensure that the
  cluster itself and the Kubernetes provider resources can be managed with separate apply operations":
  <https://registry.terraform.io/providers/hashicorp/kubernetes/3.2.1/docs>
- Helm provider 3.x, the `kubernetes` attribute and its nested `exec` attribute, with the EKS
  `eks get-token` example: <https://registry.terraform.io/providers/hashicorp/helm/3.3.0/docs>
- AWS CLI reference for `aws eks get-token`, which shows the response is an `ExecCredential` with
  `"apiVersion": "client.authentication.k8s.io/v1beta1"`:
  <https://docs.aws.amazon.com/cli/latest/reference/eks/get-token.html>
- AWS Secrets Manager, why a secret ARN cannot be constructed from a name: "Secrets Manager constructs
  an ARN for a secret with Region, account, secret name, and then a hyphen and six more characters":
  <https://docs.aws.amazon.com/secretsmanager/latest/userguide/troubleshoot.html>
- RFC 2606, section 2: `.invalid` is reserved so that a name is guaranteed not to resolve:
  <https://www.rfc-editor.org/rfc/rfc2606#section-2>
- The plan-time behaviour above was measured locally on 2026-09-09 with the pinned Terraform and
  provider versions. No AWS API call was involved: the failing configuration used a built-in
  `terraform_data` resource as the source of the unknown value.
