# 0017. The Standard quota ceilings follow what AWS applied: 16 on-demand, 32 Spot

Date: 2026-11-09

## Status

Accepted. Changes the two Standard targets that ADR 0011 describes at 5 vCPUs.

## Context

`var.quota_targets` held both Standard EC2 quotas at their documented default of 5 vCPUs, as
ceilings. `guard-status` fails when an applied value is above its ceiling, because neither
`eks:CreateNodegroup` nor `eks:UpdateNodegroupConfig` can be filtered by size in IAM, so the quota is
the only cap on how much system-node capacity a node group can ask for (ADR 0011).

On 2026-10-08 both quotas read 5. On 2026-11-09, during window 0, they read:

| Quota | Code | 2026-10-08 | 2026-11-09 |
| --- | --- | --- | --- |
| Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances | L-1216C47A | 5 | 16 |
| All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests | L-34B43A08 | 5 | 32 |

Nobody requested either change; the only quota request on the account is the G and VT Spot one. The
account moved to the PAID plan in between (ADR 0057), which is the likely cause, but AWS did not say.

Service Quotas only raises a quota. Lowering one is a support case with no published turnaround. Until
it is answered, `guard-status` would fail on both lines, and no window can open on a failing
`guard-status`.

## Decision

The two ceilings are set to the applied values, 16 and 32, so the check holds the account at what AWS
gave it and fails if AWS raises them again. Applied with the administrator profile in window 0 on
2026-11-09, at the author's written request.

## Consequences

A runaway node group can now use up to 16 on-demand Standard vCPUs instead of 5. At the us-east-1
on-demand rate of an m5.xlarge (4 vCPUs, about 0.19 USD an hour) that is roughly 0.77 USD an hour.
The sweeper terminates project instances after 510 minutes, so one incident costs about 6.5 USD. The
budget action at 90 USD, the billing alarms and the instance-type whitelist are unchanged, so it is
still a bounded loss.

The ceiling no longer says "the documented default". A fresh account would read 5 and pass, because a
ceiling only fails above its target.

Worth revisiting if a support case brings the quotas back to 5: then the targets go back to 5 in a new
record.

## Sources

- Service Quotas, requesting an increase; decreases are not a self-service action:
  <https://docs.aws.amazon.com/servicequotas/latest/userguide/request-quota-increase.html>
- Window 0 readings: `get-service-quota` for L-1216C47A and L-34B43A08 on both dates.
