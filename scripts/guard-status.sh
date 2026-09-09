#!/usr/bin/env bash
# mise run guard-status
#
# Rule 2a of the workspace rules: before every window, every guardrail must be present and
# healthy. If it is not, the window does not open. This script is the definition of
# "green": it exits 0 only when every check below passes.
#
# Present is not the same as healthy, and most of the interesting failures are in the
# gap between them. A topic with an unconfirmed email subscription is present. A kill
# Lambda left in dry-run after a drill is present. A disabled sweeper schedule is
# present. Each of those is checked here.
#
# Every call is read-only. The script creates, modifies and deletes nothing, so it is
# safe in LOCAL mode and safe to run twice.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd aws jq

ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/llm-eks-guard-status.XXXXXX")"
trap 'rm -f "$ERR_FILE"' EXIT

RO_OUT=""
RO_ERR=""

# run_ro <args...> — an aws_ro call whose stdout and stderr are both captured, so a
# failure can be reported as a check rather than ending the run.
run_ro() {
  if RO_OUT="$(aws_ro "$@" 2>"$ERR_FILE")"; then
    RO_ERR=""
    return 0
  fi
  RO_ERR="$(tr '\n' ' ' <"$ERR_FILE" | sed 's/  */ /g')"
  RO_OUT=""
  return 1
}

# short <text> — trim an AWS error down to something that fits a table row.
short() { printf '%.140s' "$1"; }

heading "guard-status — $(date -u '+%Y-%m-%d %H:%M:%SZ') — region $WORK_REGION"

if ! aws_available; then
  error "no usable AWS credentials."
  log ""
  log "guard-status is read-only but it still has to ask the account. Check the profile"
  log "first:"
  log ""
  log "    mise run auth operator"
  exit 1
fi

ACCOUNT="$(account_id)"
PARTITION="$(partition)"
CALLER_ARN="$(aws_ro sts get-caller-identity --query Arn --output text)"

# infra/guardrails publishes the window limits, the kill-path resource names and the
# semantics of each billing alarm to one SSM parameter (its `limits_parameter` output).
# Reading them here rather than restating them is what keeps this script from drifting
# away from the stack it is checking: the sweeper's age, the two alarm names and
# whether SMS was ever turned on are all facts about the applied guardrail, not
# opinions this file is entitled to hold.
LIMITS_PARAMETER="/${NAME_PREFIX}/guardrails/limits"
LIMITS=""
if run_ro ssm get-parameter --name "$LIMITS_PARAMETER" --region "$WORK_REGION" --output json; then
  LIMITS="$(printf '%s' "$RO_OUT" | jq -r '.Parameter.Value')"
  check PASS "guardrail limits published" "$LIMITS_PARAMETER"
else
  check FAIL "guardrail limits published" "cannot read $LIMITS_PARAMETER: $(short "$RO_ERR"). Several checks below have nothing to compare against without it, and 'mise run up' refuses to open a window at all."
fi

limit() { # limit <jq-path> — one value out of the published limits, or empty
  #
  # Never fails. This script's contract is that it runs every check and prints a
  # table; a malformed parameter has to turn into an empty value that the checks
  # below report on, not into a jq exit status that ends the run under set -e with
  # half the guardrail unexamined.
  [ -n "$LIMITS" ] || return 0
  printf '%s' "$LIMITS" | jq -r "$1 // empty" 2>/dev/null || true
}

limit_list() { # limit_list <jq-path> — the elements of a published list, one per line
  #
  # Same contract as limit(): an absent or malformed list is empty output, never a
  # non-zero exit. Two of the published values are lists — the kill-path alarm names
  # and the regions the kill Lambda sweeps — and both are checked below.
  [ -n "$LIMITS" ] || return 0
  printf '%s' "$LIMITS" | jq -r "($1 // []) | .[]" 2>/dev/null || true
}

case "$CALLER_ARN" in
  *":assumed-role/${OPERATOR_ROLE_NAME}/"*)
    check PASS "caller identity" "$OPERATOR_ROLE_NAME in $ACCOUNT" ;;
  *":assumed-role/${ADMIN_ROLE_NAME}/"*)
    check WARN "caller identity" "running as $ADMIN_ROLE_NAME — only correct in window 0 or the final teardown step" ;;
  *)
    check FAIL "caller identity" "$CALLER_ARN is neither the operator nor the admin role" ;;
esac

# ------------------------------------------------------------------ operator role

if run_ro iam get-role --role-name "$OPERATOR_ROLE_NAME" --output json; then
  boundary_arn="$(printf '%s' "$RO_OUT" | jq -r '.Role.PermissionsBoundary.PermissionsBoundaryArn // empty')"
  if [ -z "$boundary_arn" ]; then
    check FAIL "operator role boundary" "the role exists and carries NO permission boundary — it is unconstrained"
  elif [ "$boundary_arn" = "arn:${PARTITION}:iam::${ACCOUNT}:policy/${OPERATOR_BOUNDARY_NAME}" ]; then
    check PASS "operator role boundary" "$OPERATOR_BOUNDARY_NAME"
  else
    check FAIL "operator role boundary" "carries $boundary_arn, not $OPERATOR_BOUNDARY_NAME"
  fi
else
  check FAIL "operator role" "$(short "$RO_ERR")"
fi

BOUNDARY_ARN="arn:${PARTITION}:iam::${ACCOUNT}:policy/${OPERATOR_BOUNDARY_NAME}"
# Kept rather than scoped to the block below: the kill Lambda's region check reads the
# document of this exact version, so it has to know which version is in force.
BOUNDARY_VERSION=""
if run_ro iam get-policy --policy-arn "$BOUNDARY_ARN" --output json; then
  BOUNDARY_VERSION="$(printf '%s' "$RO_OUT" | jq -r '.Policy.DefaultVersionId')"
  attachments="$(printf '%s' "$RO_OUT" | jq -r '.Policy.PermissionsBoundaryUsageCount')"
  check PASS "boundary policy" "$BOUNDARY_VERSION, boundary of $attachments entities"
else
  check FAIL "boundary policy" "$(short "$RO_ERR")"
fi

# ------------------------------------------------------------------ budget

if run_ro budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" \
     --region "$BILLING_REGION" --output json; then
  limit="$(printf '%s' "$RO_OUT" | jq -r '.Budget.BudgetLimit.Amount + " " + .Budget.BudgetLimit.Unit')"
  # Rule 2a of the workspace rules: every threshold is on GROSS spend, credits excluded. If the
  # budget has stopped excluding credits it will read zero forever and protect nothing.
  credits_excluded="$(printf '%s' "$RO_OUT" |
    jq -r '[.Budget.CostTypes.IncludeCredit, .Budget.CostTypes.IncludeRefund] | map(. == false) | all')"
  if [ "$credits_excluded" = "true" ]; then
    check PASS "budget $BUDGET_NAME" "$limit gross, credits and refunds excluded"
  else
    check FAIL "budget $BUDGET_NAME" "$limit but CostTypes counts credits — thresholds would never fire"
  fi
else
  check FAIL "budget $BUDGET_NAME" "$(short "$RO_ERR")"
fi

if run_ro budgets describe-budget-actions-for-budget --account-id "$ACCOUNT" \
     --budget-name "$BUDGET_NAME" --region "$BILLING_REGION" --output json; then
  action_count="$(printf '%s' "$RO_OUT" | jq -r '.Actions | length')"
  if [ "$action_count" -ge 1 ]; then
    action_status="$(printf '%s' "$RO_OUT" | jq -r '.Actions[0].Status')"
    action_value="$(printf '%s' "$RO_OUT" | jq -r '.Actions[0].ActionThreshold.ActionThresholdValue')"
    case "$action_status" in
      STANDBY|PENDING)  check PASS "budget action" "armed at \$$action_value, status $action_status" ;;
      EXECUTION_SUCCESS) check FAIL "budget action" "ALREADY EXECUTED — the deny policy is attached to the operator. Money has been spent; stop and read materials/costs/." ;;
      *)                check WARN "budget action" "status $action_status at \$$action_value" ;;
    esac
  else
    check FAIL "budget action" "no action on the budget — the automatic stop does not exist"
  fi
else
  check FAIL "budget action" "$(short "$RO_ERR")"
fi

# ------------------------------------------------------------------ anomaly detection

if run_ro ce get-anomaly-monitors --region "$BILLING_REGION" --output json; then
  monitor_arn="$(printf '%s' "$RO_OUT" |
    jq -r --arg n "$ANOMALY_MONITOR_NAME" '.AnomalyMonitors[] | select(.MonitorName == $n) | .MonitorArn' | head -n 1)"
  if [ -n "$monitor_arn" ]; then
    check PASS "anomaly monitor" "$ANOMALY_MONITOR_NAME"
  else
    check FAIL "anomaly monitor" "$ANOMALY_MONITOR_NAME not found (STATE.md open question 3: is Cost Anomaly Detection available on a Free Plan account?)"
  fi
else
  check FAIL "anomaly monitor" "$(short "$RO_ERR")"
fi

if run_ro ce get-anomaly-subscriptions --region "$BILLING_REGION" --output json; then
  sub_freq="$(printf '%s' "$RO_OUT" |
    jq -r --arg n "$ANOMALY_SUBSCRIPTION_NAME" '.AnomalySubscriptions[] | select(.SubscriptionName == $n) | .Frequency' | head -n 1)"
  if [ -n "$sub_freq" ]; then
    check PASS "anomaly subscription" "$ANOMALY_SUBSCRIPTION_NAME, frequency $sub_freq"
  else
    check FAIL "anomaly subscription" "$ANOMALY_SUBSCRIPTION_NAME not found — the monitor would detect and tell nobody"
  fi
else
  check FAIL "anomaly subscription" "$(short "$RO_ERR")"
fi

# ------------------------------------------------------------------ billing alarms
#
# Two alarms on the same metric, and they mean different things. Treating them the
# same is how a month's worth of windows gets blocked by one that has already served
# its purpose.
#
#   The cumulative alarm watches AWS/Billing EstimatedCharges, which is month-to-date
#   and only ever rises within a month. It therefore crosses its threshold at most
#   once per calendar month, fires once, and then sits in ALARM until the month rolls
#   over. ALARM on it means "gross spend has crossed the threshold at some point this
#   month". That is worth knowing and worth reading Cost Explorer over; it is not
#   evidence that anything is spending now, and failing on it would mean no window can
#   open for the rest of the month, which is exactly the kind of pressure that gets a
#   guardrail edited rather than obeyed.
#
#   The burn-rate alarm watches the DIFF of the same metric: dollars added since the
#   previous datapoint. It can fire repeatedly and it clears on its own, so ALARM on
#   it means spend is being added right now. That one is a hard failure.
#
# Both names and both descriptions come from the guardrails stack rather than from
# here. https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/monitor_estimated_charges_with_cloudwatch.html

# billing_alarm <alarm-name> <severity-when-in-alarm: WARN|FAIL> <label>
billing_alarm() {
  local name="$1" on_alarm="$2" label="$3"
  local state threshold actions reason

  if ! run_ro cloudwatch describe-alarms --alarm-names "$name" \
       --region "$BILLING_REGION" --output json; then
    check FAIL "$label" "$(short "$RO_ERR")"
    return 0
  fi

  state="$(printf '%s' "$RO_OUT" | jq -r '.MetricAlarms[0].StateValue // empty')"
  threshold="$(printf '%s' "$RO_OUT" | jq -r '.MetricAlarms[0].Threshold // empty')"
  actions="$(printf '%s' "$RO_OUT" | jq -r '.MetricAlarms[0].ActionsEnabled // false')"
  # StateReason carries the datapoint that put the alarm where it is, so the figure
  # can be printed without a second get-metric-statistics call.
  reason="$(printf '%s' "$RO_OUT" | jq -r '.MetricAlarms[0].StateReason // ""')"

  if [ -z "$state" ]; then
    check FAIL "$label" "$name does not exist in $BILLING_REGION"
  elif [ "$actions" != "true" ]; then
    check FAIL "$label" "exists at \$$threshold but its actions are disabled"
  elif [ "$state" = "ALARM" ]; then
    if [ "$on_alarm" = "FAIL" ]; then
      check FAIL "$label" "IN ALARM at \$$threshold — $(short "$reason")"
    else
      check WARN "$label" "IN ALARM at \$$threshold. $(short "$reason")"
    fi
  else
    check PASS "$label" "\$$threshold, state $state"
  fi
}

CUMULATIVE_ALARM="$(limit '.billing_alarms.cumulative.name')"
BURN_ALARM="$(limit '.billing_alarms.burn.name')"
[ -n "$CUMULATIVE_ALARM" ] || CUMULATIVE_ALARM="$BILLING_ALARM_NAME"

# Has crossed at some point this month: a warning, with the reason printed.
billing_alarm "$CUMULATIVE_ALARM" WARN "billing alarm (month to date)"

if [ -n "$BURN_ALARM" ]; then
  # Is crossing now: a failure. This is the control that makes warning on the
  # cumulative one safe, so its absence is itself a failure.
  billing_alarm "$BURN_ALARM" FAIL "billing alarm (burn rate)"
else
  check FAIL "billing alarm (burn rate)" "the guardrail limits name no burn-rate alarm. Without one, the cumulative alarm is the only billing control and it can fire at most once a calendar month, so windows later in the month would have no billing backstop at all."
fi

# When the cumulative alarm is in ALARM, say WHEN it entered it. A transition from
# before the last closed window is history; one from after it is this session's
# problem and the author should stop and read Cost Explorer before opening anything.
# DescribeAlarmHistory with HistoryItemType StateUpdate is what answers that.
# https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_DescribeAlarmHistory.html
if run_ro cloudwatch describe-alarms --alarm-names "$CUMULATIVE_ALARM" \
     --region "$BILLING_REGION" --output json &&
   [ "$(printf '%s' "$RO_OUT" | jq -r '.MetricAlarms[0].StateValue // empty')" = "ALARM" ]; then
  if run_ro cloudwatch describe-alarm-history --alarm-name "$CUMULATIVE_ALARM" \
       --history-item-type StateUpdate --max-records 20 \
       --region "$BILLING_REGION" --output json; then
    # HistoryData is documented as "data about the alarm, in JSON format" and for a
    # StateUpdate item it carries the new state; HistorySummary is prose and its
    # wording is not specified anywhere. Either is accepted, so a change to the
    # summary text cannot silently turn this into a check that never matches.
    entered="$(printf '%s' "$RO_OUT" |
      jq -r '[.AlarmHistoryItems[]
              | select(
                  (((.HistoryData // "") | (try (fromjson | .newState.stateValue) catch null)) == "ALARM")
                  or (((.HistorySummary // "") | ascii_downcase) | test("to alarm"))
                )]
             | sort_by(.Timestamp) | last | .Timestamp // empty')"
    if [ -n "$entered" ]; then
      check WARN "billing alarm crossed at" "$entered — compare that against the last CLOSED entry in materials/costs/windows.md. Later than it means the spend is from this window or the one before, and the window does not open until you know why."
    else
      check WARN "billing alarm crossed at" "the alarm is in ALARM but its StateUpdate history shows no transition into ALARM in the last 20 records. Read Cost Explorer before opening a window."
    fi
  else
    check WARN "billing alarm crossed at" "cannot read the alarm history: $(short "$RO_ERR"). The month-to-date alarm is in ALARM and this script cannot tell you when it got there; check Cost Explorer by hand."
  fi
fi

# The alarm cannot fire on a metric that has never been published. AWS/Billing
# EstimatedCharges only appears once charges accrue, and on a several-hour cadence,
# so an empty result on a fresh account is expected rather than broken. STATE.md
# records this as a window 0 entry condition.
if run_ro cloudwatch list-metrics --namespace AWS/Billing --metric-name EstimatedCharges \
     --region "$BILLING_REGION" --output json; then
  metric_count="$(printf '%s' "$RO_OUT" | jq -r '.Metrics | length')"
  if [ "$metric_count" -gt 0 ]; then
    check PASS "billing metric published" "$metric_count AWS/Billing EstimatedCharges series"
  else
    check WARN "billing metric published" "no series yet — the alarm cannot fire until AWS publishes one. Expected on an account with no charges."
  fi
else
  check WARN "billing metric published" "$(short "$RO_ERR")"
fi

# ------------------------------------------------------------------ alert topic

TOPIC_ARN="arn:${PARTITION}:sns:${BILLING_REGION}:${ACCOUNT}:${ALERT_TOPIC_NAME}"
if run_ro sns get-topic-attributes --topic-arn "$TOPIC_ARN" --region "$BILLING_REGION" --output json; then
  check PASS "alert topic" "$ALERT_TOPIC_NAME"

  if run_ro sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --region "$BILLING_REGION" --output json; then
    # An unconfirmed subscription has the literal string "PendingConfirmation" in
    # place of its ARN, so it is counted rather than trusted. Compare case- and
    # space-insensitively: the API reference spells it "pending confirmation" in one
    # place and PendingConfirmation in another, and a guardrail check should not
    # depend on which.
    # https://docs.aws.amazon.com/cli/latest/reference/sns/subscribe.html
    total_subs="$(printf '%s' "$RO_OUT" | jq -r '.Subscriptions | length')"
    pending="$(printf '%s' "$RO_OUT" |
      jq -r '[.Subscriptions[] | select((.SubscriptionArn | ascii_downcase | gsub(" ";"")) == "pendingconfirmation")] | length')"
    confirmed=$((total_subs - pending))
    protocols="$(printf '%s' "$RO_OUT" |
      jq -r '[.Subscriptions[] | select((.SubscriptionArn | ascii_downcase | gsub(" ";"")) != "pendingconfirmation") | .Protocol] | sort | unique | join(",")')"

    if [ "$confirmed" -eq 0 ]; then
      check FAIL "alert subscriptions" "$total_subs subscriptions, none confirmed — every alert would be delivered to nobody"
    elif [ "$pending" -gt 0 ]; then
      check FAIL "alert subscriptions" "$confirmed confirmed ($protocols) but $pending still PendingConfirmation — the human has not clicked the link"
    else
      check PASS "alert subscriptions" "$confirmed confirmed: $protocols"
    fi

    # "Confirmed" is a lie for SMS and this check used to tell it. An SMS subscription
    # is given a real SubscriptionArn immediately, with no confirmation handshake, so
    # the PendingConfirmation logic above counts it as confirmed the moment it exists.
    # Whether anything is ever delivered is decided somewhere else entirely: a new
    # account is in the SNS SMS sandbox, where a message reaches only destination
    # numbers that have been added and verified. An unverified number receives nothing
    # and looks healthy from here.
    # https://docs.aws.amazon.com/sns/latest/dg/sns-sms-sandbox.html
    sms_endpoints="$(printf '%s' "$RO_OUT" |
      jq -r '.Subscriptions[] | select(.Protocol == "sms") | .Endpoint')"

    if [ -z "$sms_endpoints" ]; then
      if [ "$(limit '.sms_enabled')" = "true" ]; then
        check FAIL "SMS delivery" "the guardrail limits say SMS is enabled but no sms subscription exists on $ALERT_TOPIC_NAME"
      else
        check PASS "SMS delivery" "no SMS subscription; email is the alert path and the guardrail limits agree"
      fi
    elif ! run_ro sns get-sms-sandbox-account-status --region "$BILLING_REGION" --output json; then
      check WARN "SMS delivery" "cannot read the SMS sandbox status ($(short "$RO_ERR")), so this script cannot tell you whether an SMS would arrive. Check by hand before relying on it: 'aws sns get-sms-sandbox-account-status' and 'aws sns list-sms-sandbox-phone-numbers', and treat the SMS path as unproven until both agree."
    else
      in_sandbox="$(printf '%s' "$RO_OUT" | jq -r '.IsInSandbox')"
      if [ "$in_sandbox" != "true" ]; then
        check PASS "SMS delivery" "the account is out of the SMS sandbox, so delivery is not gated on per-number verification"
      elif ! run_ro sns list-sms-sandbox-phone-numbers --region "$BILLING_REGION" --output json; then
        check WARN "SMS delivery" "the account is in the SMS sandbox and the verified-number list could not be read ($(short "$RO_ERR")). Run 'aws sns list-sms-sandbox-phone-numbers' by hand; any subscribed number that is not Verified receives nothing."
      else
        verified="$(printf '%s' "$RO_OUT" |
          jq -r '[.PhoneNumbers[] | select(.Status == "Verified") | .PhoneNumber] | join("\n")')"
        unverified=""
        while IFS= read -r number; do
          [ -n "$number" ] || continue
          printf '%s\n' "$verified" | grep -Fxq "$number" ||
            unverified="${unverified:+$unverified }$number"
        done <<<"$sms_endpoints"

        if [ -n "$unverified" ]; then
          check FAIL "SMS delivery" "the account is in the SNS SMS sandbox and $(printf '%s' "$unverified" | wc -w | tr -d ' ') subscribed number(s) are not Verified — those messages are dropped and the subscription still reads as confirmed. Verify with 'aws sns create-sms-sandbox-phone-number' then 'aws sns verify-sms-sandbox-phone-number', or drop alert_phone and rely on email."
        else
          check WARN "SMS delivery" "every subscribed number is Verified in the sandbox. Verification is necessary but not sufficient: AWS also requires an origination identity for some destinations, which this script cannot check. Send yourself one real alert before trusting the SMS path."
        fi
      fi
    fi

    # The kill Lambda subscribes to the same topic, which is what makes a spend alert
    # a teardown rather than a notification.
    if printf '%s' "$RO_OUT" | jq -e --arg fn "$KILL_FUNCTION_NAME" \
         '.Subscriptions[] | select(.Protocol == "lambda") | select(.Endpoint | endswith(":" + $fn))' >/dev/null; then
      check PASS "kill Lambda subscribed" "an alert on $ALERT_TOPIC_NAME triggers a teardown"
    else
      check FAIL "kill Lambda subscribed" "$KILL_FUNCTION_NAME is not subscribed — alerts would notify but not act"
    fi
  else
    check FAIL "alert subscriptions" "$(short "$RO_ERR")"
  fi
else
  check FAIL "alert topic" "$(short "$RO_ERR")"
fi

# ------------------------------------------------------------------ kill Lambda

if run_ro lambda get-function --function-name "$KILL_FUNCTION_NAME" --output json; then
  fn_state="$(printf '%s' "$RO_OUT" | jq -r '.Configuration.State // "Unknown"')"
  fn_dry="$(printf '%s' "$RO_OUT" | jq -r '.Configuration.Environment.Variables.DRY_RUN // "false"')"
  fn_tag="$(printf '%s' "$RO_OUT" | jq -r '.Configuration.Environment.Variables.PROJECT_TAG // ""')"
  fn_age="$(printf '%s' "$RO_OUT" | jq -r '.Configuration.Environment.Variables.MAX_AGE_MINUTES // "?"')"
  fn_regions="$(printf '%s' "$RO_OUT" | jq -r '.Configuration.Environment.Variables.REGIONS // ""')"

  if [ "$fn_state" != "Active" ]; then
    check FAIL "kill Lambda" "state $fn_state — it cannot be invoked"
  elif [ "$fn_dry" != "false" ]; then
    check FAIL "kill Lambda" "DRY_RUN=$fn_dry — it reports and terminates nothing. Left over from a drill; an admin apply is needed to clear it."
  elif [ "$fn_tag" != "$PROJECT_TAG" ]; then
    check FAIL "kill Lambda" "PROJECT_TAG=$fn_tag, not $PROJECT_TAG — it would sweep the wrong set of instances"
  else
    check PASS "kill Lambda" "Active, live, sweeping $PROJECT_TAG older than ${fn_age}m"
  fi

  # The sweeper-age contract, checked against the live function rather than against
  # anybody's copy of it. The always-on sweeper terminates project compute past
  # MAX_AGE_MINUTES whether or not a window is open, so if that age is not longer than
  # the longest window the approval form can grant, the sweeper kills a cluster
  # somebody is legitimately using, halfway through, at full cost and with the
  # measurements lost. The guardrails stack derives one from the other for exactly this
  # reason; this is the check that the derivation is what is actually deployed.
  max_hours="$(limit '.max_window_hours')"
  published_age="$(limit '.sweeper_max_age_minutes')"

  if [ -z "$max_hours" ] || [ -z "$published_age" ]; then
    check FAIL "sweeper age contract" "the guardrail limits do not publish both max_window_hours and sweeper_max_age_minutes, so the contract between the window length and the sweeper cannot be checked. 'mise run up' refuses to open a window in this state."
  elif [ "$fn_age" != "$published_age" ]; then
    check FAIL "sweeper age contract" "the kill Lambda sweeps at ${fn_age}m but the guardrail limits publish ${published_age}m. The two came from the same apply and they disagree, so one of them is stale; do not open a window until they match."
  elif awk -v a="$published_age" -v h="$max_hours" 'BEGIN { exit (a > h * 60) ? 1 : 0 }'; then
    check FAIL "sweeper age contract" "the sweeper terminates project compute after ${published_age}m but a window may be approved for up to ${max_hours}h (=$(awk -v h="$max_hours" 'BEGIN { printf "%d", h * 60 }')m). A window at the maximum would be swept from underneath itself. This needs an admin apply of infra/guardrails, and the variable to raise is max_window_hours, never the sweeper age on its own."
  else
    check PASS "sweeper age contract" "sweeper at ${published_age}m, longest approvable window ${max_hours}h — the sweeper outlasts it"
  fi

  # The region contract. The kill Lambda sweeps the regions named in its REGIONS
  # variable and nothing else, and the boundary's RegionLock statement decides which
  # regions the operator can create anything in. A region the boundary permits and the
  # Lambda does not sweep is a region where a mis-set AWS_REGION can leave a GPU node
  # running that no automatic control will ever reach — the sweeper will not see it,
  # the one-shot window timer will not see it, and `mise run audit` scans the working
  # region. So the two lists are compared here rather than assumed to agree.
  #
  # Two comparisons, because they catch different failures. Against the published
  # limits: those come from the same apply as the function, so a disagreement means
  # one of them is stale. Against the deployed boundary document: that is the list
  # actually being enforced, and it is the one that matters if a boundary was applied
  # without redeploying the function.
  fn_region_list="$(printf '%s' "$fn_regions" | tr ',' '\n' | sed '/^[[:space:]]*$/d' |
    tr -d '[:blank:]' | sort -u | paste -sd, -)"
  published_region_list="$(limit_list '.kill_regions' | sed '/^[[:space:]]*$/d' |
    tr -d '[:blank:]' | sort -u | paste -sd, -)"

  if [ -z "$fn_region_list" ]; then
    check FAIL "kill Lambda regions" "the function publishes no REGIONS variable, so it sweeps nothing. This needs an admin apply of infra/guardrails."
  elif [ -z "$published_region_list" ]; then
    check FAIL "kill Lambda regions" "the function sweeps $fn_region_list but the guardrail limits publish no kill_regions list to check it against."
  elif [ "$fn_region_list" != "$published_region_list" ]; then
    check FAIL "kill Lambda regions" "the function sweeps $fn_region_list, the guardrail limits publish $published_region_list. They came from the same apply and they disagree, so one is stale."
  else
    check PASS "kill Lambda regions" "$fn_region_list, matching the published kill_regions"
  fi

  # RegionLock is a Deny over everything except the global services with
  # StringNotEquals on aws:RequestedRegion, so the values of that condition are the
  # regions the operator may reach.
  # https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html
  if [ -z "$BOUNDARY_VERSION" ]; then
    check FAIL "boundary region lock" "the boundary policy could not be read above, so the regions it permits cannot be compared with the ones the kill Lambda sweeps."
  elif run_ro iam get-policy-version --policy-arn "$BOUNDARY_ARN" \
         --version-id "$BOUNDARY_VERSION" --output json; then
    boundary_doc="$(maybe_urldecode "$(printf '%s' "$RO_OUT" |
      jq -r '.PolicyVersion.Document | if type == "string" then . else tojson end')")"
    boundary_region_list="$(printf '%s' "$boundary_doc" |
      jq -r '[.Statement[] | select(.Sid == "RegionLock")
              | .Condition.StringNotEquals["aws:RequestedRegion"]] | flatten | .[]' 2>/dev/null |
      sed '/^[[:space:]]*$/d' | sort -u | paste -sd, -)"

    if [ -z "$boundary_region_list" ]; then
      check FAIL "boundary region lock" "$BOUNDARY_VERSION of $OPERATOR_BOUNDARY_NAME has no RegionLock statement with a StringNotEquals on aws:RequestedRegion. The operator can create resources in any region and nothing sweeps them."
    elif [ "$boundary_region_list" != "$fn_region_list" ]; then
      check FAIL "boundary region lock" "the boundary permits $boundary_region_list, the kill Lambda sweeps $fn_region_list. Anything created in the difference is unreachable by every automatic control. Do not open a window."
    else
      check PASS "boundary region lock" "$boundary_region_list, and the kill Lambda sweeps exactly those"
    fi
  else
    check FAIL "boundary region lock" "cannot read $BOUNDARY_VERSION of the boundary: $(short "$RO_ERR"). The check is inconclusive; the operator needs iam:GetPolicyVersion."
  fi
else
  check FAIL "kill Lambda" "$(short "$RO_ERR")"
fi

# ------------------------------------------------------------------ kill-path alarms
#
# The alarms that answer "is the kill path still working". They are the only thing
# that can say the always-on sweeper has stopped running, that a scheduled teardown
# was dropped after its retries, or that the Lambda raised half-way through a stop.
# None of them publish to the alert topic, on purpose: that topic invokes the kill
# Lambda, so alarming on the kill Lambda's own failures into it would answer a broken
# teardown by asking the broken teardown to run again.
#
# Their names come from the guardrail limits rather than from this file, so adding a
# fifth alarm to the stack brings it into this check with no edit here.
#
# INSUFFICIENT_DATA fails rather than warns. An alarm in that state is not evaluating,
# and an alarm that is not evaluating is indistinguishable from one that is healthy
# until the moment it was needed. The one honest exception is an alarm applied minutes
# ago, which reads INSUFFICIENT_DATA until its first evaluation period elapses, so the
# period and the timestamp are printed and the answer is to run this again rather than
# to assume.
# https://docs.aws.amazon.com/cli/latest/reference/cloudwatch/describe-alarms.html

KILL_ALARM_NAMES=()
while IFS= read -r kill_alarm; do
  [ -n "$kill_alarm" ] && KILL_ALARM_NAMES+=("$kill_alarm")
done < <(limit_list '.kill_path_alarms')

if [ "${#KILL_ALARM_NAMES[@]}" -eq 0 ]; then
  check FAIL "kill-path alarms" "the guardrail limits publish no kill_path_alarms list, so nothing here checks the alarms on the only control that can stop money being spent. They are published for this check; if the list is gone, so is the check."
elif run_ro cloudwatch describe-alarms --alarm-names "${KILL_ALARM_NAMES[@]}" \
       --region "$WORK_REGION" --output json; then
  KILL_ALARMS_JSON="$RO_OUT"
  for kill_alarm in "${KILL_ALARM_NAMES[@]}"; do
    # Composite alarms are searched too. describe-alarms returns them in their own
    # list, and an alarm converted to a composite one is still the alarm the limits
    # name; reporting it as absent would be wrong.
    alarm_row="$(printf '%s' "$KILL_ALARMS_JSON" | jq -c --arg n "$kill_alarm" \
      '((.MetricAlarms // []) + (.CompositeAlarms // []))[] | select(.AlarmName == $n)' | head -n 1)"

    if [ -z "$alarm_row" ]; then
      check FAIL "kill-path alarm" "$kill_alarm is named in the guardrail limits and does not exist in $WORK_REGION. Either the stack was applied without it or somebody deleted it; the kill path has no detection on that failure."
      continue
    fi

    alarm_state="$(printf '%s' "$alarm_row" | jq -r '.StateValue // "?"')"
    alarm_actions_on="$(printf '%s' "$alarm_row" | jq -r '.ActionsEnabled')"
    alarm_period="$(printf '%s' "$alarm_row" | jq -r '.Period // "?"')"
    alarm_since="$(printf '%s' "$alarm_row" | jq -r '.StateUpdatedTimestamp // "?"')"

    if [ "$alarm_actions_on" != "true" ]; then
      check FAIL "kill-path alarm" "$kill_alarm has ActionsEnabled=false — it evaluates and notifies nobody, which is the same as not having it."
      continue
    fi

    case "$alarm_state" in
      OK)
        check PASS "kill-path alarm" "$kill_alarm OK since $alarm_since" ;;
      ALARM)
        check FAIL "kill-path alarm" "$kill_alarm is in ALARM since $alarm_since. The kill path is degraded now: read its description and /aws/lambda/${KILL_FUNCTION_NAME}, then 'mise run audit'. No window opens on a broken teardown." ;;
      INSUFFICIENT_DATA)
        check FAIL "kill-path alarm" "$kill_alarm is INSUFFICIENT_DATA since $alarm_since; it evaluates over ${alarm_period}s periods. If the guardrails stack was applied within the last period this is expected and the answer is to run guard-status again, not to open a window on an alarm that has never evaluated." ;;
      *)
        check FAIL "kill-path alarm" "$kill_alarm reports state $alarm_state, which is none of the three DescribeAlarms documents (OK, ALARM, INSUFFICIENT_DATA)." ;;
    esac
  done
else
  check FAIL "kill-path alarms" "$(short "$RO_ERR")"
fi

# ------------------------------------------------------------------ schedules

if run_ro scheduler get-schedule --name "$SWEEPER_SCHEDULE_NAME" --group-name default \
     --region "$WORK_REGION" --output json; then
  sweeper_state="$(printf '%s' "$RO_OUT" | jq -r '.State')"
  sweeper_expr="$(printf '%s' "$RO_OUT" | jq -r '.ScheduleExpression')"
  sweeper_mode="$(printf '%s' "$RO_OUT" | jq -r '.Target.Input | fromjson | .mode // "?"')"
  if [ "$sweeper_state" = "ENABLED" ]; then
    check PASS "sweeper schedule" "$sweeper_expr, mode $sweeper_mode"
  else
    check FAIL "sweeper schedule" "state $sweeper_state — the always-on control is off"
  fi
else
  check FAIL "sweeper schedule" "$(short "$RO_ERR")"
fi

if run_ro scheduler get-schedule-group --name "$WINDOW_GROUP_NAME" --region "$WORK_REGION" --output json; then
  group_state="$(printf '%s' "$RO_OUT" | jq -r '.State')"
  if [ "$group_state" = "ACTIVE" ]; then
    check PASS "window schedule group" "$WINDOW_GROUP_NAME"
  else
    check FAIL "window schedule group" "state $group_state — mise run up has nowhere to arm the timer"
  fi
else
  check FAIL "window schedule group" "$(short "$RO_ERR")"
fi

# A timer still armed outside a window means the last window did not close cleanly.
if run_ro scheduler list-schedules --group-name "$WINDOW_GROUP_NAME" --region "$WORK_REGION" --output json; then
  armed="$(printf '%s' "$RO_OUT" | jq -r '[.Schedules[].Name] | join(", ")')"
  if [ -z "$armed" ]; then
    check PASS "no window timer armed" "the group is empty, as it should be between windows"
  else
    check WARN "window timer armed" "$armed — a window is open, or the last one did not close. Run 'mise run audit'."
  fi
else
  check FAIL "window timers" "$(short "$RO_ERR")"
fi

if run_ro iam get-role --role-name "$SCHEDULER_ROLE_NAME" --output json; then
  check PASS "scheduler execution role" "$SCHEDULER_ROLE_NAME"
else
  check FAIL "scheduler execution role" "$(short "$RO_ERR") — mise run up cannot pass a role to the timer"
fi

# ------------------------------------------------------------------ service quotas
#
# Phase 0 established that the L- codes are undocumented and must be discovered at
# run time, and that the discovery call is list-aws-default-service-quotas rather
# than list-service-quotas, which omits any quota that has never had an applied value
# — which is exactly the set of accelerator quotas that must read zero. ADR 0054.
# No L- code appears in this file.
#
# What each target means is read from the target, not guessed from its value. A quota
# that has to be raised for the project to work and a quota that has to stay small are
# opposite requirements, and testing both as "at least the target" is how an account
# whose Standard quota AWS has quietly raised reports PASS. See the block below.

if run_ro ssm get-parameter --name "$QUOTA_TARGETS_PARAMETER" --region "$WORK_REGION" --output json; then
  QUOTA_TARGETS="$(printf '%s' "$RO_OUT" | jq -r '.Parameter.Value')"
else
  QUOTA_TARGETS=""
  check FAIL "quota targets" "cannot read $QUOTA_TARGETS_PARAMETER: $(short "$RO_ERR")"
fi

if [ -n "$QUOTA_TARGETS" ]; then
  services="$(printf '%s' "$QUOTA_TARGETS" | jq -r '[.[].service_code] | unique | .[]')"
  DEFAULTS_ALL="[]"
  defaults_ok=1
  for service in $services; do
    if run_ro service-quotas list-aws-default-service-quotas --service-code "$service" \
         --region "$WORK_REGION" --output json; then
      DEFAULTS_ALL="$(jq -n --argjson acc "$DEFAULTS_ALL" --argjson new "$(printf '%s' "$RO_OUT" | jq '.Quotas')" \
        '$acc + $new')"
    else
      defaults_ok=0
      check FAIL "quota discovery ($service)" "$(short "$RO_ERR")"
    fi
  done

  if [ "$defaults_ok" -eq 1 ]; then
    while IFS=$'\t' read -r key service_code quota_name target direction note; do
      [ -n "$key" ] || continue

      # Which way the target binds is data, not something inferred here.
      #
      #   floor    the quota must be at least the target. Exactly one quota is a
      #            floor: the GPU Spot one, which starts at a default of zero and has
      #            to be raised or the project cannot run at all.
      #   ceiling  the quota must be no more than the target. Everything the design
      #            relies on staying small.
      #   exact    both, and the default when the target does not say.
      #
      # Defaulting to `exact` rather than to `floor` is the whole point of this block.
      # A floor-only test passes an applied value above the target, and for the two
      # Standard families that is the difference between a two-node system group and a
      # node group large enough to matter. That gap cannot be closed in IAM: per the
      # service authorization reference, eks:CreateNodegroup reads only
      # aws:RequestTag/${TagKey}, aws:ResourceTag/${TagKey} and aws:TagKeys, and
      # eks:UpdateNodegroupConfig only aws:ResourceTag/${TagKey} — neither carries an
      # instance-type, capacity-type or scaling-size condition key, so neither can be
      # filtered by size. The quota is the only ceiling those two calls have.
      # https://docs.aws.amazon.com/service-authorization/latest/reference/list_eks.html
      #
      # "-" rather than an empty field: the reader below splits on tabs, and bash
      # treats a run of tab characters as one delimiter, so an empty column would
      # shift the note into the direction and go unnoticed.
      declared_direction="$direction"
      [ "$declared_direction" != "-" ] || direction="exact"
      case "$direction" in
        floor|ceiling|exact) : ;;
        *)
          check FAIL "quota $key" "the target declares direction \"$declared_direction\", which is not floor, ceiling or exact. Fix it in infra/guardrails; an unrecognised direction is not treated as any of them."
          continue ;;
      esac

      quota_code="$(printf '%s' "$DEFAULTS_ALL" |
        jq -r --arg s "$service_code" --arg n "$quota_name" \
          'map(select(.ServiceCode == $s and .QuotaName == $n)) | .[0].QuotaCode // empty')"
      default_value="$(printf '%s' "$DEFAULTS_ALL" |
        jq -r --arg s "$service_code" --arg n "$quota_name" \
          'map(select(.ServiceCode == $s and .QuotaName == $n)) | .[0].Value // empty')"

      if [ -z "$quota_code" ]; then
        check FAIL "quota $key" "AWS publishes no default quota named \"$quota_name\" for $service_code — the name in SSM is wrong"
        continue
      fi

      # get-service-quota returns the APPLIED value. A quota that has never been
      # changed has no applied value and the call raises NoSuchResourceException, in
      # which case the default is the effective value.
      if run_ro service-quotas get-service-quota --service-code "$service_code" \
           --quota-code "$quota_code" --region "$WORK_REGION" --output json; then
        applied="$(printf '%s' "$RO_OUT" | jq -r '.Quota.Value')"
        origin="applied"
      elif printf '%s' "$RO_ERR" | grep -q 'NoSuchResourceException'; then
        applied="$default_value"
        origin="default"
      else
        check FAIL "quota $key" "$(short "$RO_ERR")"
        continue
      fi

      # jq does the comparison so that fractional quota values compare correctly.
      verdict="$(jq -rn --argjson a "$applied" --argjson t "$target" --arg d "$direction" '
        if   $d == "floor"   then (if $a >= $t then "ok" else "under" end)
        elif $d == "ceiling" then (if $a <= $t then "ok" else "over" end)
        else (if $a == $t then "ok" elif $a < $t then "under" else "over" end) end')"

      # Said out loud on every row, so that a target with no direction is visible in
      # the passing output too and not only when it fails.
      how="$direction $target"
      [ "$declared_direction" != "-" ] || how="$how (the target does not say floor or ceiling, so it is held to an exact match)"

      case "$verdict" in
        ok)
          check PASS "quota $key" "$quota_code = $applied ($origin), $how" ;;
        under)
          check FAIL "quota $key" "$quota_code = $applied ($origin), below $how — raise it before the window. $note" ;;
        over)
          check FAIL "quota $key" "$quota_code = $applied ($origin), ABOVE $how. A quota above its target funds compute that no IAM condition can filter: neither eks:CreateNodegroup nor eks:UpdateNodegroupConfig carries an instance-type, capacity-type or scaling-size condition key, so the quota is the only bound on how large a node group can be. Find out who raised it, or whether AWS raised it, before opening a window; lowering a quota is a support request, not a self-service one. $note" ;;
      esac
    done < <(printf '%s' "$QUOTA_TARGETS" |
      jq -r 'to_entries[] | [.key, .value.service_code, .value.quota_name,
                             (.value.target|tostring), (.value.direction // "-"),
                             (.value.note // "-")] | @tsv')
  fi
fi

# ------------------------------------------------------------------ organizations
#
# Creating or joining an AWS Organization expires the Free Tier credits immediately
# (workspace rules, Rule 2a), so this is checked every time rather than assumed. The
# operator is granted organizations:DescribeOrganization for exactly this reason: a
# denial and a "no organization" answer are different facts and must not look alike.

if run_ro organizations describe-organization --region "$BILLING_REGION" --output json; then
  org_id="$(printf '%s' "$RO_OUT" | jq -r '.Organization.Id')"
  check FAIL "not in an organization" "THE ACCOUNT IS IN ORGANIZATION $org_id — Free Tier credits expire on joining. Stop and tell the author."
elif printf '%s' "$RO_ERR" | grep -q 'AWSOrganizationsNotInUseException'; then
  check PASS "not in an organization" "AWSOrganizationsNotInUseException, which is the answer we want"
elif printf '%s' "$RO_ERR" | grep -qi 'AccessDenied'; then
  check FAIL "not in an organization" "AccessDenied — the check is inconclusive. The operator must hold organizations:DescribeOrganization."
else
  check FAIL "not in an organization" "$(short "$RO_ERR")"
fi

# ------------------------------------------------------------------ free tier
#
# The three read-only Free Tier APIs. Credits are treated as cash, so their state is
# part of the pre-flight rather than something looked up when it is already too late.
# The service has a single endpoint, in us-east-1.
# https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/Welcome.html

if run_ro freetier get-account-plan-state --region "$BILLING_REGION" --output json; then
  plan_type="$(printf '%s' "$RO_OUT" | jq -r '.accountPlanType // "unknown"')"
  plan_status="$(printf '%s' "$RO_OUT" | jq -r '.accountPlanStatus // "unknown"')"
  plan_expiry="$(printf '%s' "$RO_OUT" | jq -r '.accountPlanRemainingCredits.amount // "n/a"')"
  if [ "$plan_type" = "PAID" ]; then
    check FAIL "free tier account plan" "the account is on the PAID plan — credits no longer apply and every threshold means real money"
  else
    check PASS "free tier account plan" "$plan_type, $plan_status, remaining credits $plan_expiry"
  fi
else
  check FAIL "free tier account plan" "$(short "$RO_ERR")"
fi

if run_ro freetier list-account-activities --region "$BILLING_REGION" --output json; then
  act_total="$(printf '%s' "$RO_OUT" | jq -r '.activities | length')"
  act_done="$(printf '%s' "$RO_OUT" | jq -r '[.activities[] | select(.status == "COMPLETED")] | length')"
  check PASS "free tier activities" "$act_done of $act_total completed (STATE.md open question 1)"
else
  check WARN "free tier activities" "$(short "$RO_ERR")"
fi

if run_ro freetier get-free-tier-usage --region "$BILLING_REGION" --output json; then
  usage_rows="$(printf '%s' "$RO_OUT" | jq -r '.freeTierUsages | length')"
  over_limit="$(printf '%s' "$RO_OUT" |
    jq -r '[.freeTierUsages[] | select((.actualUsageAmount // 0) > (.limit // 0))] | length')"
  if [ "$over_limit" -gt 0 ]; then
    check WARN "free tier usage" "$usage_rows offers tracked, $over_limit already over their limit — that usage is billed"
  else
    check PASS "free tier usage" "$usage_rows offers tracked, none over limit"
  fi
else
  check WARN "free tier usage" "$(short "$RO_ERR")"
fi

# ------------------------------------------------------------------ verdict

if check_summary "guard-status"; then
  printf '\n%sGUARDRAILS GREEN.%s A cloud window may be opened with an approval message.\n' \
    "$C_GREEN" "$C_RESET" >&2
  exit 0
fi

printf '\n%sGUARDRAILS NOT GREEN. The window does not open.%s\n' "$C_RED" "$C_RESET" >&2
printf 'Rule 2a of the workspace rules. Fix every FAIL above, then run this again. Do not\n' >&2
printf 'open a window on a partial guardrail, and do not weaken a check to make it pass.\n' >&2
exit 1
