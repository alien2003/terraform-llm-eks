# 0016. The budget action fires before the credits run out

Date: 2026-11-07

## Status

Accepted. Changes the default of `budget_action_threshold_usd` from 120 to 90.

## Context

The account holds 100 USD of credits and is on the PAID plan (ADR 0057). On PAID, spend past the
credits bills the card.

Four signals stop spend automatically:

| Signal | Default | Effect |
| --- | --- | --- |
| Burn-rate alarm | 25 USD inside six hours | Kill Lambda, everything stops |
| Cumulative billing alarm | 60 USD month to date | Kill Lambda, everything stops |
| Budget action | was 120 USD | Deny policy on the operator role |
| One-shot window timer and sweeper | time, not money | Kill Lambda |

At 120 the budget action fired 20 USD after the credits were gone. It is the last automatic stop, so
it was the only one placed where it protects nothing.

## Decision

The default is 90. The other thresholds stay where they are.

90 leaves 10 USD between the action and the end of the credits. Billing data lags by hours, so spend
keeps arriving after the action fires, and the margin is for that.

## Consequences

The budget action now fires before the budget limit of 100 and before its 100 percent notification.
That is the order I want: the stop, then the email saying the month's budget is used.

Every threshold is monthly. The credits are one amount across months, so several months each under 60
can still add up to more than 100. No threshold here can see that. What can is the credit balance:
`guard-status` reads it before every window and fails when no credits remain.

Changing this value is an admin apply of `infra/guardrails`, as for every guardrail.
