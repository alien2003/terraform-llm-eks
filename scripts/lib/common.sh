#!/usr/bin/env bash
# Shared helpers for every script behind a `mise run` task.
#
# This file is sourced, never executed. It sets no traps and changes no directory
# so that the sourcing script keeps control of both.
#
# Three things live here that are worth reading before writing a new script:
#
#   1. `mise_usage_arg` — mise does not hand a task's declared arguments to the
#      script as positionals. It exports them as one shell-quoted string in an
#      environment variable named after the argument. See ADR 0050.
#   2. `aws_ro` / `aws_dry_run` / `aws_write` — the LOCAL-mode guard. The workspace
#      rules forbid any call that creates, modifies or deletes a billable resource
#      outside a cloud window, and prose does not enforce that. These wrappers do.
#   3. `check` / `check_summary` — the reporting shape guard-status, audit and
#      lint all share, so that a run continues past the first failure and the
#      author sees the whole picture rather than one line at a time.

# This file is a definition library: almost everything in it is consumed by the
# scripts that source it, so shellcheck's "appears unused" warning is wrong here by
# construction. Nothing else in scripts/ carries this directive.
# shellcheck disable=SC2034

set -euo pipefail

# ---------------------------------------------------------------- presentation

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""
fi
readonly C_RESET C_BOLD C_RED C_GREEN C_YELLOW C_DIM

log()   { printf '%s\n' "$*" >&2; }
info()  { printf '%s\n' "$*" >&2; }
warn()  { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
note()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }

hr()      { printf '%s\n' "------------------------------------------------------------------------" >&2; }
heading() { hr; printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; hr; }

# die <message...> — print and exit 1. Every failure message should say what to do
# next, not only what went wrong.
die() {
  error "$*"
  exit 1
}

# ---------------------------------------------------------------- layout

# repo_root — the directory holding mise.toml. Every path in every script is built
# from this, so a script works from any working directory.
repo_root() {
  local dir="${BASH_SOURCE[0]}"
  dir="$(cd -- "$(dirname -- "$dir")/../.." && pwd)"
  [ -f "$dir/mise.toml" ] || die "cannot find mise.toml above ${BASH_SOURCE[0]}; is this a checkout of terraform-llm-eks?"
  printf '%s' "$dir"
}

REPO_ROOT="$(repo_root)"
readonly REPO_ROOT

# The private working material lives beside the repository, never inside it.
# Only guard-drill.sh writes here, and only under guardrails/. See scripts/README.md.
MATERIALS_DIR="${LLM_EKS_MATERIALS_DIR:-$(cd -- "$REPO_ROOT/.." && pwd)/materials}"
readonly MATERIALS_DIR

# ---------------------------------------------------------------- fixed names
#
# These are the names in materials/journal/PHASE1-CONTRACT.md. They are referenced
# across stacks and scripts, so they are declared once, here.

PROJECT_TAG="${PROJECT_TAG:-terraform-llm-eks}"
NAME_PREFIX="llm-eks"
OPERATOR_ROLE_NAME="${NAME_PREFIX}-operator"
OPERATOR_BOUNDARY_NAME="${NAME_PREFIX}-operator-boundary"
ADMIN_ROLE_NAME="${NAME_PREFIX}-admin"
BASE_USER_NAME="${NAME_PREFIX}-human"
ALERT_TOPIC_NAME="${NAME_PREFIX}-alerts"
BUDGET_NAME="${NAME_PREFIX}-gross-spend"
KILL_FUNCTION_NAME="${NAME_PREFIX}-kill"
SWEEPER_SCHEDULE_NAME="${NAME_PREFIX}-sweeper"
WINDOW_GROUP_NAME="${NAME_PREFIX}-windows"
SCHEDULER_ROLE_NAME="${NAME_PREFIX}-scheduler"
BILLING_ALARM_NAME="${NAME_PREFIX}-estimated-charges"
ANOMALY_MONITOR_NAME="${NAME_PREFIX}-service-monitor"
ANOMALY_SUBSCRIPTION_NAME="${NAME_PREFIX}-anomaly-alerts"
QUOTA_TARGETS_PARAMETER="/${NAME_PREFIX}/guardrails/quota-targets"
readonly PROJECT_TAG NAME_PREFIX OPERATOR_ROLE_NAME OPERATOR_BOUNDARY_NAME
readonly ADMIN_ROLE_NAME BASE_USER_NAME ALERT_TOPIC_NAME BUDGET_NAME
readonly KILL_FUNCTION_NAME SWEEPER_SCHEDULE_NAME WINDOW_GROUP_NAME
readonly SCHEDULER_ROLE_NAME BILLING_ALARM_NAME QUOTA_TARGETS_PARAMETER
readonly ANOMALY_MONITOR_NAME ANOMALY_SUBSCRIPTION_NAME

# Budgets, Cost Explorer, the Free Tier API and the AWS/Billing metric namespace are
# only reachable through us-east-1, whatever the working region is.
# https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/monitor_estimated_charges_with_cloudwatch.html
# https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/Welcome.html
BILLING_REGION="us-east-1"
readonly BILLING_REGION

# The working region. mise.toml sets AWS_REGION; the region is still provisional, so
# nothing below hardcodes it.
WORK_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
readonly WORK_REGION

# ---------------------------------------------------------------- tools

require_cmd() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "required command not found: $cmd"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    die "run this through mise, which pins the toolchain: 'mise exec -- <command>' or 'mise run <task>'."
  fi
}

# ---------------------------------------------------------------- mise arguments
#
# ADR 0050. `mise run up WINDOW_ID=0 WINDOW_HOURS=3` does NOT reach the script as
# positional parameters. mise exports the declared argument as one shell-quoted
# string in an environment variable named `usage_<argname>`, here:
#
#     usage_vars='WINDOW_ID=0' 'WINDOW_HOURS=3'
#
# so the caller re-expands it with `eval "set -- $(mise_usage_arg vars)"`, guarded by
# a check that there are no real positionals. Scripts stay directly invokable, which
# is what makes them testable.
mise_usage_arg() {
  local var="usage_$1"
  printf '%s' "${!var-}"
}

# ---------------------------------------------------------------- AWS call guard
#
# Rule 2b of the workspace rules. In LOCAL mode no AWS API call may create, modify or delete a
# billable resource; read-only calls are allowed once credentials exist. Only
# window-up.sh and window-down.sh may write, and only after their own preconditions
# hold, which they signal by exporting LLM_EKS_WINDOW_WRITE=1.

# aws_ro <service> <operation> [args...] — a read-only AWS call.
# Refuses anything whose operation name is not obviously read-only, so a typo cannot
# turn a status check into a mutation.
aws_ro() {
  local service="${1:-}" operation="${2:-}"
  case "$operation" in
    describe-*|list-*|get-*|lookup-*|head-*|search-*|select-*|simulate-*|batch-get-*|check-*) : ;;
    *) die "aws_ro refuses '$service $operation': not a read-only operation. Use aws_write inside a window, or fix the call." ;;
  esac
  command aws "$@"
}

# aws_dry_run <service> <operation> [args...] — an EC2 call that carries --dry-run.
# EC2 answers DryRunOperation when the caller is permitted and UnauthorizedOperation
# when it is not, and creates nothing either way, which is what the boundary drill
# needs.
# https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-instance-types.html
aws_dry_run() {
  local arg found=0
  for arg in "$@"; do
    [ "$arg" = "--dry-run" ] && found=1
  done
  [ "$found" -eq 1 ] || die "aws_dry_run called without --dry-run; refusing to make a real request."
  command aws "$@"
}

# aws_write <service> <operation> [args...] — a call that may change something.
#
# The gate is one exported environment variable, which window-up.sh and window-down.sh
# set once they have established that a window is open. Being an environment variable,
# what it enforces is that some ancestor process set it, not that this process checked
# anything: a child of either script inherits it, and so does anything started from a
# shell where it was already set. That is the honest description of the control. Those
# two scripts turn it off explicitly across the child scripts they call, and nothing
# else in this repository sets it.
aws_write() {
  [ "${LLM_EKS_WINDOW_WRITE:-0}" = "1" ] || die \
    "aws_write refused: LOCAL mode. A billable change needs an open cloud window (workspace rules, Rule 2b), which only 'mise run up' and 'mise run down' establish."
  command aws "$@"
}

# aws_available — true when the CLI can reach STS with the configured profile.
aws_available() {
  command aws sts get-caller-identity >/dev/null 2>&1
}

# account_id — the account the current credentials belong to, cached per process.
_ACCOUNT_ID=""
account_id() {
  if [ -z "$_ACCOUNT_ID" ]; then
    _ACCOUNT_ID="$(aws_ro sts get-caller-identity --query Account --output text)" ||
      die "cannot read the account id. Check the ${AWS_PROFILE:-default} profile with 'mise run auth operator'."
  fi
  printf '%s' "$_ACCOUNT_ID"
}

# partition — aws, aws-cn or aws-us-gov, derived from the caller ARN rather than
# assumed, so nothing here breaks in a partition this project has not seen.
_PARTITION=""
partition() {
  if [ -z "$_PARTITION" ]; then
    local arn
    arn="$(aws_ro sts get-caller-identity --query Arn --output text)" ||
      die "cannot read the caller ARN. Check the ${AWS_PROFILE:-default} profile with 'mise run auth operator'."
    _PARTITION="$(printf '%s' "$arn" | cut -d: -f2)"
  fi
  printf '%s' "$_PARTITION"
}

# ---------------------------------------------------------------- check reporting
#
# A guard-status or audit run that stops at the first failure tells you one thing.
# One that runs everything and prints a table tells you what state the account is in.

CHECKS_TOTAL=0
CHECKS_FAILED=0
CHECKS_WARNED=0

# check <PASS|FAIL|WARN|SKIP> <name> <detail...>
check() {
  local status="$1" name="$2"
  shift 2
  local detail="$*"
  local colour="$C_GREEN"

  CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
  case "$status" in
    PASS) colour="$C_GREEN" ;;
    WARN) colour="$C_YELLOW"; CHECKS_WARNED=$((CHECKS_WARNED + 1)) ;;
    FAIL) colour="$C_RED";    CHECKS_FAILED=$((CHECKS_FAILED + 1)) ;;
    SKIP) colour="$C_DIM" ;;
    *) die "check: unknown status '$status'" ;;
  esac

  printf '%s%-4s%s  %-38s %s\n' "$colour" "$status" "$C_RESET" "$name" "$detail" >&2
}

# check_summary <subject> — print the tally and return 1 if anything failed.
check_summary() {
  local subject="$1"
  hr
  if [ "$CHECKS_FAILED" -eq 0 ]; then
    printf '%s%s: %d checks, 0 failed, %d warnings%s\n' \
      "$C_GREEN" "$subject" "$CHECKS_TOTAL" "$CHECKS_WARNED" "$C_RESET" >&2
    return 0
  fi
  printf '%s%s: %d checks, %d FAILED, %d warnings%s\n' \
    "$C_RED" "$subject" "$CHECKS_TOTAL" "$CHECKS_FAILED" "$CHECKS_WARNED" "$C_RESET" >&2
  return 1
}

# ---------------------------------------------------------------- misc

# confirm <prompt> — ask the human. The window protocol says a window never outlives
# the human's attention, so a destructive step asks rather than assumes. Set
# LLM_EKS_ASSUME_YES=1 only when the answer has already been given in writing.
confirm() {
  local prompt="$1" reply=""
  if [ "${LLM_EKS_ASSUME_YES:-0}" = "1" ]; then
    note "LLM_EKS_ASSUME_YES=1, taking '$prompt' as yes."
    return 0
  fi
  if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
    die "$prompt — no terminal to ask on. Run this in the main conversation with the human present (workspace rules, Rule 2b), or set LLM_EKS_ASSUME_YES=1 if the answer is already in writing."
  fi
  printf '%s%s%s [y/N] ' "$C_BOLD" "$prompt" "$C_RESET" >&2
  if [ -t 0 ]; then read -r reply; else read -r reply < /dev/tty; fi
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# utc_stamp — a filename-safe UTC timestamp.
utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }

# maybe_urldecode <text> — RFC 3986 percent-decoding, applied only if the text still
# needs it.
#
# IAM documents the policy documents it returns — GetPolicyVersion's Document and
# GetRole's AssumeRolePolicyDocument — as "URL-encoded compliant with RFC 3986". Some
# SDK and CLI versions decode them on the way out and some hand them back encoded, and
# a check that assumed either would break on the other. So the test is on the value: a
# JSON object begins with a brace, and a still-encoded one begins with %7B.
#
# Decoding is safe only because of that test. In a percent-encoded document a literal
# backslash arrives as %5C, so after the substitution the only backslashes in the
# string are the ones this function introduced, and printf %b has nothing else to
# misread. Never call it on text that was not percent-encoded.
# https://docs.aws.amazon.com/cli/latest/reference/iam/get-policy-version.html
maybe_urldecode() {
  local text="$1"
  case "$text" in
    %7B*|%7b*) : ;;
    *) printf '%s' "$text"; return 0 ;;
  esac
  local s="${text//+/ }"
  printf '%b' "${s//%/\\x}"
}
