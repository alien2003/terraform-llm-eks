# 0062. Karpenter's dry-run validation is off, because GpuSpotOnly refuses it

Date: 2026-11-26

## Status

Accepted. Supersedes ADR 0048. ADR 0047 turned the same setting off for a reason that turned out to be
wrong; this record turns it off for one that was observed.

## Context

ADR 0048 put Karpenter's NodeClass validation back on, so that a boundary refusing Karpenter would show
up on the EC2NodeClass right after the apply.

In window 1, attempt 3 (2026-11-26), the general NodeClass validated and the GPU one did not:
`ValidationSucceeded=False`, reason `RunInstancesAuthCheckFailed`, "User is not authorized to perform
this operation due to a permission boundary". With the NodeClass not Ready, the GPU NodePool was not
Ready either, so no GPU node could launch.

CloudTrail had the calls, all from `llm-eks-karpenter-controller` between 19:56:44Z and 19:56:47Z:

| Instance type | Market in the request | Result |
| --- | --- | --- |
| `t3.medium` | none (on-demand) | `Client.DryRunOperation` |
| `g6.xlarge` | none (on-demand), six calls | `Client.UnauthorizedOperation` |

The validation's dry-run `RunInstances` names no `InstanceMarketOptions`, so EC2 treats it as an
on-demand request. `g6.xlarge` is on the instance whitelist; the statement that refuses it is
`GpuSpotOnly`, which denies a GPU type whose `ec2:InstanceMarketType` is not `spot`. The boundary did
what it is for. The validation asked a question the real launch never asks.

ADR 0048 missed this because the only refusal it had seen was `InstanceTypeWhitelist` on `CreateFleet`.

## Decision

`settings.disableDryRun: true` in `values/karpenter.yaml`.

It was applied inside the window, on the author's decision, as a plan of one in-place change to
`helm_release.karpenter`, about 35 s. The NodeClass and NodePool were Ready at the first check after the
rollout, 20:08:10Z. The first real fleet
for the GPU NodeClaim, Spot `g6.2xlarge`, launched at 20:12:08Z and the node was Ready at 20:13:01Z.

## Consequences

The NodeClass status no longer says anything about the boundary. The first real launch does, as a
NodeClaim event; the platform README's check 8 says to decode it there.

The real launch path stays under the boundary. A Karpenter fleet authorizes `ec2:RunInstances` per
instance with the type and the market in the context (ADR 0018, Revised), so `GpuSpotOnly` and
`InstanceTypeWhitelist` still decide it. The Karpenter GPU NodePool also lists only `spot`.

There is no per-NodeClass switch for validation, so the general NodeClass loses it too. It was never the
one at risk.

## Sources

- Karpenter v1.14.1 chart values, `settings.disableDryRun`.
  https://github.com/aws/karpenter-provider-aws/blob/v1.14.1/charts/karpenter/values.yaml
- Karpenter v1.14.1 NodeClass validation controller.
  https://github.com/aws/karpenter-provider-aws/blob/v1.14.1/pkg/controllers/nodeclass/validation.go
- Evidence in the working notes: `materials/guardrails/w1c/cloudtrail-runinstances-validation.json`,
  `ec2nodeclass-gpu-validation-failed.yaml`, `karpenter-disabledryrun-plan.txt` and `-apply.txt`,
  `materials/measurements/provisioning/w1c-nodeclaim-ready.txt`.
