# 0014. Quota targets are data keyed by quota name, and no L- code is written down

Status: accepted
Date: 2026-09-08

## Context

The quotas that matter here are the EC2 instance-type quotas, which are expressed in vCPUs per purchasing
option and per family. On a fresh account every accelerator family sits at zero, which is a second lock
on the same door the instance whitelist covers: even if a launch got past the boundary, there would be no
headroom for it to succeed in.

Service Quotas addresses a quota by a code that looks like `L-3819A6DF`. Those codes are not published in
the documentation. Phase 0 also established that `list-service-quotas` omits quotas that have no applied
value, which is the state of every accelerator quota on an account that has never used one, so the call
that actually returns them is `list-aws-default-service-quotas`.

Terraform can manage a quota increase with `aws_servicequotas_service_quota`, but that resource takes a
quota code, and a quota increase is not a thing that converges on apply anyway. It is a support request
with a lead time measured in hours or days.

## Decision

The targets are a variable, `quota_targets`, keyed by a short identifier and carrying the service code,
the quota **name**, the target value and a note saying why that value. No `L-` code appears anywhere in
this stack or in any script that reads it.

Terraform publishes the map to SSM at `/llm-eks/guardrails/quota-targets` and requests nothing. The
request path is documented in `infra/guardrails/README.md`: resolve name to code at run time with
`list-aws-default-service-quotas`, raise the request under the administrator profile in window 0, record
the request ID and status in `materials/guardrails/`.

The map includes the F and X families alongside P, Trn, Inf and DL. Phase 0 found both missing from the
original specification, and both default to zero, which is where they stay.

## Consequences

There is one source of truth for what the quotas are supposed to be, and both `guard-status` and the
request path read it. A target that changes changes in one place.

The trade is that Terraform does not enforce the quota. Nothing fails at apply time if a quota drifts;
`mise run guard-status` is what compares the applied values against the targets, and a window does not
open unless it is green.

One entry in the map is meant to be raised: `g_vt_spot`, from its default of zero to the vCPUs the GPU
node needs. The other nine exist to be asserted rather than changed. Seven of them sit at zero, which is
where the accelerator and FPGA families stay, and two sit at the documented default of five, which is
what the system node group runs on. An entry already at its default is still worth writing down, because
the check `guard-status` performs is "does the applied value still equal the target", and that question
has to be asked of all ten. A family that quietly gained headroom is exactly the drift nobody would
notice.

## Sources

- <https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-quotas.html>
