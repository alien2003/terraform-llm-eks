# 0052. Destroy, then audit, then disarm, and never in another order

Date: 2026-09-08

## Status

Accepted.

## Context

`mise run down` does three things: destroys the stacks, checks that nothing survived, and removes
the one-shot kill timer. The order they happen in is the difference between a safety net and a
decoration.

The tempting order is to disarm first. The window is over, the human is watching, the timer is about
to become noise, and removing it before the destroy means no risk of it firing halfway through and
interfering. That reasoning is exactly backwards. A destroy that fails part way is the single most
likely way this project ends up with something running that nobody is watching, and it is precisely
the case in which the timer is the only thing left. Disarming first opens a gap the width of the
destroy, in the one situation where the gap matters.

The second tempting order is to disarm as soon as the destroy returns zero. Terraform returning zero
means Terraform believes it deleted everything it knows about. It says nothing about a resource
created outside Terraform, a resource whose deletion was accepted asynchronously and then failed, or
a resource in the other region.

## Decision

The order is fixed and the code makes the wrong order unreachable:

1. `terraform destroy` for each stack, in the reverse of the apply order. A failure here is recorded
   and does not stop the script.
2. `scripts/audit.sh`, which asks the account what still exists rather than asking Terraform.
3. The disarm, inside a single branch guarded by the audit's exit status.

If the audit is dirty the timer stays armed, the script says so in the loudest terms it has, and it
exits non-zero. There is no flag to skip the audit and no flag to force the disarm.

## Consequences

The worst realistic outcome of a botched teardown is that everything project-tagged is terminated by
the timer at the end of the approved window, or by the always-on sweeper at its configured age.
Both are noisy and neither is expensive.

A dirty audit leaves the window formally open. That is intended: the protocol says a window closes
when the audit is clean, and a script that announced `CLOSED` over a dirty audit would be lying in
the project's own log.

`mise run down` is safe to run repeatedly, which is what makes the fix-and-retry loop natural: fix
the orphan, run it again, and the timer disarms itself the moment the audit passes.

The audit runs while the timer is still armed, so `audit.sh` treats a schedule in the window group as
information rather than as a fault. An audit that failed on the presence of the timer it is meant to
protect would deadlock the teardown.
