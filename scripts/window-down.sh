#!/usr/bin/env bash
# mise run down
#
# Closes a cloud window. The order is the safety property and it is the whole point
# of the script:
#
#     destroy  →  audit  →  disarm, and only if the audit was clean
#
# Getting that backwards is the one mistake in this project that costs real money
# quietly. Disarming first, then destroying, leaves a gap in which a failed destroy
# has no backstop at all: the timer that would have killed everything is gone and
# nobody finds out until the bill arrives. So the disarm lives inside a single branch
# guarded by the audit's exit status, and there is no path to it that does not go
# through a clean audit. ADR 0052.
#
# If the audit is dirty the timer stays armed. That is not a failure of this script,
# it is the script working: whatever is still running will be terminated by the timer
# or by the sweeper whether or not anyone remembers to come back.
#
# Safe to run twice. A second run finds nothing to destroy, audits clean, and finds no
# timer to disarm.
#
# What it destroys is infra/cluster and nothing else. See the comment above
# DESTROY_STACKS: the bootstrap stack owns the state bucket and is meant to outlive a
# window, and the guardrails stack is admin-applied and destroyed last of everything.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd aws jq terraform

heading "closing cloud window — region $WORK_REGION"

if ! aws_available; then
  die "no usable AWS credentials. Nothing can be destroyed or audited without them; check with 'mise run auth operator'."
fi

# ------------------------------------------------------------------ what is armed

ARMED_TIMERS="$(aws_ro scheduler list-schedules --group-name "$WINDOW_GROUP_NAME" \
  --region "$WORK_REGION" --output json | jq -r '.Schedules[].Name')"

if [ -n "$ARMED_TIMERS" ]; then
  info "armed timers in $WINDOW_GROUP_NAME:"
  while IFS= read -r timer; do
    [ -n "$timer" ] || continue
    expr="$(aws_ro scheduler get-schedule --name "$timer" --group-name "$WINDOW_GROUP_NAME" \
      --region "$WORK_REGION" --query 'ScheduleExpression' --output text)"
    info "  $timer  $expr"
  done <<<"$ARMED_TIMERS"
else
  warn "no window timer is armed. Either the window was already closed, or it was never"
  warn "opened with 'mise run up'. Destroying and auditing anyway, which is harmless."
fi

# ------------------------------------------------------------------ 1. destroy

info ""
info "step 1/3: terraform destroy"

# What a window closes, and what it deliberately does not.
#
# infra/cluster is destroyed. The platform layer goes with it: it is a child module of
# that stack, not a root stack of its own, so it has no state and no destroy of its own
# to run. Karpenter, the node pools and the inference release are removed as part of
# the parent destroy.
#
# infra/bootstrap is NOT destroyed, and this is not an omission. It holds the Terraform
# state bucket that infra/cluster's own backend lives in, so destroying it from here
# would delete the state of the stack this script has just destroyed, mid-run. It also
# holds the weights bucket and the ECR pull-through cache, both of which exist to
# survive between windows: re-uploading the model weights and re-pulling multi-gigabyte
# images every window would cost more than storing them. `mise run audit` knows this
# too and reports Stack=bootstrap resources as expected rather than as orphans. The
# bootstrap stack is destroyed once, by hand, in the final window, before guardrails.
#
# infra/guardrails is not destroyed either, for the stronger reason: it is the thing
# protecting the account, it is admin-applied, and Rule 2a puts it last of everything.
DESTROY_STACKS="${LLM_EKS_DESTROY_STACKS:-infra/cluster}"

export LLM_EKS_WINDOW_WRITE=1

destroy_failed=0
for stack in $DESTROY_STACKS; do
  dir="$REPO_ROOT/$stack"
  if [ ! -d "$dir" ]; then
    warn "no such stack: $stack — skipping"
    continue
  fi

  info ""
  info "--- $stack"

  if ! terraform -chdir="$dir" init -input=false; then
    error "terraform init failed in $stack; cannot destroy it."
    destroy_failed=1
    continue
  fi

  # A destroy that fails is not fatal here. The audit that follows is what decides
  # whether the window can close, and it looks at the account rather than at
  # Terraform's opinion of the account.
  if ! terraform -chdir="$dir" destroy -input=false -auto-approve; then
    error "terraform destroy failed in $stack."
    destroy_failed=1
  fi
done

if [ "$destroy_failed" -ne 0 ]; then
  warn "at least one destroy failed. Continuing to the audit, which is the check that matters."
fi

# ------------------------------------------------------------------ 2. audit

info ""
info "step 2/3: audit"

# LLM_EKS_WINDOW_WRITE is exported above, and an exported variable is inherited by
# every child. The audit only ever reads, but a child that inherits the write flag is
# a child running in CLOUD mode because of who started it rather than because it
# checked anything, so it is turned off across this call.
audit_clean=0
if LLM_EKS_WINDOW_WRITE=0 "$REPO_ROOT/scripts/audit.sh"; then
  audit_clean=1
fi

# ------------------------------------------------------------------ 3. disarm

info ""
info "step 3/3: the timer"

if [ "$audit_clean" -ne 1 ]; then
  cat >&2 <<EOF

${C_RED}${C_BOLD}THE TIMER STAYS ARMED.${C_RESET}

The audit is dirty, so this script will not disarm anything. That is deliberate: the
one-shot timer and the always-on sweeper are the only things standing between what is
still running and an open-ended bill, and removing them because a teardown was
untidy is exactly the wrong reaction.

${C_RED}CLOUD WINDOW NOT CLOSED.${C_RESET}

Fix the orphans the audit listed — that is the only permitted activity now
(workspace rules, Rule 2b) — and run 'mise run down' again. The timer will disarm itself
from this script the moment the audit is clean, and not before.
EOF
  exit 1
fi

if [ -z "$ARMED_TIMERS" ]; then
  check PASS "timer" "nothing was armed; nothing to disarm"
else
  while IFS= read -r timer; do
    [ -n "$timer" ] || continue
    if aws_write scheduler delete-schedule --name "$timer" --group-name "$WINDOW_GROUP_NAME" \
         --region "$WORK_REGION"; then
      check PASS "timer disarmed" "$timer"
    else
      check FAIL "timer disarm" "could not delete $timer — delete it by hand before opening the next window"
    fi
  done <<<"$ARMED_TIMERS"
fi

# A one-time schedule counts against the account quota even after it has fired, which
# is why they are deleted rather than left to expire.
# https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html
remaining="$(aws_ro scheduler list-schedules --group-name "$WINDOW_GROUP_NAME" \
  --region "$WORK_REGION" --output json | jq -r '[.Schedules[].Name] | join(", ")')"
if [ -n "$remaining" ]; then
  die "timers still present after the disarm: $remaining. Do not report the window closed."
fi

# ------------------------------------------------------------------ hand back

closed_at="$(date -u '+%Y-%m-%d %H:%M:%SZ')"

cat >&2 <<EOF

${C_GREEN}${C_BOLD}CLOUD WINDOW CLOSED, audit clean, timer disarmed.${C_RESET}

One step is left and it is yours, not this script's: append the window entry to
materials/costs/windows.md. Nothing in repo/ writes to materials/ except the
boundary drill, and a cost record written by the thing being measured is not a cost
record.

    ## Window <n> — <purpose>
    opened     <time>
    closed     $closed_at
    approved   max <h>h, max \$<amount>
    actual     \$<from Cost Explorer, once the charges settle>
    status     CLOSED

Then update materials/journal/STATE.md and the dated journal entry, and check
materials/blog/SHOTLIST.md for captures that were missed while the window was open.
EOF
