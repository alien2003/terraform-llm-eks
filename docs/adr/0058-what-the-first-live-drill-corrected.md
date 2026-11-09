# 0058. What the first live boundary drill corrected

Date: 2026-11-09

## Status

Accepted. Amends how ADR 0053's rules are applied in three cases; the rules themselves stand.

## Context

`mise run guard-drill` ran against the live operator role for the first time in window 0, on
2026-11-09. It reported 76 checks and 9 failures. None of the nine was a boundary defect; each was the
drill asking a question that could not be answered.

`eks:CreateCluster` on a cluster ARN. Both Auto Mode cases named `cluster/auto` and
`cluster/llm-eks`. The simulator matched no statement in either policy and answered `implicitDeny`
for both, including the one that must be allowed. Against `*` the same two cases answer `allowed`
(from the permissions policy) and `explicitDeny` (from the boundary).

Missing context keys on a case that matched nothing. Six cases expected `implicitDeny` and got it, and
failed anyway: `MissingContextValues` listed every condition key in the policy set (ten keys, from
`ec2:VolumeSize` to `eks:computeConfigEnabled`), and `sim()` fails any unresolved key. For a case that
matched no statement, the list is not the keys a matched statement read.

An arm64 type in the launch matrix. `x2gd.16xlarge` is Graviton and the matrix AMI is x86_64. EC2
answered `InvalidParameterValue` ("The architecture 'arm64' ...") before evaluating IAM, so the case
had no verdict.

## Decision

`eks:CreateCluster` joins the actions simulated against the literal `*`.

A case whose decision is `implicitDeny` with no matched statement passes despite missing keys, except
for `iam:PassRole`. A missing key could only change that answer by letting a conditional Allow match,
and the only conditional Allows in either policy are on `iam:PassRole`.

The non-whitelisted arm64 case is replaced by `x2iedn.32xlarge`, which is x86_64.

After the changes the drill reports 76 checks, 0 failed, on the same account.

## Consequences

The lenient rule is tied to the current policies. A new conditional Allow on any other action makes it
too lenient for that action. The grep that keeps `BOUNDARY_CONTEXT_KEYS` honest does not catch that, so
whoever adds such a statement has to add the action to the exception in `sim()`.

## Sources

- Window 0 drill reports, 2026-11-09: the failing run at 10:00Z and the clean rerun after these
  changes.
- Service Authorization Reference, Amazon EKS actions:
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonelastickubernetesservice.html>
