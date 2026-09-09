# 0053. Every policy simulation names a resource ARN

Date: 2026-09-08

## Status

Accepted.

## Context

`aws iam simulate-principal-policy` will answer without `--resource-arns`. It simulates the action
against `*` and returns a decision, and the decision looks authoritative.

It is nearly useless. Half the denies in the operator boundary are scoped to specific ARNs (the kill
Lambda, the sweeper schedule, the billing alarm, the roles and policies that make up the safety net),
and half the allows are scoped too, most importantly `scheduler:CreateSchedule`, which is permitted
inside `schedule/llm-eks-windows/*` and nowhere else.

Simulated against `*`, a scoped deny and a blanket deny return the same word. So do a scoped allow
and a blanket allow. A drill built that way passes just as happily against a boundary whose
resource scoping has been deleted, which is the failure it exists to catch.

Condition keys need the same care, and here the trap runs the other way. `ec2:InstanceType` and
`ec2:InstanceMarketType` are populated only by a real launch request, so a simulation that passes no
`--context-entries` is a simulation in which both keys are absent. An absent key is not a neutral input.
IAM's documented rule is that a matching operator such as `StringEquals` is false when the key is
missing, and a negated operator such as `StringNotEquals` is true. Both of those land in this boundary:

- `InstanceTypeWhitelist` tests `ec2:InstanceType` with `StringNotEquals`, so with the key absent the
  deny fires against every launch, including the four types the whitelist is there to allow. That is the
  right behaviour for a real request that names no type, and a useless test result: the drill reports an
  explicit deny for the good cases and the bad ones alike.
- `GpuSpotOnly` pairs a `StringEquals` on the type with a `StringNotEquals` on the market. With the type
  absent the first condition is false, the statement never matches, and the Spot-only rule looks as
  though it is not in the policy at all.

So an unset key does not produce an inconclusive answer or a warning. It produces a confident explicit
deny from one statement and a silent pass from another, both for the wrong reason. The `...IfExists`
variants would not rescue this either: on a `Deny`, `StringNotEqualsIfExists` still denies when the key
is missing, so it is the same behaviour with one more thing to explain.

## Decision

Every case in `scripts/guard-drill.sh` passes `--resource-arns`. Where an action's only valid
resource genuinely is `*` (`organizations:CreateOrganization`, `freetier:UpgradeAccountPlan`,
`sns:Unsubscribe`), the case passes the literal `*` and the code says why.

Several cases are pairs: the same action against a project ARN and against a deliberately
non-project ARN, with opposite expectations. `lambda:UpdateFunctionCode` must be an explicit deny
against the kill Lambda and an implicit deny against any other function.
`scheduler:CreateSchedule` must be allowed inside the window group and denied outside it. A single
answer proves nothing about scope; the pair does.

Expectations distinguish `explicitDeny` from `implicitDeny` rather than collapsing both into
"denied". They mean different things: explicit is the boundary refusing, implicit is nothing having
granted it. A statement that quietly stops matching turns an explicit deny into an implicit one
while the drill still shows a refusal.

Every simulated launch case therefore states `ec2:InstanceType`, `ec2:InstanceMarketType` and
`aws:RequestTag/Project` explicitly in `--context-entries`, and states them for both the case that must
be denied and the case that must be allowed.

The launch conditions are drilled with `ec2 run-instances --dry-run` as well, and that matrix is the
authority, because a real request is where those keys actually come from; the simulated launch cases only
confirm that the conditions are wired to the `instance` resource type rather than to the image or the
subnet. EC2 answers `DryRunOperation` when the caller is permitted and `UnauthorizedOperation` when it is
not, and creates nothing either way. Anything else EC2 says is recorded as inconclusive and fails the
drill: a case that could not reach a verdict has not verified anything.

## Consequences

The drill is slower and much longer than the obvious version. It is also the only version that can
tell the difference between a boundary that works and one that says yes to everything.

Every case states its expected outcome, and the script fails when reality differs in either
direction. An allow that became a deny is as much a finding as the reverse: it will stop the build
halfway through a window, which under the window protocol means tearing down and starting again.

Results are written to `materials/guardrails/` as text and JSON. That directory is the one place any
script in this repository writes outside the repository, and it is deliberate: a drill whose output
scrolled past in a terminal proves nothing later, and the project's rule is that a published number
traces to a file.

## Sources

- `simulate-principal-policy` reference, including `--resource-arns`, `--context-entries`, and the
  note under `--permissions-boundary-policy-input-list` that an attached permissions boundary is
  used for the simulation unless one is passed in to replace it:
  <https://docs.aws.amazon.com/cli/latest/reference/iam/simulate-principal-policy.html>
- `--dry-run` semantics: "If you have the required permissions, the error response is
  `DryRunOperation`. Otherwise, it is `UnauthorizedOperation`":
  <https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instance-types.html>
- IAM JSON policy elements: Condition operators, on a key that is absent from the request context: "the
  values do not match and the condition is false. If the policy condition requires that the key is
  *not* matched, such as `StringNotLike` or `ArnNotLike`, and the right key is not present, the
  condition is true", and on the `Deny` case, "If you are using an `"Effect": "Deny"` element with a
  negated condition operator like `StringNotEqualsIfExists`, the request is still denied even if the
  condition key is not present":
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html>
- IAM policy elements: Variables and tags, same rule stated for a key with no value: "Inverted condition
  operators like `StringNotEquals` or `StringNotLike` do match against a null value":
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_variables.html>
