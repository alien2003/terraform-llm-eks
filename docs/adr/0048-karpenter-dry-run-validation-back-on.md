# 0048. Karpenter's dry-run validation is back on

Date: 2026-11-23

## Status

Accepted. Supersedes ADR 0047.

## Context

ADR 0047 turned off the dry-run `CreateFleet` that Karpenter runs when it validates an EC2NodeClass. It
blamed a race: validation before any NodePool existed, a fallback to `m5.large`, a whitelist deny cached
for 30 minutes.

Attempt 2 of window 1 ran with validation off. The NodeClasses read Ready, and the first real
`CreateFleet` for the GPU NodeClaim was refused by the same statement. ADR 0018 has the decoded context:
a tagged fleet's `instance/*` reaches the boundary with no `ec2:InstanceType`, so `InstanceTypeWhitelist`
denied every fleet, whatever type it asked for. There was no race to work around.

Validation off did one thing. It moved the refusal from the NodeClass status, where it is visible right
after the apply, to a NodeClaim event, which only exists once a pod is pending.

## Decision

`settings.disableDryRun` is removed from `values/karpenter.yaml` and takes the chart default, `false`.

## Consequences

A boundary that refuses Karpenter shows up as `ValidationSucceeded=False` on the EC2NodeClasses within a
minute of phase 2, and the platform README's check 8 says to decode it there.

Until the admin apply of ADR 0018, the NodeClasses will fail validation, exactly as they did in attempt 1.
No window opens before that apply.

## Sources

- https://github.com/aws/karpenter-provider-aws/blob/v1.14.1/pkg/controllers/nodeclass/validation.go
- https://github.com/aws/karpenter-provider-aws/blob/v1.14.1/charts/karpenter/values.yaml
