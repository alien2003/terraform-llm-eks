# 0054. Quota codes are discovered at run time and quotas are addressed by name

Date: 2026-09-08

## Status

Accepted.

## Context

Service Quotas addresses a quota by a code like `L-1216C47A`. Those codes appear in AWS's own CLI
examples, and writing them down is the obvious thing to do.

AWS does not publish a mapping from quota name to code as documentation. The codes turn up in
examples and in blog posts, which is a poor foundation for a check that decides whether a cloud
window may open. A code copied out of a blog post and quietly wrong does not fail loudly; it looks
up a different quota and reports a comfortable number.

There is a second trap. `aws service-quotas list-service-quotas` returns quotas that have an
*applied* value, meaning one that has been changed from the AWS default. It omits every quota that has
never been touched. On this account that is exactly the set that matters: the accelerator families
whose whole purpose is to sit at zero, so that a runaway Karpenter cannot find a P, Trn, Inf, DL, F
or X instance to launch even if the permission boundary somehow let it try. Checking those with
`list-service-quotas` reports nothing at all and reads as success.

## Decision

No `L-` code appears in `scripts/` or in `infra/`, and `scripts/lint.sh` has a check that fails the
build if one turns up in a `.sh`, `.tf` or `.json` file in either tree. The codes quoted in this record
and in ADR 0014 are examples of the shape, in prose, and are deliberately outside what that check
guards. The thing that must never happen is a code compiled into a check or into a policy, where being
quietly wrong looks exactly like success.

Quota targets live in `infra/guardrails` as data keyed by a short identifier, carrying the AWS quota
*name* and the target value, and are published to SSM at `/llm-eks/guardrails/quota-targets`.

`scripts/guard-status.sh` reads that parameter, calls
`aws service-quotas list-aws-default-service-quotas --service-code ec2`, and resolves each name to
its code at run time. It then reads the applied value with `get-service-quota`, falling back to the
default value when that raises `NoSuchResourceException`, which is the normal answer for a quota
nobody has ever changed and means the AWS default is the effective value.

The families checked are the four from the original specification (P, Trn, Inf and DL) plus F and X,
which Phase 0 found missing. AWS publishes "All F Spot Instance Requests" and "All X Spot
Instance Requests" and both default to zero.

## Consequences

`guard-status` is a few API calls slower and cannot be run offline. It could not be run offline
anyway; it is a check on the state of an account.

A quota renamed by AWS fails loudly with "AWS publishes no default quota named ..." rather than
silently checking the wrong thing. That is the right failure: a name that no longer exists is a real
change and someone should look at it.

The SSM parameter is the single source of truth shared by the guardrails stack, `guard-status`, and
the quota request path in the guardrails README, so a target raised in one place is not still low in
another.

## Sources

- `get-aws-default-service-quota` and its sibling `list-aws-default-service-quotas` return AWS
  default values, including for quotas with no applied value:
  <https://docs.aws.amazon.com/cli/latest/reference/service-quotas/get-aws-default-service-quota.html>
- EC2 instance-type quota names, including the per-family Spot request quotas:
  <https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-quotas.html>
