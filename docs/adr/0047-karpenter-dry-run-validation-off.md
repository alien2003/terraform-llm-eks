# 0047. Karpenter's dry-run validation is off

Date: 2026-11-20

## Status

Accepted. The permission boundary is unchanged. ADR 0040 is why the NodeClasses and NodePools share one
Helm release, which is where the race below comes from.

## Context

In window 1 both EC2NodeClasses stayed at `ValidationSucceeded=False` with
`CreateFleetAuthCheckFailed: Controller isn't authorized to call ec2:CreateFleet ... due to a permission
boundary`. Karpenter refuses to launch from a NodeClass in that state, so no node came up and the window
ended without a GPU.

The boundary is not what is wrong. I ran `iam simulate-custom-policy` against the live boundary's EC2
statements for `ec2:CreateFleet` on `instance/*`. With `Project=terraform-llm-eks` in the request,
`t3.medium`, `m7i.large`, `g6.xlarge` and `g6.2xlarge` are allowed, and `m5.large` and `m6g.large` hit
`InstanceTypeWhitelist`. The NodeClass tags carried `Project`, so the tag Deny does not apply.

What Karpenter 1.14.1 sends is in `pkg/controllers/nodeclass/validation.go`. The dry-run `CreateFleet`
carries one instance type: the first one compatible with a NodePool that references the NodeClass. When
no such NodePool exists yet, it falls back to `m5.large` and `m6g.large`. A failed check is cached for
30 minutes (`ValidationTTL` in `pkg/cache/cache.go`), the cache key is built from the NodeClass and its
tags with no NodePool in it, and the reconciler comes back every 10 minutes.

Here the NodeClasses and NodePools come from one Helm release, `llm-eks-nodepools`. The NodeClasses were
created at about 11:32:46Z and the failure was on their status within a minute. The controller validated
before it had seen a NodePool, asked for `m5.large`, was denied, and kept the answer for half an hour.

I did not see the `m5.large` request itself. The controller log I saved came from the pod that was not
the leader, and the operator role has no `cloudtrail:LookupEvents`. Everything above is from the source
and the simulation.

## Decision

`settings.disableDryRun: true` in `values/karpenter.yaml`. The chart turns it into `DISABLE_DRY_RUN` on
the controller, and the validation reconciler then marks the NodeClass validated without calling EC2.

The alternatives I rejected:

- Two Helm releases, NodePools first. Terraform destroys in reverse, so the NodeClasses would be deleted
  before the NodePools. The NodeClass termination finalizer waits for the NodeClaims that use it, and
  those only go when the NodePool does. That is a teardown that cannot finish.
- Re-validating after phase 2 by changing an annotation on the NodeClasses, which changes the cache key.
  It keeps the early check, but it is one more step in `mise run up` that depends on a cause I have not
  observed directly.
- Adding `m5.large` and `m6g.large` to the whitelist. Two instance types nobody costed, permitted so that
  a check can pass.

## Consequences

The first permission check is now the real `CreateFleet` for a NodeClaim, and it is decided by the same
boundary with the same whitelist. A refusal shows up as an `UnauthorizedOperation` in the NodeClaim's
events, with the instance type that was actually requested. If the race was the whole cause, the GPU
NodeClaim launches. If it was not, that event is the evidence this record is missing. Item 8 of
"Things to confirm in the first window" in the platform README says to save it either way.

What is lost is the early warning: a NodeClass with a real permission problem now reads Ready until
something tries to launch from it.

Worth adding at the next admin apply, not done here: `cloudtrail:LookupEvents` for the operator. It is a
read, and today's diagnosis stopped exactly where it was missing.

Sources:

- https://github.com/aws/karpenter-provider-aws/blob/v1.14.1/pkg/controllers/nodeclass/validation.go
- https://github.com/aws/karpenter-provider-aws/blob/v1.14.1/pkg/cache/cache.go
- https://github.com/aws/karpenter-provider-aws/blob/v1.14.1/charts/karpenter/values.yaml
- https://github.com/aws/karpenter-provider-aws/blob/v1.14.1/charts/karpenter/templates/deployment.yaml
