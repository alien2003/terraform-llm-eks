# 0051. The one-shot window timer is created by the CLI, not by Terraform

Date: 2026-09-08

## Status

Accepted.

## Context

Every cloud window is bounded by a one-shot EventBridge Scheduler schedule that fires at
`now + WINDOW_HOURS` and invokes the kill Lambda. Terraform creates the schedule group
`llm-eks-windows` and the execution role; it does not create the schedules inside the group.

The alternative is a `aws_scheduler_schedule` resource in `infra/cluster` with its expression
computed from a variable. That would put the timer in the same apply as the thing it protects, which
sounds tidy and is wrong in three ways.

The fire time is only known at the moment the window opens. Encoding it as a Terraform variable
means the timer is created by the same apply that creates the cluster, so the interval during which
the apply is running is unprotected. That interval is the most dangerous one, because a hung apply is
exactly the failure the timer exists for.

A destroy that fails part way can leave the timer resource deleted while the cluster is still up.
Terraform's destroy order is derived from dependencies, and the timer has no dependency on the
cluster; there is no way to express "delete this last, and only if everything else went".

And the timer must survive Terraform being unavailable. If the state file is locked, corrupted, or
in a bucket the operator can no longer reach, the timer still has to fire.

## Decision

`scripts/window-up.sh` creates the schedule with `aws scheduler create-schedule` before it runs any
`terraform apply`. `scripts/window-down.sh` deletes it with `aws scheduler delete-schedule`, after
the destroy and after `mise run audit` reports clean.

The schedule uses a one-time `at(yyyy-mm-ddThh:mm:ss)` expression in UTC, with
`--flexible-time-window '{"Mode":"OFF"}'` and `--action-after-completion NONE`.

`ActionAfterCompletion` stays `NONE` rather than `DELETE` deliberately. A fired timer that deleted
itself leaves no evidence that it fired, and a timer firing is the most important single event that
can happen in this project. It is deleted explicitly by `window-down.sh` instead, which also
satisfies AWS's recommendation to remove one-time schedules once they have run.

The ARNs the timer needs, the kill Lambda's and the scheduler execution role's, are discovered at
window time with `lambda get-function` and `iam get-role` rather than read out of the guardrails
state file, because that state is local to whoever applied it (see ADR 0020) and a window has to be
openable from a machine that has never held it.

## Consequences

The timer is armed before anything billable exists and disarmed after everything billable is gone,
which is the only ordering with no unprotected interval.

Arming is idempotent in the safe direction. A second `mise run up` for the same window finds the
existing schedule, reports its fire time, and leaves it alone; it does not push the deadline further
out. Extending a window requires a new approval message, and this makes that structural rather than
a matter of remembering.

A timer armed for a different window blocks `mise run up` outright. Two windows open at once means
two timers disagreeing about when everything dies.

The operator's permission boundary allows `scheduler:CreateSchedule` and `scheduler:DeleteSchedule`
only against `schedule/llm-eks-windows/*`, so this is the one part of the scheduler surface the
window tasks can touch. `scheduler:DeleteSchedule` against the always-on sweeper is explicitly
denied.

## Sources

- One-time schedules and the `at()` expression syntax, including the note that a completed one-time
  schedule still counts against the account quota and should be deleted:
  <https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html>
- `create-schedule` options, including `--action-after-completion` with values `NONE` and `DELETE`,
  and the required `--flexible-time-window`:
  <https://docs.aws.amazon.com/cli/latest/reference/scheduler/create-schedule.html>
