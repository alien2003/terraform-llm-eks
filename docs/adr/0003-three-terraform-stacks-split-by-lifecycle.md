# 0003. Three Terraform stacks, split by lifecycle

Date: 2026-09-08

## Status

Accepted.

## Context

The natural first shape for a project this size is one root module with a couple of variables. Everything
plans together, everything applies together, and there is one state file to look after.

It does not survive contact with the way this project is actually operated. Three groups of resources here
have three different answers to the question "when is this destroyed?".

The guardrails are the operator role and its permission boundary, the budget, the anomaly monitor, the
billing alarm, the alert topic, the kill Lambda and the sweeper schedule. They are applied once, with
administrator credentials, before anything else exists, and they are destroyed last, after the final audit
is clean. They have to outlive every other resource in the account, because they are what makes the other
resources safe to create.

The bootstrap resources are the Terraform state bucket, the model weights bucket and the ECR pull-through
cache. They are applied once and then left alone. They cost close to nothing while idle and they hold data
that is expensive to recreate: a re-download of the model weights on every window is minutes of wall time
and a transfer bill for no reason.

The cluster is the VPC, the EKS control plane, the system node group and the AWS half of Karpenter. It is
created at the start of a window and destroyed before the window closes, over and over. It is the only part
with a meaningful hourly price.

Putting all three in one state file means every `terraform destroy` at the end of a window is aimed at the
same state that holds the boundary protecting me from that destroy, and every apply plans a diff over
resources that should not be in the plan at all. Targeting with `-target` on every run is a workaround, and
it is exactly the workaround that HashiCorp's own documentation describes as a tool for exceptional
recovery rather than routine use.

## Decision

Three stacks, each a root module with its own state, its own providers block and its own README:

`infra/guardrails`, applied with the administrator role, once, and destroyed last.
`infra/bootstrap`, applied as the operator, once, and destroyed second to last.
`infra/cluster`, applied and destroyed inside every window. The platform layer at `infra/cluster/platform`
is written to be a child module of it rather than a fourth stack, so that the Kubernetes objects will share
the cluster's lifetime instead of getting a fourth state file for no reason.

Values that cross a stack boundary are published as SSM parameters by the producing stack and read with a
data source by the consumer, which is ADR 0022. Where each stack keeps its state, and why it is not the
same answer for all three, is ADR 0004.

## Consequences

`mise run up` and `mise run down` operate on the cluster stack alone, which is what makes a window a
bounded thing rather than a plan over the whole account.

The cost is ordering. Nothing enforces that guardrails is applied before bootstrap, or bootstrap before the
cluster, other than the fact that the operator role does not exist until guardrails has run and the state
bucket does not exist until bootstrap has. In practice those two facts are the enforcement, and both fail
loudly rather than quietly.

The platform layer is wired in: `infra/cluster/platform.tf` holds the `module "platform"` block, the
cluster stack configures the `kubernetes` and `helm` providers for it, and a `platform_enabled` variable
gates the call. That gate is not decoration. A provider cannot be configured from a value the same apply
creates, so the cluster comes up in one apply and the layer goes on in a second. ADR 0037 records that and
the measurement behind it.

Being a child module rather than a fourth stack means it cannot be applied on its own. That is intended: a
NodePool without a cluster is not a useful thing to have. It still gets its own
`terraform init -backend=false` and `terraform validate` in CI, because the stack matrix is discovered from
every directory holding `.tf` files rather than written out, so the directory is checked as a standalone
root module as well as through its parent. That is how its chart values and CRD field names are checked with
no cluster and no credentials.

## Sources

- Terraform on `-target`: "Use `-target=ADDRESS` in exceptional circumstances only, such as recovering from
  mistakes or working around Terraform limitations."
  <https://developer.hashicorp.com/terraform/cli/commands/plan>
- The project's own naming, tagging and cross-stack conventions: [`docs/conventions.md`](../conventions.md)
