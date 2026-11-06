# 0057. A PAID account plan is accepted, and credits are what is checked

Date: 2026-11-06

## Status

Accepted. Supersedes the plan check written in Phase 1.

## Context

`guard-status` was written for an account on the Free plan. It failed on any other plan, with the
message that credits no longer apply.

Window 0, on 2026-10-08, read `freetier get-account-plan-state` for the first time. The account is on
the PAID plan, status ACTIVE, with 100.0 USD of credits remaining. The check would have failed every
pre-flight from then on, and the window halted on it.

The message was also wrong. AWS gives the USD 100 sign-up credit on either plan. The plans differ in
what happens when the credits run out: the Free plan closes the account, the PAID plan bills the card.
https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html

## Decision

The check accepts both plans. It fails if the plan type is anything other than `FREE` or `PAID`, if the
status is not `ACTIVE`, or if the remaining credits are zero or absent. On PAID it passes and says that
spend past the credits bills the card.

The separate `credit balance` check, from `billing:GetCredits`, stays as it was. It is the figure that
goes into `materials/costs/credits.md`.

## Consequences

On this account there is no safety net under the credits. On the Free plan, running out would have
closed the account. Here it starts a bill. The budget, the anomaly monitor, the kill Lambda, the
sweeper and the one-shot window timer are now the only things between a mistake and the card. None of
them changes; they were already written as if credits were cash.

The boundary still denies `freetier:UpgradeAccountPlan`. On a PAID account that deny protects nothing,
and it costs nothing either, so it stays.
