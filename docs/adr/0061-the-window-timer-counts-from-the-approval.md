# 0061. The window timer counts from the approval

Date: 2026-11-25

## Status

Accepted. Amends step 4 of `window-up` as described in ADR 0059.

## Context

An approval message names a window's length: `max 3h`. `mise run up` armed the kill timer at the moment
it ran plus `WINDOW_HOURS`. Between the approval and that moment sit the guard-status run, the
pre-flight and the cost confirmation.

On window 1's second attempt the approval arrived at 11:52:23Z and the timer was armed at 12:33:58Z, so it
was set for 15:33:58Z, 42 minutes after the approval ended at 14:52:23Z. The manual cutoff in the window
plan held and the teardown finished at 13:27:21Z, but the one control that does not depend on anyone
paying attention was set past the approved time.

Taking `WINDOW_HOURS` smaller than the message says would fix the number and break the rule that both
inputs are copied from the message verbatim.

## Decision

`mise run up` accepts a third input, `APPROVED_AT=<yyyy-mm-ddThh:mm:ssZ>`, the UTC time the approval
arrived. With it, the timer fires at `APPROVED_AT + WINDOW_HOURS`, which is when the approval ends.

It is checked before guard-status, so a bad value costs nothing:

- not that format, or not a real time: refused;
- more than 2 minutes in the future: refused, because that is the end time copied by mistake;
- fewer than 15 minutes left in the approval: refused, and checked again at the moment of arming, since
  guard-status and pre-flight take minutes.

It stays optional. Without it the old behaviour holds and the script prints a warning that says how the
timer will be late. Window plans pass it.

## Consequences

A window opened slowly has less time, not more. That is the point: the approval is the budget, and the
pre-flight spends it.

A timer that already exists is still left alone on a second `mise run up`, whatever `APPROVED_AT` says.
Extending a window remains a new approval message.

The 15-minute floor is below the time the cluster takes to come up. A window opened with 20 minutes left
would arm, start applying and be cut by the timer half way. The floor stops the hopeless case, not every
bad one; the plan's own clock does the rest.

## Sources

- `materials/costs/windows.md` in the working notes, window 1 attempt 2: approval, arming and close times.
- EventBridge Scheduler one-time schedules, `at(yyyy-mm-ddThh:mm:ss)`.
  https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html
