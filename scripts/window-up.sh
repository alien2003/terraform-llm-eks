#!/usr/bin/env bash
# mise run up WINDOW_ID=<n> WINDOW_HOURS=<h>
#
# Opens a cloud window. Rule 2b of the workspace rules fixes the order, and this
# script is that order made mechanical:
#
#   1. WINDOW_ID and WINDOW_HOURS are required, and are taken verbatim from the
#      approval message. There is no default and no prompt for them: a window that
#      can be opened by typing `mise run up` is not a window.
#   2. guard-status must be green. If it is not, the window does not open.
#   3. The window's own limits are read from the guardrails stack rather than held
#      here. The always-on sweeper terminates project compute past a fixed age, and a
#      WINDOW_HOURS longer than that age is a window the sweeper kills from underneath
#      the person using it. Both numbers are published by infra/guardrails to one SSM
#      parameter, and this script reads them and fails closed if it cannot.
#   4. The estimated cost is read from scripts/rates.json and printed twice: at the
#      steady state an open window sits at, and at the ceiling the stack itself
#      permits. The ceiling is the figure in the confirmation prompt, because that is
#      what the `max $<amount>` in the approval message has to be checked against. If
#      any rate is missing the script stops. It never guesses a price.
#   5. The one-shot kill timer is armed BEFORE anything is applied. This is the
#      safety property: if the apply hangs, if the session dies, if the human walks
#      away, the timer still fires and the kill Lambda still terminates everything.
#      Arming after the apply would leave a hole exactly the width of the apply.
#   6. Only then, terraform apply, bootstrap before cluster.
#
# Running it twice is safe. An already-armed timer is reported and left alone rather
# than pushed further into the future: extending a window needs a new approval
# message, not a second invocation of this script.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd aws jq terraform

MIN_WINDOW_HOURS=0.25

# There is deliberately no MAX_WINDOW_HOURS constant here. The upper bound belongs to
# the guardrails stack, which derives the sweeper's age threshold from it, and a copy
# in this file is a copy that goes stale in the direction that hurts: a window longer
# than the sweeper tolerates dies mid-benchmark and the obvious-looking fix is to
# raise the one variable in that stack that should only ever go down. The value is
# read from SSM in step 2 and this script refuses to open a window without it.
LIMITS_PARAMETER="/${NAME_PREFIX}/guardrails/limits"

usage() {
  cat >&2 <<'USAGE'
usage: mise run up WINDOW_ID=<n> WINDOW_HOURS=<h>

Both come verbatim from the approval message, which has exactly this form and no
other:

    APPROVE CLOUD WINDOW <n>: <purpose>; max <hours>h; max $<amount>

Nothing else counts as approval. Not "yes", not "go ahead", not "sounds good".
USAGE
}

# ADR 0050. mise hands a task's declared arguments over as one shell-quoted string in
# usage_<argname>, not as positionals, so re-expand when no real positional was given.
if [ "$#" -eq 0 ]; then
  _usage_vars="$(mise_usage_arg vars)"
  if [ -n "$_usage_vars" ]; then
    eval "set -- $_usage_vars"
  fi
fi

WINDOW_ID=""
WINDOW_HOURS=""
for pair in "$@"; do
  case "$pair" in
    WINDOW_ID=*)    WINDOW_ID="${pair#WINDOW_ID=}" ;;
    WINDOW_HOURS=*) WINDOW_HOURS="${pair#WINDOW_HOURS=}" ;;
    *)
      usage
      die "unrecognised argument '$pair'. Only WINDOW_ID=<n> and WINDOW_HOURS=<h> are accepted."
      ;;
  esac
done

if [ -z "$WINDOW_ID" ] || [ -z "$WINDOW_HOURS" ]; then
  usage
  die "WINDOW_ID and WINDOW_HOURS are both required. Copy them from the approval message rather than remembering them."
fi

case "$WINDOW_ID" in
  ''|*[!0-9]*) die "WINDOW_ID must be a whole number; got '$WINDOW_ID'. It becomes part of a schedule name and a resource tag." ;;
esac

case "$WINDOW_HOURS" in
  ''|*[!0-9.]*|*.*.*) die "WINDOW_HOURS must be a number of hours; got '$WINDOW_HOURS'." ;;
esac

if awk -v h="$WINDOW_HOURS" -v lo="$MIN_WINDOW_HOURS" \
  'BEGIN { exit (h >= lo) ? 1 : 0 }'; then
  die "WINDOW_HOURS=$WINDOW_HOURS is below the minimum of ${MIN_WINDOW_HOURS}h. The upper bound is not checked here; it comes from the guardrails stack in step 2."
fi

WINDOW_MINUTES="$(awk -v h="$WINDOW_HOURS" 'BEGIN { printf "%d", (h * 60) + 0.5 }')"
TIMER_NAME="${NAME_PREFIX}-window-${WINDOW_ID}"

heading "opening cloud window $WINDOW_ID — $WINDOW_HOURS h — region $WORK_REGION"

# ------------------------------------------------------------------ 1. guardrails

info "step 1/6: guard-status"
if ! "$REPO_ROOT/scripts/guard-status.sh"; then
  die "guard-status is not green, so the window does not open (workspace rules, Rule 2a). Fix every FAIL it reported first."
fi

if [ "${AWS_PROFILE:-}" = "$ADMIN_ROLE_NAME" ]; then
  die "AWS_PROFILE is $ADMIN_ROLE_NAME. Windows are opened as the operator; the admin profile belongs to window 0's guardrail apply and to the final teardown, and to nothing else (workspace rules, Rule 2a)."
fi

ACCOUNT="$(account_id)"

# ------------------------------------------------------------------ 2. window limits
#
# infra/guardrails publishes max_window_hours and the sweeper's derived age to one SSM
# parameter (its `limits_parameter` output) so that the guardrail's own numbers are the
# only numbers. Two properties are checked here, and both are fatal:
#
#   the requested WINDOW_HOURS is within max_window_hours, and
#   the sweeper's age threshold is longer than max_window_hours,
#
# the second because the sweeper runs whether or not a window is open. If the two ever
# disagree the sweeper wins, silently, at whatever hour it happens to reach.

info ""
info "step 2/6: window limits from $LIMITS_PARAMETER"

if ! LIMITS="$(aws_ro ssm get-parameter --name "$LIMITS_PARAMETER" --region "$WORK_REGION" \
     --query 'Parameter.Value' --output text 2>/dev/null)"; then
  die "cannot read $LIMITS_PARAMETER. That parameter is where infra/guardrails publishes the window and sweeper limits, and this script will not fall back to a hardcoded ceiling: a window opened against a guessed limit is a window the sweeper may end early. Apply the guardrails stack, or fix the operator's ssm read, and run this again."
fi

printf '%s' "$LIMITS" | jq -e 'type == "object"' >/dev/null 2>&1 ||
  die "$LIMITS_PARAMETER does not hold a JSON object. It is written by infra/guardrails and read by this script and by guard-status; something has overwritten it. Do not open a window until it is right."

MAX_WINDOW_HOURS="$(printf '%s' "$LIMITS" | jq -r '.max_window_hours // empty')"
SWEEPER_AGE_MINUTES="$(printf '%s' "$LIMITS" | jq -r '.sweeper_max_age_minutes // empty')"
KILL_DLQ_ARN="$(printf '%s' "$LIMITS" | jq -r '.kill_dlq_arn // empty')"

[ -n "$MAX_WINDOW_HOURS" ] ||
  die "$LIMITS_PARAMETER carries no max_window_hours. Refusing to guess one."
[ -n "$SWEEPER_AGE_MINUTES" ] ||
  die "$LIMITS_PARAMETER carries no sweeper_max_age_minutes. Refusing to open a window without knowing when the always-on sweeper would terminate it."

sweeper_hours="$(awk -v m="$SWEEPER_AGE_MINUTES" 'BEGIN { printf "%.2f", m / 60 }')"

# The guardrails stack derives the sweeper age from max_window_hours plus a margin, so
# this inequality should hold by construction. Checked anyway: it is the whole contract
# between the two controls, and an admin apply with a hand-set value would break it
# without anything else noticing.
if awk -v s="$SWEEPER_AGE_MINUTES" -v h="$MAX_WINDOW_HOURS" \
  'BEGIN { exit (s > h * 60) ? 1 : 0 }'; then
  die "the two limits disagree: the sweeper terminates project compute after ${SWEEPER_AGE_MINUTES}m (${sweeper_hours}h) but a window may be approved for up to ${MAX_WINDOW_HOURS}h. The sweeper runs whether or not a window is open, so it would kill this cluster mid-window. Fix it in infra/guardrails, with the admin profile, before opening anything."
fi

if awk -v h="$WINDOW_HOURS" -v hi="$MAX_WINDOW_HOURS" 'BEGIN { exit (h <= hi) ? 1 : 0 }'; then
  die "WINDOW_HOURS=$WINDOW_HOURS is longer than the ${MAX_WINDOW_HOURS}h the guardrails stack allows. A shorter window than the approval allows is always fine; a longer one needs both a new approval message and an admin apply that raises max_window_hours and the sweeper age with it."
fi

check PASS "window limits" "${WINDOW_HOURS}h requested, ${MAX_WINDOW_HOURS}h allowed, sweeper terminates at ${SWEEPER_AGE_MINUTES}m (${sweeper_hours}h)"

if [ -z "$KILL_DLQ_ARN" ]; then
  warn "$LIMITS_PARAMETER carries no kill_dlq_arn, so the one-shot timer will be armed"
  warn "without a dead-letter queue: an undelivered kill event would be dropped after"
  warn "its retries with nothing to show it existed."
fi

# ------------------------------------------------------------------ 3. cost estimate

info ""
info "step 3/6: cost estimate"

RATES_FILE="${LLM_EKS_RATES_FILE:-$REPO_ROOT/scripts/rates.json}"
if [ ! -f "$RATES_FILE" ]; then
  die "no rates file at $RATES_FILE. The window does not open without one: the protocol requires stating the estimated \$/hour before applying, and this script will not invent a price (workspace rules, Rule 5)."
fi

missing_rates="$(jq -r '[.line_items | to_entries[] | select(.value.usd_per_hour == null) | .key] | join(", ")' "$RATES_FILE")"
if [ -n "$missing_rates" ]; then
  error "these line items in $RATES_FILE have no price yet: $missing_rates"
  log ""
  log "Fill in usd_per_hour, source_url and sourced_on for each, then run this again."
  log "The Spot line is read with:"
  log ""
  log "    aws ec2 describe-spot-price-history --instance-types g6.xlarge \\"
  log "        --product-descriptions 'Linux/UNIX' --max-items 10"
  log ""
  log "which is read-only and allowed in LOCAL mode."
  die "refusing to open a window on an unpriced stack."
fi

rates_region="$(jq -r '.region // "unset"' "$RATES_FILE")"
rates_date="$(jq -r '.sourced_on // "unset"' "$RATES_FILE")"
if [ "$rates_region" != "$WORK_REGION" ]; then
  warn "$RATES_FILE was sourced for region $rates_region but this window runs in $WORK_REGION."
fi

# Two figures per line, not one. `quantity` is the steady state an open window sits
# at; `max_quantity` is the ceiling the stack itself permits, traced in rates.json to
# the variable that enforces it. The GPU line is the one where they differ and it is
# the expensive one: the inference deployment scales to inference_max_replicas, one
# replica per GPU node, so a load test that pushes the vLLM queue past the KEDA
# threshold doubles the GPU line without anything in this tool changing. Printing only
# the steady state is how a $4 approval becomes $8 of spend that nobody agreed to.
read -r BASE_HOUR GPU_HOUR TOTAL_HOUR BASE_MAX_HOUR GPU_MAX_HOUR CEILING_HOUR <<EOF
$(jq -r '
  ([.line_items[] | select(.gpu_only == false) | .usd_per_hour * .quantity]     | add) as $base    |
  ([.line_items[] | select(.gpu_only == true)  | .usd_per_hour * .quantity]     | add) as $gpu     |
  ([.line_items[] | select(.gpu_only == false) | .usd_per_hour * .max_quantity] | add) as $basemax |
  ([.line_items[] | select(.gpu_only == true)  | .usd_per_hour * .max_quantity] | add) as $gpumax  |
  "\($base) \($gpu) \($base + $gpu) \($basemax) \($gpumax) \($basemax + $gpumax)"' "$RATES_FILE")
EOF

projected="$(awk -v t="$TOTAL_HOUR" -v h="$WINDOW_HOURS" 'BEGIN { printf "%.2f", t * h }')"
projected_idle="$(awk -v b="$BASE_HOUR" -v h="$WINDOW_HOURS" 'BEGIN { printf "%.2f", b * h }')"
projected_ceiling="$(awk -v c="$CEILING_HOUR" -v h="$WINDOW_HOURS" 'BEGIN { printf "%.2f", c * h }')"

gpu_nodes_max="$(jq -r '.line_items.gpu_node.max_quantity' "$RATES_FILE")"
gpu_ceiling_source="$(jq -r '.line_items.gpu_node.ceiling_source' "$RATES_FILE")"

cat >&2 <<EOF

  rates from  $RATES_FILE, sourced $rates_date for $rates_region

  steady state, which is what an idle open window costs
    without the GPU node   \$$(printf '%.4f' "$BASE_HOUR")/h
    one GPU node adds      \$$(printf '%.4f' "$GPU_HOUR")/h
    with one GPU node      \$$(printf '%.4f' "$TOTAL_HOUR")/h

  ceiling, which is what the stack is allowed to reach without anyone doing anything
    non-GPU at its ceiling \$$(printf '%.4f' "$BASE_MAX_HOUR")/h
    GPU at its ceiling     \$$(printf '%.4f' "$GPU_MAX_HOUR")/h  ($gpu_nodes_max GPU nodes)
    everything at ceiling  \$$(printf '%.4f' "$CEILING_HOUR")/h

    the GPU ceiling is $gpu_nodes_max node(s): $gpu_ceiling_source

  projected over ${WINDOW_HOURS}h
    GPU node never up                   \$$projected_idle
    one GPU node up the whole time      \$$projected
    everything at its ceiling           \$$projected_ceiling   <-- check this against the approval

  These are hourly charges only. Data transfer, NAT gateway data processing, S3
  requests, ECR storage and CloudWatch Logs ingestion are per-unit and are not in this
  figure; they go into materials/costs/windows.md after the window, from Cost Explorer.
EOF

if ! confirm "Open window $WINDOW_ID for ${WINDOW_HOURS}h at up to \$$projected_ceiling (ceiling, not steady state)?"; then
  die "not confirmed. Nothing was armed and nothing was applied."
fi

# ------------------------------------------------------------------ 4. arm the timer

info ""
info "step 4/6: arm the one-shot kill timer"

# Discovered from the account rather than read out of the guardrails state file: the
# state is local to whoever applied it (ADR 0020), and a window must be openable from
# a machine that has never held it.
KILL_ARN="$(aws_ro lambda get-function --function-name "$KILL_FUNCTION_NAME" \
  --query 'Configuration.FunctionArn' --output text)" ||
  die "cannot find the $KILL_FUNCTION_NAME function. guard-status passed, so this is a race or a permissions change; do not proceed."

SCHEDULER_ROLE_ARN="$(aws_ro iam get-role --role-name "$SCHEDULER_ROLE_NAME" \
  --query 'Role.Arn' --output text)" ||
  die "cannot find the $SCHEDULER_ROLE_NAME role. EventBridge Scheduler needs it to invoke the kill Lambda."

# A second window while one is open is how two timers end up disagreeing about when
# everything dies.
existing="$(aws_ro scheduler list-schedules --group-name "$WINDOW_GROUP_NAME" \
  --region "$WORK_REGION" --output json | jq -r '.Schedules[].Name')"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ "$name" != "$TIMER_NAME" ]; then
    die "a timer for another window is already armed: $name. Close that window with 'mise run down' before opening window $WINDOW_ID."
  fi
done <<<"$existing"

export LLM_EKS_WINDOW_WRITE=1

if printf '%s\n' "$existing" | grep -Fxq "$TIMER_NAME"; then
  fire_expr="$(aws_ro scheduler get-schedule --name "$TIMER_NAME" --group-name "$WINDOW_GROUP_NAME" \
    --region "$WORK_REGION" --query 'ScheduleExpression' --output text)"
  fire_at="${fire_expr#at(}"
  fire_at="${fire_at%)}"
  warn "window $WINDOW_ID is already armed and fires at ${fire_at}Z. Leaving it alone."
  warn "Extending a window is a new approval message, not a second 'mise run up'."
else
  # `at(yyyy-mm-ddThh:mm:ss)` is the one-time schedule form. Both GNU and BSD date
  # can do the arithmetic; neither can do it the other's way.
  # https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html
  if fire_at="$(date -u -d "+${WINDOW_MINUTES} minutes" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)"; then
    :
  elif fire_at="$(date -u -v "+${WINDOW_MINUTES}M" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)"; then
    :
  else
    die "cannot compute the fire time: this date(1) understands neither -d nor -v."
  fi

  # The dead-letter queue matters more here than on the sweeper. The sweeper runs
  # every few minutes, so a dropped invocation is retried by the next one; the one-shot
  # timer fires once, and if that single delivery fails after its retries there is no
  # second chance and, without a DLQ, no evidence either. The queue is created by
  # infra/guardrails and has an alarm on its depth, so a dropped kill event reaches the
  # notices topic rather than nobody.
  # https://docs.aws.amazon.com/scheduler/latest/UserGuide/managing-schedule-dlq.html
  target="$(jq -nc --arg arn "$KILL_ARN" --arg role "$SCHEDULER_ROLE_ARN" \
    --arg dlq "$KILL_DLQ_ARN" \
    --arg input "$(jq -nc --arg w "$WINDOW_ID" '{mode:"kill_all", window_id:$w}')" \
    '{Arn:$arn, RoleArn:$role, Input:$input, RetryPolicy:{MaximumRetryAttempts:3}}
     + (if $dlq == "" then {} else {DeadLetterConfig:{Arn:$dlq}} end)')"

  # ActionAfterCompletion stays NONE. A fired timer that deleted itself leaves no
  # evidence that it fired, and a timer firing is the single most important thing
  # that can happen in this project. window-down deletes it explicitly instead, which
  # is also what AWS recommends for one-time schedules.
  aws_write scheduler create-schedule \
    --name "$TIMER_NAME" \
    --group-name "$WINDOW_GROUP_NAME" \
    --region "$WORK_REGION" \
    --description "One-shot kill timer for cloud window $WINDOW_ID, armed by mise run up." \
    --schedule-expression "at($fire_at)" \
    --schedule-expression-timezone UTC \
    --flexible-time-window '{"Mode":"OFF"}' \
    --action-after-completion NONE \
    --target "$target" >/dev/null ||
    die "could not arm the kill timer. Nothing has been applied; nothing is running. Do not apply anything by hand."

  check PASS "kill timer armed" "$TIMER_NAME fires at ${fire_at}Z"
fi

printf '\n%sThe timer is armed. Project-tagged compute is terminated at %sZ whatever else\nhappens; the sweeper does the same to anything older than %sm regardless.%s\n\n' \
  "$C_BOLD" "$fire_at" "$SWEEPER_AGE_MINUTES" "$C_RESET" >&2

# ------------------------------------------------------------------ 5. apply

info "step 5/6: terraform apply"

# The apply order, in one place, and it is a dependency chain rather than a list.
#
#   infra/bootstrap  creates the Terraform state bucket, the weights bucket and the
#                    ECR pull-through cache. It keeps LOCAL state (ADR 0020) because it
#                    is what creates the bucket a remote backend would need, so it can
#                    be applied first from a cold start. It is idempotent and cheap to
#                    re-apply, and every later window needs it to already exist.
#   infra/cluster    VPC, EKS, Karpenter and, as a child module, the platform layer.
#                    Its backend is the S3 bucket bootstrap creates, which is why the
#                    order is not negotiable.
#
# infra/guardrails is not here and must not be: it is applied with the admin profile in
# window 0 and destroyed with the admin profile in the final window (Rule 2a).
# infra/cluster/platform is not here either. It is a child module of infra/cluster, not
# a root stack: it has no backend, no provider configuration of its own and seven
# variables with no default, so `terraform apply -input=false` against it cannot
# succeed. The parent stack calls it.
#
# The destroy order in window-down.sh is deliberately NOT the reverse of this list.
# Bootstrap holds the state bucket every other stack's backend lives in, and it is
# expected to survive between windows; destroying it from `mise run down` would delete
# the state of the stack being destroyed while the destroy was running.
APPLY_STACKS="${LLM_EKS_APPLY_STACKS:-infra/bootstrap infra/cluster}"

STATE_BUCKET="${NAME_PREFIX}-tfstate-${ACCOUNT}"

for stack in $APPLY_STACKS; do
  dir="$REPO_ROOT/$stack"
  [ -d "$dir" ] || die "no such stack: $stack"

  info ""
  info "--- $stack"

  # A stack with an S3 backend cannot init before the bucket exists, and the raw
  # backend error for that is a wall of text about workspaces. Say it plainly instead,
  # and say which stack was supposed to have created it.
  #
  # The bucket name is read out of the backend block rather than derived, because a
  # backend block cannot take variables and the name in it is therefore a literal that
  # can disagree with the account these credentials belong to. That disagreement is
  # worth catching on its own: it means the checkout is pointed at somebody else's
  # state.
  if grep -Rqs 'backend "s3"' "$dir"/*.tf; then
    backend_bucket="$(sed -n 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$dir"/*.tf | head -n 1)"
    [ -n "$backend_bucket" ] || backend_bucket="$STATE_BUCKET"

    if [ "$backend_bucket" != "$STATE_BUCKET" ]; then
      warn "$stack has its backend on $backend_bucket, but this account's state bucket"
      warn "would be $STATE_BUCKET. One of the two is wrong; check before continuing."
    fi

    if ! aws_ro s3api head-bucket --bucket "$backend_bucket" >/dev/null 2>&1; then
      die "the Terraform state bucket $backend_bucket does not exist or is not readable, so $stack cannot initialise its backend. infra/bootstrap is what creates it and it is applied first in this list; if that apply was skipped or failed, fix it before going further. The timer is armed and nothing is running yet."
    fi
  fi

  terraform -chdir="$dir" init -input=false ||
    die "terraform init failed in $stack. The timer is armed; nothing is running yet."

  apply_args=(-input=false -auto-approve)
  # Resources created inside a window carry Window=<id> so that the audit task can
  # tell one window's leftovers from another's. Only the stacks that declare the
  # variable get it.
  if grep -Rqs 'variable "window_id"' "$dir"/*.tf; then
    apply_args+=(-var "window_id=$WINDOW_ID")
  fi

  if ! terraform -chdir="$dir" apply "${apply_args[@]}"; then
    error "terraform apply failed in $stack."
    log ""
    log "The timer is still armed, so nothing can survive the window even now. Tear down"
    log "first and investigate afterwards (workspace rules, Rule 2b):"
    log ""
    log "    mise run down"
    exit 1
  fi
done

# ------------------------------------------------------------------ 6. hand back

info ""
info "step 6/6: window open"

cat >&2 <<EOF

${C_GREEN}CLOUD WINDOW $WINDOW_ID OPEN.${C_RESET} Timer armed, stacks applied.

  timer      $TIMER_NAME in group $WINDOW_GROUP_NAME
  account    $ACCOUNT
  region     $WORK_REGION
  budget     \$$projected over ${WINDOW_HOURS}h with one GPU node up throughout,
             \$$projected_ceiling if everything reaches its ceiling

Do only the work listed in materials/journal/WINDOW-$WINDOW_ID-PLAN.md. When it is
done, or the moment anything goes wrong, or the moment the human goes quiet:

    mise run down

which destroys, audits, and disarms the timer only if the audit is clean.
EOF
