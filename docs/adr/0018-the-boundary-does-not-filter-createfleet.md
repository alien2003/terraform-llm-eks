# 0018. The boundary does not filter CreateFleet, and the kill path takes every instance

Date: 2026-11-23
Revised: 2026-11-24

## Status

Accepted. Revised 2026-11-24 after the real fleet test: the whitelist still binds Karpenter, through
`ec2:RunInstances`. See "Revised 2026-11-24" at the end; where it disagrees with the text above, it wins.

Supersedes the `CreateFleet` half of `InstanceTypeWhitelist` and `InstancesMustCarryProjectTag` in ADR
0011, and the tag selection of instances in ADR 0015. ADR 0048 follows from it on the platform side.

## Context

In both attempts at window 1, Karpenter never launched a node. On attempt 2 the NodeClaim events carried
`UnauthorizedOperation` for `ec2:CreateFleet` on `instance/*`. I decoded the authorization message with
`sts decode-authorization-message`. The matched statement was `InstanceTypeWhitelist`, and the request
context held seven keys: `aws:Region`, `aws:Service`, `ec2:InstanceID` (`*`), `aws:Resource`, `aws:Type`,
`aws:Account` and `aws:ARN`. There was no `ec2:InstanceType` and no `aws:RequestTag/Project`.

The statement is a Deny with `StringNotEquals` on `ec2:InstanceType`. A negated operator matches an absent
key, so it denied every fleet. ADR 0047 blamed a race in Karpenter's dry-run validation. That was wrong:
the simulation it rested on supplied `ec2:InstanceType` by hand, which tested the policy and not the
request EC2 builds.

I then ran `create-fleet --dry-run` as the operator, which carries the same boundary as the Karpenter
controller role, with a launch template name that does not exist. Three instance types, each with and
without a `TagSpecifications` entry for the instance:

| Type | Instance tagged | Result |
| --- | --- | --- |
| `t3.medium` | no | `DryRunOperation` |
| `t3.medium` | yes | denied by `InstanceTypeWhitelist`, no type in the context |
| `g6.xlarge` | no | `DryRunOperation` |
| `g6.xlarge` | yes | denied by `InstanceTypeWhitelist`, no type in the context |
| `m5.large` | no | `DryRunOperation` |
| `m5.large` | yes | denied by `InstanceTypeWhitelist`, no type in the context |

So on a fleet, EC2 evaluates `instance/*` only when the request tags the instances, and then without the
type. `m5.large` is outside the whitelist and an untagged fleet of it passed. The whitelist never filtered
a type on this path. It only refused the fleets that tag their instances, and Karpenter always does.

The EC2 authorization reference does list `ec2:InstanceType` and `aws:RequestTag/${TagKey}` on the
`CreateFleet` instance row. Listed is not sent. Observed behaviour wins, so this record carries the
evidence.

Three ways to keep the statements and let Karpenter through, all rejected:

- `StringNotEqualsIfExists`. The IAM reference says a negated `...IfExists` in a Deny still denies when
  the key is absent. It changes nothing.
- A `Null` guard (deny only when the key is present and outside the list). It works in principle and
  would start enforcing on the day EC2 sends the key. It needs two more statements, about 400 characters,
  and the live boundary has 88 spare of 6,144.
- Dropping Karpenter for a second managed node group. That path launches through
  `AWSServiceRoleForAutoScaling`, which carries no boundary, so it is no more filtered than the fleet. It
  would cost the Spot interruption handling in ADR 0043.

## Decision

`InstanceTypeWhitelist` and `InstancesMustCarryProjectTag` name `ec2:RunInstances` only. `GpuSpotOnly`
already did.

What bounds Karpenter's launches is what already bounded the managed node group's:

- the NodePools, which list `g6.xlarge`, `g6.2xlarge`, `t3.medium` and `m7i.large` and cap CPU at 8 and 16;
- the vCPU quotas: G and VT Spot 8, G and VT on demand 0, every other accelerator family 0, standard on
  demand 16, standard Spot 32;
- the window timer, the sweeper and the budget action.

Because the boundary can no longer guarantee the Project tag on every instance, nothing that stops money
selects instances by it any more:

- the kill Lambda's `describe_instances` filters on state alone;
- the kill role's `ec2:TerminateInstances` drops the `aws:ResourceTag/Project` condition and is scoped to
  instances in the regions `RegionLock` leaves open.

This account exists for this project and nothing else, so every instance in one of its regions belongs to
the project. That rule does not depend on any launcher tagging correctly.

`mise run audit` already reported an instance without the tag as a failure. It still does. Only the
message changes, since the sweeper now terminates such an instance.

`guard-drill` loses its three simulated `CreateFleet` cases and gains a `create-fleet --dry-run` matrix:
GPU types on Spot, a type outside the whitelist and an untagged fleet, all expected allowed. `aws_ro`
accepts `decode-*`, so the drill can name the statement when a fleet is refused.

## Consequences

A Karpenter launch of a type outside the whitelist is no longer refused by IAM. It never was on an
untagged fleet. Now it is not on a tagged one either. A NodePool edited to ask for `c7i.4xlarge` would
get one, inside the standard quotas. The quotas are the ceiling for that mistake, as they always were for
the node group.

The kill role can terminate any instance in the project's regions. A handler bug could now stop something
untagged. In this account that is a feature.

The Project tag stays on every RunInstances launch and still feeds the cost reports and the per-stack
audit. `NoProjectTagRemoval` and `NoProjectTagRepoint` stay: NAT gateways, addresses and VPCs are still
found by tag.

The change needs an admin apply. Until then the live boundary still refuses every tagged fleet.

Not settled here: whether an instant fleet with a real launch template also authorizes `RunInstances` for
each instance it starts. If it does, the whitelist binds Karpenter after all and this record gets a
`Revised:` line. The cheapest test is one real fleet of one `t3.nano` on Spot, terminated at once, in the
admin window.

`NoProjectTagRepoint` is a Deny on `ec2:CreateTags` with the same kind of negated condition. The dry runs
above did not trip it, but none of them got past `instance/*` with tags. The drill's tagged fleet cases
after the apply are the first real test of it.

## Sources

- IAM condition operators, `...IfExists`: "If you are using an `"Effect": "Deny"` element with a negated
  condition operator like `StringNotEqualsIfExists`, the request is still denied even if the condition key
  is not present."
  https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html
- Actions, resources, and condition keys for Amazon EC2, the `CreateFleet` instance row.
  https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html
- IAM quotas, 6,144 characters for a customer managed policy.
  https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html

## Revised 2026-11-24

The admin window applied this decision, then ran the test the record asked for. Both fleets were real, not
dry runs: `create-fleet --type instant`, one Spot instance, as the operator, with a real launch template,
`Project` and `Stack` on the instance and the volume.

| Type | Whitelisted | Result |
| --- | --- | --- |
| `t3.nano` | no | refused: `UnauthorizedOperation` on `ec2:RunInstances`, `instance/*` |
| `t3.medium` | yes | launched, both tags on the instance and on its volume, terminated 35 s later |

The decoded `t3.nano` message matched `InstanceTypeWhitelist`, and its request context carried
`ec2:InstanceType` = `t3.nano`, `ec2:InstanceMarketType` = `spot` and `ec2:LaunchTemplate` among 24 keys.
So an instant fleet authorizes `RunInstances` for each instance it starts, as the caller, and that
evaluation does carry the type. The `CreateFleet` evaluation above still carries neither the type nor the
tags. Both statements are true; the first one is the one that counts.

What changes:

- A Karpenter launch of a type outside the whitelist is refused by IAM. The first paragraph of
  Consequences is wrong. The NodePools and the quotas are a second layer, not the only one.
- `InstancesMustCarryProjectTag` binds the fleet path too, through the same per-instance `RunInstances`.
  It did not fire on either fleet, because both tagged their instances.
- `NoProjectTagRepoint` let the fleet's create-time tags through. Karpenter's launch path is open with the
  boundary as it now stands.
- `create-fleet --dry-run` stops at the fleet's own evaluation. The drill's dry-run case for `m5.large`
  reports allowed while the same fleet without `--dry-run` is refused. The drill keeps the case and says
  so; the type filter on this path is drilled by the `RunInstances` launch matrix.
- CloudTrail records a `CreateFleet` whose every instance was refused without an `errorCode`. The refusal
  is in the response's `errors`. A search on `errorCode` does not find it.

What does not change: `CreateFleet` stays out of both Denies, since with it in them every tagged fleet is
refused before the per-instance check is reached. The kill path still selects every instance in the
project's regions, whatever its tags.

Evidence: `materials/guardrails/w0-reapply/` in the working notes, `step9-decoded.json`,
`step9b-create-fleet-t3medium.json`, `step9b-instance.json`, `step9b-volume-tags.json`,
`step10-cloudtrail-createfleet.json`.
