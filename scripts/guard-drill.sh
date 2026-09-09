#!/usr/bin/env bash
# mise run guard-drill
#
# The permission boundary drill. Rule 4 of the workspace rules: never ship a boundary
# that has not been drilled. This is what "drilled" means for this project.
#
# Three parts.
#
#   The simulator. `aws iam simulate-principal-policy` for the actions that have no
#   dry-run. Every case passes --resource-arns. Without it every action is simulated
#   against "*" and the answer is useless: it cannot tell "denied for the sweeper
#   schedule" from "denied for every schedule", and it cannot tell "allowed inside
#   the window group" from "allowed everywhere". Several cases below are pairs — the
#   same action against a project ARN and against a non-project ARN — precisely
#   because a single-ARN answer proves nothing about scope. ADR 0053.
#
#   The launch matrix. `aws ec2 run-instances --dry-run` for the launch conditions.
#   The simulator can only be told what ec2:InstanceType and ec2:InstanceMarketType
#   would be; a real request is where they are actually derived from the call, so the
#   matrix is the authority and the simulated launch cases only confirm the wiring.
#   Leaving those keys unset is not a neutral choice: both launch statements in the
#   boundary test them with StringNotEquals, and AWS documents that an inverted
#   operator matches an absent key, so an unset key denies the request for the wrong
#   reason. Every case therefore states its keys explicitly.
#   https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_variables.html
#   EC2 answers DryRunOperation when the caller is permitted and UnauthorizedOperation
#   when it is not, and creates nothing either way.
#
#   The kill path. What the first two parts establish is what the boundary decides.
#   This one asks what is deployed — the kill role's trust policy, its boundary, its
#   attached policies — and then invokes the kill Lambda in report mode, which walks
#   the whole full-stop path and performs none of it. That invocation is the only
#   thing in this repository that proves the kill role can actually see what it would
#   have to stop; a simulation cannot, and neither can a local test.
#
# Every case states the outcome it expects. The script fails if reality differs, in
# either direction: a deny that has become an allow is a hole, and an allow that has
# become a deny is a boundary that will stop the build at the worst moment.
#
# Results are written to materials/guardrails/. That directory is the one place any
# script in this repository writes outside the repository, and it is deliberate:
# Rule 5 of the workspace rules says every number in the documentation traces to a file there, and
# a drill whose output scrolled away proves nothing. Shot w0-07 captures it.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd aws jq

STAMP="$(utc_stamp)"
OUT_DIR="${LLM_EKS_DRILL_DIR:-$MATERIALS_DIR/guardrails}"
TXT_PATH="$OUT_DIR/drill-$STAMP.txt"
JSON_PATH="$OUT_DIR/drill-$STAMP.json"

ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/llm-eks-drill.XXXXXX")"
RESULTS_FILE="$(mktemp "${TMPDIR:-/tmp}/llm-eks-drill-results.XXXXXX")"
INVOKE_FILE="$(mktemp "${TMPDIR:-/tmp}/llm-eks-drill-invoke.XXXXXX")"
trap 'rm -f "$ERR_FILE" "$RESULTS_FILE" "$INVOKE_FILE"' EXIT

heading "guard-drill — $STAMP — region $WORK_REGION"

if ! aws_available; then
  die "no usable AWS credentials. The drill asks the account what the boundary would do; it cannot be run offline. Check with 'mise run auth operator'."
fi

ACCOUNT="$(account_id)"
PARTITION="$(partition)"
CALLER_ARN="$(aws_ro sts get-caller-identity --query Arn --output text)"

OPERATOR_ARN="arn:${PARTITION}:iam::${ACCOUNT}:role/${OPERATOR_ROLE_NAME}"
ADMIN_ARN="arn:${PARTITION}:iam::${ACCOUNT}:role/${ADMIN_ROLE_NAME}"
BASE_USER_ARN="arn:${PARTITION}:iam::${ACCOUNT}:user/${BASE_USER_NAME}"
BOUNDARY_ARN="arn:${PARTITION}:iam::${ACCOUNT}:policy/${OPERATOR_BOUNDARY_NAME}"
KILL_FUNCTION_ARN="arn:${PARTITION}:lambda:${WORK_REGION}:${ACCOUNT}:function:${KILL_FUNCTION_NAME}"
SWEEPER_ARN="arn:${PARTITION}:scheduler:${WORK_REGION}:${ACCOUNT}:schedule/default/${SWEEPER_SCHEDULE_NAME}"
WINDOW_TIMER_ARN="arn:${PARTITION}:scheduler:${WORK_REGION}:${ACCOUNT}:schedule/${WINDOW_GROUP_NAME}/${NAME_PREFIX}-window-drill"
BILLING_ALARM_ARN="arn:${PARTITION}:cloudwatch:${BILLING_REGION}:${ACCOUNT}:alarm:${BILLING_ALARM_NAME}"
KILL_ROLE_NAME="${NAME_PREFIX}-kill"
KILL_ROLE_ARN="arn:${PARTITION}:iam::${ACCOUNT}:role/${KILL_ROLE_NAME}"
INSTANCE_ARN="arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:instance/*"
# An Auto Scaling group ARN carries the group id and then the friendly name:
# arn:${Partition}:autoscaling:${Region}:${Account}:autoScalingGroup:${GroupId}:autoScalingGroupName/${GroupFriendlyName}
# https://docs.aws.amazon.com/service-authorization/latest/reference/list_autoscaling.html
ASG_ARN="arn:${PARTITION}:autoscaling:${WORK_REGION}:${ACCOUNT}:autoScalingGroup:*:autoScalingGroupName/${NAME_PREFIX}-drill"

# The negative cases. Nothing in this project owns any of these, so an allow against
# one means the statement that was meant to be scoped is not scoped.
FOREIGN_SCHEDULE_ARN="arn:${PARTITION}:scheduler:${WORK_REGION}:${ACCOUNT}:schedule/default/not-this-project"
FOREIGN_FUNCTION_ARN="arn:${PARTITION}:lambda:${WORK_REGION}:${ACCOUNT}:function:not-this-project"
FOREIGN_ROLE_ARN="arn:${PARTITION}:iam::${ACCOUNT}:role/not-this-project"

# ------------------------------------------------------------------ context keys
#
# Every condition key the operator's two policy documents read, and the statement that
# reads it. This list is not written from memory and not carried over from an earlier
# version of the boundary: it is re-derived from the file, with
#
#     grep -oE 'variable *= *"[^"]+"' infra/guardrails/iam_operator.tf | sort -u
#
# which is the only place a condition key can appear in either document, because
# aws_iam_policy_document expresses one as `condition { variable = ... }` and nothing
# else in that file uses the name `variable`. Re-derived after the boundary gained the
# NoUnfilterableLaunchPath statement and the eks-auth:AssumeRoleForPodIdentity action:
# neither carries a condition, so neither added to the set. The table below is the set.
#
# What the list is for. simulate-principal-policy answers MissingContextValues with the
# keys a matched statement read and the simulation did not supply, and sim() below
# fails a case that leaves one unresolved, because such a case tested nothing. When
# that happens the drill is being read by someone inside a cloud window with a timer
# counting down, so the message has to name the key, the statement that reads it and
# the flag that supplies it. That is what this table makes possible.
#
# Keeping it honest. scripts/lint.sh re-runs the derivation above on every run and
# fails if this table no longer covers iam_operator.tf, so a condition key added to the
# boundary is caught locally, before window 0, rather than by a case that fails for the
# wrong reason once the account is live.
declare -A BOUNDARY_CONTEXT_KEYS=(
  ["aws:RequestedRegion"]="RegionLock"
  ["aws:RequestTag/Project"]="InstancesMustCarryProjectTag and NoProjectTagRepoint"
  ["aws:TagKeys"]="NoProjectTagRemoval, NoBlanketTagWipe and NoProjectTagRepoint"
  ["ec2:InstanceMarketType"]="GpuSpotOnly"
  ["ec2:InstanceType"]="InstanceTypeWhitelist and GpuSpotOnly"
  ["ec2:VolumeIops"]="NoProvisionedIops"
  ["ec2:VolumeSize"]="VolumeSizeCeiling"
  ["ec2:VolumeType"]="VolumeTypeMustBeGp3"
  ["eks:computeConfigEnabled"]="NoEksAutoModeCompute"
  ["iam:PassedToService"]="PassSchedulerRoleToWindowTimer, and PassSchedulerRole in the permissions policy"
  ["iam:PermissionsBoundary"]="NewRolesMustCarryThisBoundary"
)

# explain_unresolved <comma-separated keys> — say exactly which key was missing, which
# statement reads it, and what to add to the case. One block per key, on stderr, right
# under the FAIL line it belongs to.
explain_unresolved() {
  local key sids
  local -a keys=()
  IFS=',' read -r -a keys <<<"$1"
  for key in ${keys[@]+"${keys[@]}"}; do
    sids="${BOUNDARY_CONTEXT_KEYS[$key]:-}"
    if [ -n "$sids" ]; then
      error "missing context key: $key — read by $sids in infra/guardrails/iam_operator.tf."
    else
      error "missing context key: $key — no statement in infra/guardrails/iam_operator.tf"
      error "  declares it, so either the boundary changed under this drill or another policy on"
      error "  the operator role reads it. Re-derive BOUNDARY_CONTEXT_KEYS in this script and do"
      error "  not trust the verdicts above until the derivation and the file agree."
    fi
    error "  supply it in this case:  \"ContextKeyName=$key,ContextKeyValues=<value>,ContextKeyType=string\""
    error "  or, if its absence is what the case tests:  sim -m $key <expected> <action> <arn>"
  done
}

# ------------------------------------------------------------------ recording

record() { # record <section> <case> <expected> <actual> <verdict> <detail>
  jq -cn --arg section "$1" --arg case "$2" --arg expected "$3" \
         --arg actual "$4" --arg verdict "$5" --arg detail "$6" \
    '{section:$section, case:$case, expected:$expected, actual:$actual, verdict:$verdict, detail:$detail}' \
    >>"$RESULTS_FILE"
}

# ------------------------------------------------------------------ simulator
#
# SimulatePrincipalPolicy evaluates the permissions boundary that is attached to the
# principal, which is the whole point of pointing it at the operator role rather than
# at a policy document.
# https://docs.aws.amazon.com/cli/latest/reference/iam/simulate-principal-policy.html

# sim [-r <region>] [-m <key>[,<key>...]] <expected> <action> <resource-arn> [context-entry ...]
#
# <expected> is one of: allowed, explicitDeny, implicitDeny, denied (either deny).
# A wildcard resource is written as the literal "*" and only for actions whose only
# valid resource is "*"; every other case names a real ARN.
#
#   -r  the region the simulated request is made into. Defaults to $WORK_REGION; the
#       billing alarm lives in $BILLING_REGION and its case says so.
#   -m  condition keys this case leaves unset deliberately, because the absence is
#       what it tests. Any other unresolved key fails the case.
#
# Two things here are easy to get wrong and both make a case look like it tested
# something it did not.
#
#   Context entries go after a single --context-entries flag, space-separated. The
#   AWS CLI parses a list parameter as one option that takes many values, so a
#   repeated flag replaces the previous value instead of appending to it: only the
#   last entry ever reaches the API. Reproduced against aws-cli 2.36.41 — with two
#   flags and a malformed first value the CLI raises no validation error at all,
#   because the malformed value was discarded before parsing.
#   https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-parameters-shorthand.html
#
#   Every case supplies aws:RequestedRegion. The boundary's RegionLock statement is a
#   Deny with StringNotEquals aws:RequestedRegion over everything except the global
#   services, and AWS documents that an inverted operator matches an absent key. A
#   case that leaves the key unset is therefore denied by RegionLock whatever else it
#   is testing: every explicitDeny case would still report PASS with the statement it
#   exists to prove deleted, and the "allowed" cases would fail against a boundary
#   that is working correctly. Supplying an allowed region puts RegionLock out of the
#   way so the verdict belongs to the statement under test.
#   https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_variables.html
#
# MissingContextValues names the keys the policies read and the simulation did not
# supply. Such a key was not tested — the statement that reads it either did not fire
# or fired against a null — so an undeclared one fails the case rather than being
# recorded as commentary. The set of keys either policy can report is fixed and
# derived above in BOUNDARY_CONTEXT_KEYS, which is what lets the failure name the
# statement responsible instead of leaving the reader to grep for it.
sim() {
  local region="$WORK_REGION"
  local -a allow_missing=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -r) region="$2"; shift 2 ;;
      -m) IFS=',' read -r -a allow_missing <<<"$2"; shift 2 ;;
      *)  break ;;
    esac
  done

  # A typo in -m fails the case rather than the drill, which reads as a boundary
  # problem when it is a typing problem. Caught here instead.
  local declared
  for declared in ${allow_missing[@]+"${allow_missing[@]}"}; do
    [ -n "${BOUNDARY_CONTEXT_KEYS[$declared]+set}" ] ||
      die "sim -m names '$declared', which no statement in infra/guardrails/iam_operator.tf reads. Fix the spelling, or add the key to BOUNDARY_CONTEXT_KEYS if the boundary really does read it now."
  done

  local expected="$1" action="$2" resource="$3"
  shift 3

  local case_name="$action on $resource"
  if [ "$#" -gt 0 ]; then
    case_name="$case_name with $*"
  fi

  local entry has_region=0
  for entry in "$@"; do
    case "$entry" in
      ContextKeyName=aws:RequestedRegion,*) has_region=1 ;;
    esac
  done
  if [ "$has_region" -eq 0 ]; then
    set -- "$@" "ContextKeyName=aws:RequestedRegion,ContextKeyValues=$region,ContextKeyType=string"
  fi

  local out decision
  if ! out="$(aws_ro iam simulate-principal-policy \
        --policy-source-arn "$OPERATOR_ARN" \
        --action-names "$action" \
        --resource-arns "$resource" \
        --context-entries "$@" \
        --output json 2>"$ERR_FILE")"; then
    local msg
    msg="$(tr '\n' ' ' <"$ERR_FILE")"
    check FAIL "sim: $action" "call failed: $(printf '%.110s' "$msg")"
    record simulate "$case_name" "$expected" error FAIL "$msg"
    return 0
  fi

  decision="$(printf '%s' "$out" | jq -r '.EvaluationResults[0].EvalDecision')"

  local missing matched
  missing="$(printf '%s' "$out" | jq -r '.EvaluationResults[0].MissingContextValues | join(",")')"
  # SimulatePrincipalPolicy returns the policy a matched statement came from and its
  # line and column, but no Sid, so the policy name is as far as attribution goes
  # here. It is recorded rather than asserted; the region context above is what makes
  # the decision attributable to one statement.
  matched="$(printf '%s' "$out" |
    jq -r '[.EvaluationResults[0].MatchedStatements[]?.SourcePolicyId] | unique | join(",")')"

  local unresolved="" key allowed found
  if [ -n "$missing" ]; then
    local -a missing_list=()
    IFS=',' read -r -a missing_list <<<"$missing"
    for key in ${missing_list[@]+"${missing_list[@]}"}; do
      found=0
      for allowed in ${allow_missing[@]+"${allow_missing[@]}"}; do
        [ "$key" = "$allowed" ] && found=1
      done
      [ "$found" -eq 1 ] || unresolved="${unresolved:+$unresolved,}$key"
    done
  fi

  local ok=0
  case "$expected" in
    allowed)      [ "$decision" = "allowed" ] && ok=1 ;;
    explicitDeny) [ "$decision" = "explicitDeny" ] && ok=1 ;;
    implicitDeny) [ "$decision" = "implicitDeny" ] && ok=1 ;;
    denied)       [ "$decision" != "allowed" ] && ok=1 ;;
    *) die "sim: unknown expectation '$expected'" ;;
  esac

  local detail="expected $expected, got $decision"
  [ -n "$matched" ] && detail="$detail; matched in $matched"
  [ -n "$missing" ] && detail="$detail; unresolved context keys: $missing"
  if [ -n "$unresolved" ]; then
    ok=0
    detail="$detail; missing context key $unresolved, so this case tested nothing"
  fi

  if [ "$ok" -eq 1 ]; then
    check PASS "sim: $action" "$decision — $resource"
    record simulate "$case_name" "$expected" "$decision" PASS "$detail"
  else
    check FAIL "sim: $action" "$detail — $resource"
    record simulate "$case_name" "$expected" "$decision" FAIL "$detail"
    # An `[ -n … ] && …` here would return 1 from sim() when the string is empty, and
    # sim() is called at the top level of a `set -e` script: the drill would abandon
    # its remaining cases on the first ordinary failure. Written as an if for that
    # reason, not for style.
    if [ -n "$unresolved" ]; then
      explain_unresolved "$unresolved"
    fi
  fi
}

heading "1. policy simulator — actions with no dry-run"

note "Every case names a resource ARN. A simulation against \"*\" cannot distinguish a"
note "scoped deny from a blanket one, which is the failure this drill exists to catch."
note "Every case also names the region it is made into and every condition key the"
note "boundary reads, because an unset key that a negated operator matches produces the"
note "right verdict for the wrong reason."

# --- identity creation. Rule 2c: exactly one static credential exists in the project.
sim explicitDeny iam:CreateAccessKey "$BASE_USER_ARN"
sim explicitDeny iam:CreateUser      "arn:${PARTITION}:iam::${ACCOUNT}:user/${NAME_PREFIX}-drill-user"
sim explicitDeny iam:CreateLoginProfile "$BASE_USER_ARN"

# --- the boundary cannot be removed or rewritten by the identity it constrains.
sim explicitDeny iam:PutRolePermissionsBoundary    "$OPERATOR_ARN" \
    "ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=$BOUNDARY_ARN,ContextKeyType=string"
sim explicitDeny iam:DeleteRolePermissionsBoundary "$OPERATOR_ARN"
sim explicitDeny iam:CreatePolicyVersion           "$BOUNDARY_ARN"
sim explicitDeny iam:SetDefaultPolicyVersion       "$BOUNDARY_ARN"
sim explicitDeny iam:DetachRolePolicy              "$OPERATOR_ARN"
sim explicitDeny iam:UpdateAssumeRolePolicy        "$OPERATOR_ARN"

# --- and the operator cannot become the administrator.
sim explicitDeny sts:AssumeRole "$ADMIN_ARN"

# --- a role the operator creates must carry the same boundary, or the whole design
#     is one CreateRole away from an administrator. The pair is the proof: denied
#     without the condition key, allowed with it.
sim -m iam:PermissionsBoundary explicitDeny iam:CreateRole "$FOREIGN_ROLE_ARN"
sim allowed      iam:CreateRole "$FOREIGN_ROLE_ARN" \
    "ContextKeyName=iam:PermissionsBoundary,ContextKeyValues=$BOUNDARY_ARN,ContextKeyType=string"

# --- money controls. Each of these would silently remove a guardrail.
sim explicitDeny budgets:ModifyBudget "arn:${PARTITION}:budgets::${ACCOUNT}:budget/${BUDGET_NAME}"
sim explicitDeny ce:UpdateAnomalyMonitor "*"
sim explicitDeny freetier:UpgradeAccountPlan "*"
sim explicitDeny servicequotas:RequestServiceQuotaIncrease "*"
sim explicitDeny sns:Unsubscribe "*"

# --- anything that expires the Free Tier credits the moment it succeeds.
sim explicitDeny organizations:CreateOrganization "*"
sim explicitDeny controltower:EnableControl "*"
sim explicitDeny sso:CreateInstance "*"
# The read that guard-status depends on must survive all of that.
sim allowed organizations:DescribeOrganization "*"

# --- committed and reserved spend, which bills outside the launch path entirely.
sim explicitDeny ec2:CreateCapacityReservation "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:capacity-reservation/*"
sim explicitDeny ec2:AllocateHosts             "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:dedicated-host/*"
sim explicitDeny savingsplans:CreateSavingsPlan "*"

# --- the safety net itself, and its negative controls. The denies below are scoped
#     to project ARNs, so each is drilled twice: once against the resource it is
#     meant to protect, once against a resource it is not.
sim explicitDeny lambda:UpdateFunctionCode "$KILL_FUNCTION_ARN"
sim implicitDeny lambda:UpdateFunctionCode "$FOREIGN_FUNCTION_ARN"
sim explicitDeny scheduler:DeleteSchedule "$SWEEPER_ARN"
sim -r "$BILLING_REGION" explicitDeny cloudwatch:DeleteAlarms "$BILLING_ALARM_ARN"

# --- the kill role. Protecting the function and leaving its role writable protects
#     nothing: an IAM write against the role is a way to take the terminate
#     permissions away from the only control that can stop compute, without touching
#     the function at all. The role is in the boundary's protected list for that
#     reason, and these are the four verbs that would do it. The pair at the end is
#     the scope proof — the same write against a role this project does not own has
#     to stay possible, because the operator builds the cluster's own roles.
sim explicitDeny iam:PutRolePolicy          "$KILL_ROLE_ARN"
sim explicitDeny iam:AttachRolePolicy       "$KILL_ROLE_ARN"
sim explicitDeny iam:DeleteRole             "$KILL_ROLE_ARN"
sim explicitDeny iam:UpdateAssumeRolePolicy "$KILL_ROLE_ARN"
sim allowed      iam:PutRolePolicy          "$FOREIGN_ROLE_ARN"

# --- invoking the kill Lambda by hand. Only the alert topic and the scheduler
#     execution role may fire it, which is what stops a kill_all arriving in the
#     middle of a measurement from anywhere else. The operator's ceiling grants
#     lambda:Get* and lambda:List* and no invoke, so this is an implicit deny rather
#     than an explicit one, and the drill says which it expects.
sim implicitDeny lambda:InvokeFunction "$KILL_FUNCTION_ARN"

# --- the window timer lifecycle, which is the one thing mise run up and down need.
#     Allowed inside the window group, and nowhere else.
sim allowed      scheduler:CreateSchedule "$WINDOW_TIMER_ARN"
sim allowed      scheduler:DeleteSchedule "$WINDOW_TIMER_ARN"
sim implicitDeny scheduler:CreateSchedule "$FOREIGN_SCHEDULE_ARN"

# --- the launch conditions, as far as the simulator can model them. The launch
#     matrix below is the authority; these cases only confirm that the condition keys
#     are wired to the instance resource type and not to the image or the subnet.
sim explicitDeny ec2:RunInstances "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:instance/*" \
    "ContextKeyName=ec2:InstanceType,ContextKeyValues=p5.48xlarge,ContextKeyType=string" \
    "ContextKeyName=ec2:InstanceMarketType,ContextKeyValues=spot,ContextKeyType=string" \
    "ContextKeyName=aws:RequestTag/Project,ContextKeyValues=$PROJECT_TAG,ContextKeyType=string"
sim explicitDeny ec2:RunInstances "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:instance/*" \
    "ContextKeyName=ec2:InstanceType,ContextKeyValues=g6.xlarge,ContextKeyType=string" \
    "ContextKeyName=ec2:InstanceMarketType,ContextKeyValues=on-demand,ContextKeyType=string" \
    "ContextKeyName=aws:RequestTag/Project,ContextKeyValues=$PROJECT_TAG,ContextKeyType=string"
sim allowed ec2:RunInstances "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:instance/*" \
    "ContextKeyName=ec2:InstanceType,ContextKeyValues=g6.xlarge,ContextKeyType=string" \
    "ContextKeyName=ec2:InstanceMarketType,ContextKeyValues=spot,ContextKeyType=string" \
    "ContextKeyName=aws:RequestTag/Project,ContextKeyValues=$PROJECT_TAG,ContextKeyType=string"

# --- the volume statements. ec2:CreateVolume is the largest dollar-per-API-call in
#     this account: unbounded, it takes a size to 64 TiB and provisioned IOPS to six
#     figures, and a volume is the one hourly resource neither the kill Lambda nor the
#     audit's tag sweep could reach before. Each of the three conditions is drilled
#     against a request that violates it and against one that does not, because a
#     ceiling nobody has pushed against is a ceiling nobody knows the height of.
sim explicitDeny ec2:CreateVolume "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:volume/*" \
    "ContextKeyName=ec2:VolumeType,ContextKeyValues=io2,ContextKeyType=string" \
    "ContextKeyName=ec2:VolumeSize,ContextKeyValues=100,ContextKeyType=numeric" \
    "ContextKeyName=ec2:VolumeIops,ContextKeyValues=3000,ContextKeyType=numeric"
sim explicitDeny ec2:CreateVolume "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:volume/*" \
    "ContextKeyName=ec2:VolumeType,ContextKeyValues=gp3,ContextKeyType=string" \
    "ContextKeyName=ec2:VolumeSize,ContextKeyValues=16384,ContextKeyType=numeric" \
    "ContextKeyName=ec2:VolumeIops,ContextKeyValues=3000,ContextKeyType=numeric"
sim explicitDeny ec2:CreateVolume "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:volume/*" \
    "ContextKeyName=ec2:VolumeType,ContextKeyValues=gp3,ContextKeyType=string" \
    "ContextKeyName=ec2:VolumeSize,ContextKeyValues=100,ContextKeyType=numeric" \
    "ContextKeyName=ec2:VolumeIops,ContextKeyValues=64000,ContextKeyType=numeric"
# The GPU node's own root volume, which has to stay possible: 120 GiB gp3 at the
# baseline IOPS. If this one is denied the cluster cannot start a GPU node at all.
sim allowed ec2:CreateVolume "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:volume/*" \
    "ContextKeyName=ec2:VolumeType,ContextKeyValues=gp3,ContextKeyType=string" \
    "ContextKeyName=ec2:VolumeSize,ContextKeyValues=120,ContextKeyType=numeric" \
    "ContextKeyName=ec2:VolumeIops,ContextKeyValues=3000,ContextKeyType=numeric"

# --- the tag statements. The Project tag is what both the sweeper and mise run audit
#     select on, so removing it from a running instance makes that instance
#     unkillable by anything except the admin profile. Denying the launch of an
#     untagged instance is only half the control; the other half is that the tag
#     cannot be taken off afterwards.
sim explicitDeny ec2:DeleteTags "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:instance/*" \
    "ContextKeyName=aws:TagKeys,ContextKeyValues=Project,ContextKeyType=stringList"
sim explicitDeny ec2:DeleteTags "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:natgateway/*" \
    "ContextKeyName=aws:TagKeys,ContextKeyValues=Project,ContextKeyType=stringList"
# The blanket wipe, which is a different call from the two above and needs its own
# case. ec2:DeleteTags with no Tags parameter removes every user-defined tag on the
# resource; the request then carries no aws:TagKeys at all, the ForAnyValue test in
# NoProjectTagRemoval is false against an absent key, and that statement denies
# nothing. NoBlanketTagWipe is a Null test on aws:TagKeys for exactly this call, so the
# case that proves it is the one that leaves the key unset on purpose — which is what
# -m declares here. Without this case the boundary could lose that statement and the
# drill would still be green.
# https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html
sim -m aws:TagKeys explicitDeny ec2:DeleteTags "$INSTANCE_ARN"
sim -m aws:TagKeys explicitDeny ec2:DeleteTags "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:volume/*"
# And the other direction, because a Null test that matched every DeleteTags would
# stop `mise run down` removing the Window tag and nobody would find out until a
# window was open. Naming a key that is not Project or Stack has to stay possible.
sim allowed ec2:DeleteTags "$INSTANCE_ARN" \
    "ContextKeyName=aws:TagKeys,ContextKeyValues=Window,ContextKeyType=stringList"
sim explicitDeny ec2:CreateTags "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:instance/*" \
    "ContextKeyName=aws:TagKeys,ContextKeyValues=Project,ContextKeyType=stringList" \
    "ContextKeyName=aws:RequestTag/Project,ContextKeyValues=something-else,ContextKeyType=string"
# Tagging that does not touch Project is ordinary work and must stay possible: the
# Window tag is written on every in-window resource.
sim allowed ec2:CreateTags "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:instance/*" \
    "ContextKeyName=aws:TagKeys,ContextKeyValues=Window,ContextKeyType=stringList" \
    "ContextKeyName=aws:RequestTag/Project,ContextKeyValues=$PROJECT_TAG,ContextKeyType=string"

# --- EKS Auto Mode, which reaches running compute through a service principal the
#     instance whitelist never evaluates.
sim explicitDeny eks:CreateCluster "arn:${PARTITION}:eks:${WORK_REGION}:${ACCOUNT}:cluster/auto" \
    "ContextKeyName=eks:computeConfigEnabled,ContextKeyValues=true,ContextKeyType=boolean"
sim allowed eks:CreateCluster "arn:${PARTITION}:eks:${WORK_REGION}:${ACCOUNT}:cluster/${NAME_PREFIX}" \
    "ContextKeyName=eks:computeConfigEnabled,ContextKeyValues=false,ContextKeyType=boolean"

# --- CreateFleet, which is how Karpenter launches and therefore the path that matters
#     most. The type whitelist and the Project tag requirement both name it; the
#     Spot-only rule deliberately does not, because the CreateFleet row of the EC2
#     authorization reference lists no ec2:InstanceMarketType and an unsupported
#     condition key is ignored rather than enforced. See the comment above GpuSpotOnly
#     in infra/guardrails/iam_operator.tf and ADR 0011. So these cases drill what is
#     enforced on that path and make no claim about the market, which is held by the
#     "Running On-Demand G and VT instances" quota at zero instead.
sim explicitDeny ec2:CreateFleet "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:instance/*" \
    "ContextKeyName=ec2:InstanceType,ContextKeyValues=p5.48xlarge,ContextKeyType=string" \
    "ContextKeyName=aws:RequestTag/Project,ContextKeyValues=$PROJECT_TAG,ContextKeyType=string"
sim explicitDeny ec2:CreateFleet "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:instance/*" \
    "ContextKeyName=ec2:InstanceType,ContextKeyValues=g6.xlarge,ContextKeyType=string" \
    "ContextKeyName=aws:RequestTag/Project,ContextKeyValues=not-this-project,ContextKeyType=string"
sim allowed ec2:CreateFleet "arn:${PARTITION}:ec2:${WORK_REGION}:${ACCOUNT}:instance/*" \
    "ContextKeyName=ec2:InstanceType,ContextKeyValues=g6.xlarge,ContextKeyType=string" \
    "ContextKeyName=aws:RequestTag/Project,ContextKeyValues=$PROJECT_TAG,ContextKeyType=string"

# --- the autoscaling narrowing. An Auto Scaling group does not launch instances as
#     the principal that created or resized it: it launches through the service-linked
#     role AWSServiceRoleForAutoScaling, which carries no permission boundary, so
#     InstanceTypeWhitelist, GpuSpotOnly and InstancesMustCarryProjectTag are never
#     evaluated on that path. The narrowing is therefore the absence of a grant:
#     autoscaling:Describe* is inside both the ceiling and the permissions policy and
#     every write is outside them, which makes each of these an IMPLICIT deny. That is
#     the weakest kind of control there is — a single wildcard added to either
#     document removes all four at once and nothing else in this repository would
#     notice — which is the argument for drilling it rather than trusting it.
#     https://docs.aws.amazon.com/service-authorization/latest/reference/list_autoscaling.html
sim implicitDeny autoscaling:CreateAutoScalingGroup "$ASG_ARN"
sim implicitDeny autoscaling:UpdateAutoScalingGroup "$ASG_ARN"
sim implicitDeny autoscaling:SetDesiredCapacity     "$ASG_ARN"
# The read that the cluster stack and `mise run audit` both need. DescribeAutoScalingGroups
# takes no resource type in the authorization reference, so its only valid resource is "*".
sim allowed autoscaling:DescribeAutoScalingGroups "*"

# --- the region lock. A resource in a region nobody looks at is a resource nobody
#     turns off. This is the one case that names a region outside the allowed set,
#     which is why it is also the one case sim does not fill in for.
sim explicitDeny ec2:CreateVpc "arn:${PARTITION}:ec2:eu-west-3:${ACCOUNT}:vpc/*" \
    "ContextKeyName=aws:RequestedRegion,ContextKeyValues=eu-west-3,ContextKeyType=string"

# ------------------------------------------------------------------ launch matrix

heading "2. run-instances --dry-run matrix"

note "EC2 answers DryRunOperation when the caller is permitted and UnauthorizedOperation"
note "when it is not. Nothing is launched in either case."

AMI_ID="${LLM_EKS_DRILL_AMI_ID:-}"
if [ -z "$AMI_ID" ]; then
  # AMI public parameters live under /aws/service/ami-amazon-linux-latest. The leaf
  # names change as Amazon Linux releases change, so the leaf is discovered rather
  # than written down.
  # https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-ami.html
  ami_param="$(aws_ro ssm get-parameters-by-path --path /aws/service/ami-amazon-linux-latest \
      --region "$WORK_REGION" --output json 2>"$ERR_FILE" |
    jq -r '[.Parameters[].Name]
           | map(select(test("x86_64")))
           | (map(select(test("al2023"))) + .)
           | .[0] // empty')" || ami_param=""
  if [ -n "$ami_param" ]; then
    AMI_ID="$(aws_ro ssm get-parameter --name "$ami_param" --region "$WORK_REGION" \
      --query 'Parameter.Value' --output text)"
    note "AMI for the matrix: $AMI_ID (from $ami_param)"
  fi
fi

SUBNET_ID="${LLM_EKS_DRILL_SUBNET_ID:-}"
if [ -z "$SUBNET_ID" ]; then
  SUBNET_ID="$(aws_ro ec2 describe-subnets --region "$WORK_REGION" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
  [ "$SUBNET_ID" = "None" ] && SUBNET_ID=""
fi

# launch <expected> <label> <instance-type> <market: spot|on-demand> <tagged: yes|no>
#
# <expected> is allowed or denied. Anything else EC2 says — a missing subnet, an
# unsupported instance type in this region — is INCONCLUSIVE and fails the drill,
# because a drill that cannot reach a verdict has not verified anything.
launch() {
  local expected="$1" label="$2" instance_type="$3" market="$4" tagged="$5"

  local -a args=(
    ec2 run-instances --dry-run
    --region "$WORK_REGION"
    --image-id "$AMI_ID"
    --instance-type "$instance_type"
    --count 1
  )
  [ -n "$SUBNET_ID" ] && args+=(--subnet-id "$SUBNET_ID")
  [ "$market" = "spot" ] && args+=(--instance-market-options "MarketType=spot")
  if [ "$tagged" = "yes" ]; then
    args+=(--tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$PROJECT_TAG}]")
  fi

  local msg actual verdict
  if aws_dry_run "${args[@]}" >/dev/null 2>"$ERR_FILE"; then
    # A dry run that succeeds outright would mean --dry-run was dropped somewhere.
    actual="no-error"
  else
    msg="$(tr '\n' ' ' <"$ERR_FILE")"
    case "$msg" in
      *DryRunOperation*)        actual="allowed" ;;
      *UnauthorizedOperation*)  actual="denied" ;;
      *AccessDenied*)           actual="denied" ;;
      *)                        actual="inconclusive" ;;
    esac
  fi

  if [ "$actual" = "$expected" ]; then
    verdict=PASS
    check PASS "launch: $label" "$actual as expected"
  elif [ "$actual" = "inconclusive" ] || [ "$actual" = "no-error" ]; then
    verdict=FAIL
    check FAIL "launch: $label" "no verdict — EC2 said: $(printf '%.100s' "${msg:-<nothing>}")"
  else
    verdict=FAIL
    check FAIL "launch: $label" "expected $expected, got $actual"
  fi

  record launch "$label ($instance_type, $market, tagged=$tagged)" "$expected" "$actual" "$verdict" "${msg:-}"
}

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
  check FAIL "launch matrix" "no AMI id. Set LLM_EKS_DRILL_AMI_ID to any image id in $WORK_REGION and run again; the drill does not launch it."
  record launch "matrix prerequisites" "an ami id" "none" FAIL "AMI discovery through SSM public parameters returned nothing"
else
  [ -n "$SUBNET_ID" ] || note "no subnet found; running without --subnet-id. If EC2 answers VPCIdNotSpecified, set LLM_EKS_DRILL_SUBNET_ID."

  # The whitelist, from materials/journal/PHASE1-CONTRACT.md: GPU types Spot only,
  # system types either market, everything else denied.
  launch allowed "GPU on Spot, g6.xlarge"        g6.xlarge   spot      yes
  launch allowed "GPU on Spot, g6.2xlarge"       g6.2xlarge  spot      yes
  launch denied  "GPU on demand, g6.xlarge"      g6.xlarge   on-demand yes
  launch denied  "GPU on demand, g6.2xlarge"     g6.2xlarge  on-demand yes
  launch allowed "system on demand, t3.medium"   t3.medium   on-demand yes
  launch allowed "system on demand, m7i.large"   m7i.large   on-demand yes
  launch allowed "system on Spot, t3.medium"     t3.medium   spot      yes
  launch denied  "not whitelisted, p5.48xlarge"  p5.48xlarge spot      yes
  launch denied  "not whitelisted, m5.24xlarge"  m5.24xlarge on-demand yes
  launch denied  "not whitelisted, x2gd.16xlarge" x2gd.16xlarge spot   yes
  # An untagged instance is invisible to the sweeper and to the audit task, which is
  # a worse failure than a launch that does not happen.
  launch denied  "whitelisted but untagged"      t3.medium   on-demand no
fi

# ------------------------------------------------------------------ the kill path

heading "3. the kill path"

note "The simulator says what the boundary would decide about the kill Lambda. This"
note "section asks the account what is actually deployed, and then runs the thing."

# fact <case> <expected> <actual> <detail> — one assertion about a deployed resource,
# in the same shape sim() and launch() record, so the report file keeps one schema.
fact() {
  local case_name="$1" expected="$2" actual="$3" detail="$4"
  if [ "$expected" = "$actual" ]; then
    check PASS "kill: $case_name" "$actual — $detail"
    record killpath "$case_name" "$expected" "$actual" PASS "$detail"
  else
    check FAIL "kill: $case_name" "expected $expected, got $actual — $detail"
    record killpath "$case_name" "$expected" "$actual" FAIL "$detail"
  fi
}

# --- the role. Everything the kill Lambda can do it does through this role, so the
#     role is as much of the control as the code is. Three facts, each of which would
#     be a way to take the kill path apart without touching the function.
if role_json="$(aws_ro iam get-role --role-name "$KILL_ROLE_NAME" --output json 2>"$ERR_FILE")"; then
  trust_doc="$(maybe_urldecode "$(printf '%s' "$role_json" |
    jq -r '.Role.AssumeRolePolicyDocument | if type == "string" then . else tojson end')")"

  # Who may assume it. A service principal cannot be assumed by a person; an AWS or
  # Federated principal can, and would hand whoever it names the ability to terminate
  # every instance the project owns and delete the cluster.
  trust_services="$(printf '%s' "$trust_doc" |
    jq -r '[.Statement[]? | .Principal.Service? // empty] | flatten | unique | join(",")')"
  trust_others="$(printf '%s' "$trust_doc" |
    jq -r '[.Statement[]? | (.Principal.AWS? // empty), (.Principal.Federated? // empty),
            (.Principal.CanonicalUser? // empty)] | flatten | unique | join(",")')"

  # The suffix is not written down here: it differs by partition, and what the drill
  # cares about is the service, not the DNS name it happens to have.
  case "$trust_services" in
    lambda.*) trust_shape="lambda only" ;;
    "")       trust_shape="no service principal" ;;
    *)        trust_shape="other: $trust_services" ;;
  esac
  [ -z "$trust_others" ] || trust_shape="assumable by $trust_others"
  fact "kill role trusts only Lambda" "lambda only" "$trust_shape" \
    "trust policy of $KILL_ROLE_NAME"

  boundary_on_kill="$(printf '%s' "$role_json" |
    jq -r '.Role.PermissionsBoundary.PermissionsBoundaryArn // "none"')"
  fact "kill role carries no boundary" "none" "$boundary_on_kill" \
    "the guardrails stack attaches none; a boundary here would subtract from the only control that can stop compute"

  if attached="$(aws_ro iam list-attached-role-policies --role-name "$KILL_ROLE_NAME" \
       --query 'AttachedPolicies[].PolicyArn' --output text 2>"$ERR_FILE")"; then
    attached="$(printf '%s' "$attached" | tr '\t' ' ' | sed 's/^ *//; s/ *$//')"
    [ -n "$attached" ] || attached="none"
    fact "kill role has no managed policies" "none" "$attached" \
      "its permissions are one inline policy; an attached managed policy is a widening nobody in this repository wrote"
  else
    fact "kill role has no managed policies" "none" "unreadable" \
      "$(tr '\n' ' ' <"$ERR_FILE" | cut -c1-110)"
  fi
else
  fact "kill role exists" "yes" "no" "$(tr '\n' ' ' <"$ERR_FILE" | cut -c1-110)"
fi

# --- the invocation.
#
# report mode is the handler's third mode: it walks the whole full-stop path, records
# every step it would take, and performs none of them, because the handler sets
# dry_run for the mode and every mutating step is behind that flag. So this is the one
# call that proves the kill role's own permissions are sufficient — that it really can
# describe the instances, the cluster, the node groups, the load balancers, the NAT
# gateways and the window timers it would have to find in an emergency. No simulation
# and no local test can prove that; only running it can.
#
# Who may run it is itself a control, and it decides what this case expects. The alert
# topic and the scheduler execution role are the only principals the function's
# resource policy names, and lambda:InvokeFunction is outside the operator's ceiling,
# so as the operator the call must be refused — an operator that could fire the kill
# path by hand could also fire kill_all in the middle of a measurement. As the
# administrator it must succeed and the report must describe a stop it did not
# perform. Both are expectations; neither is a skip.
case "$CALLER_ARN" in
  *":assumed-role/${OPERATOR_ROLE_NAME}/"*) invoke_expected="denied" ;;
  *":assumed-role/${ADMIN_ROLE_NAME}/"*)    invoke_expected="allowed" ;;
  *)                                        invoke_expected="" ;;
esac

# kill_report_invoke <outfile> — invoke the kill Lambda in report mode.
#
# Neither aws_ro nor aws_write covers this call, and that is deliberate rather than an
# oversight. aws_ro refuses any operation whose name is not obviously read-only and
# `invoke` is not one; aws_write is the gate on a billable change and demands an open
# window, which a drill is not. What report mode is, is a read: the handler calls no
# mutating API in it. The payload is written here rather than taken as an argument, so
# this function cannot be reused to send kill_all. --cli-binary-format is required for
# a raw JSON payload on AWS CLI v2.
# https://docs.aws.amazon.com/lambda/latest/dg/API_Invoke.html
# https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-parameters-file.html
kill_report_invoke() {
  command aws lambda invoke \
    --function-name "$KILL_FUNCTION_NAME" \
    --region "$WORK_REGION" \
    --cli-binary-format raw-in-base64-out \
    --payload '{"mode":"report"}' \
    --output json \
    "$1"
}

if [ -z "$invoke_expected" ]; then
  fact "report-mode invoke" "a known principal" "$CALLER_ARN" \
    "the drill knows what the operator role and the administrator role should be able to do to the kill Lambda and nothing about this principal, so it cannot state an expectation. Run it as one of those two."
else
  : >"$INVOKE_FILE"
  if invoke_meta="$(kill_report_invoke "$INVOKE_FILE" 2>"$ERR_FILE")"; then
    invoke_actual="allowed"
  else
    invoke_msg="$(tr '\n' ' ' <"$ERR_FILE" | sed 's/  */ /g')"
    invoke_meta=""
    case "$invoke_msg" in
      *AccessDenied*|*not\ authorized*) invoke_actual="denied" ;;
      *)                                invoke_actual="inconclusive" ;;
    esac
  fi

  if [ -n "$invoke_meta" ]; then
    invoke_detail="StatusCode $(printf '%s' "$invoke_meta" | jq -r '.StatusCode // "?"')"
  else
    invoke_detail="$(printf '%.110s' "${invoke_msg:-no output}")"
  fi
  fact "report-mode invoke" "$invoke_expected" "$invoke_actual" "$invoke_detail"

  if [ "$invoke_actual" = "allowed" ]; then
    # A handler that raised put the event on the dead-letter queue and lit the error
    # alarm. In report mode there is nothing for it to raise about, so a FunctionError
    # here means the kill path is broken in a way an emergency would discover.
    fn_error="$(printf '%s' "$invoke_meta" | jq -r '.FunctionError // "none"')"
    fact "report-mode invoke did not raise" "none" "$fn_error" \
      "FunctionError from the invocation"

    report_json="$(cat "$INVOKE_FILE")"

    fact "report ran in report mode" "report true" \
      "$(printf '%s' "$report_json" | jq -r '"\(.mode // "?") \(.dry_run | tostring)"')" \
      "the mode and the dry_run flag the handler reported back"

    # `done` holds the mutating calls the handler actually made, and `terminated` the
    # instances it actually terminated. Both are appended only past the dry_run guard,
    # so both being empty is the proof that a report is a report. The other lists in
    # the payload — node_groups_deleted, nat_gateways_deleted and the rest — are what
    # it WOULD have removed and are expected to be populated when there is anything to
    # remove, which is the point of running it.
    fact "report changed nothing" "0 0" \
      "$(printf '%s' "$report_json" | jq -r '"\((.terminated // []) | length) \((.done // []) | length)"')" \
      "instances terminated and mutating calls made, in that order; a report performs neither"

    # Every read the kill role needs, attempted for real. A read it is not permitted
    # to make lands in `failed`, which is the one way to find out before an emergency
    # that the role cannot see what it would have to stop.
    fact "report completed every step" "0" \
      "$(printf '%s' "$report_json" | jq -r '(.failed // []) | length')" \
      "steps the kill role could not complete: $(printf '%s' "$report_json" | jq -r '(.failed // []) | join("; ") | if . == "" then "none" else . end')"
  elif [ "$invoke_actual" = "denied" ]; then
    note "The report itself was not exercised: as the operator the invoke is refused, which is"
    note "the outcome this case expects. What report mode does, and whether the kill role's own"
    note "permissions are sufficient, is proven by running the same call once in window 0 with"
    note "the administrator credentials that apply the guardrails stack:"
    note ""
    note "    aws lambda invoke --function-name $KILL_FUNCTION_NAME --region $WORK_REGION \\"
    note "      --cli-binary-format raw-in-base64-out --payload '{\"mode\":\"report\"}' report.json"
    note ""
    note "Do not run the rest of this drill with those credentials: the launch matrix and every"
    note "deny case below measure the operator, and an administrator passes all of them."
  fi
fi

# ------------------------------------------------------------------ report

mkdir -p "$OUT_DIR"

jq -s --arg stamp "$STAMP" --arg account "$ACCOUNT" --arg region "$WORK_REGION" \
      --arg operator "$OPERATOR_ARN" --arg boundary "$BOUNDARY_ARN" \
  '{drill: $stamp, account: $account, region: $region, principal: $operator,
    boundary: $boundary,
    totals: {cases: length,
             passed: (map(select(.verdict == "PASS")) | length),
             failed: (map(select(.verdict == "FAIL")) | length)},
    cases: .}' \
  "$RESULTS_FILE" >"$JSON_PATH"

{
  printf 'permission boundary drill\n'
  printf 'run      %s\n' "$STAMP"
  printf 'account  %s\n' "$ACCOUNT"
  printf 'region   %s\n' "$WORK_REGION"
  printf 'principal %s\n' "$OPERATOR_ARN"
  printf 'boundary  %s\n' "$BOUNDARY_ARN"
  printf '\n'
  printf '%-8s %-12s %-14s %s\n' VERDICT EXPECTED ACTUAL CASE
  jq -r '[.verdict, .expected, .actual, .case] | @tsv' "$RESULTS_FILE" |
    awk -F'\t' '{printf "%-8s %-12s %-14s %s\n", $1, $2, $3, $4}'
  printf '\n'
  jq -r '.totals | "cases \(.cases), passed \(.passed), failed \(.failed)"' "$JSON_PATH"
} >"$TXT_PATH"

hr
info "wrote $TXT_PATH"
info "wrote $JSON_PATH"

if check_summary "guard-drill"; then
  printf '\n%sDRILL CLEAN.%s Every case matched its expected outcome.\n' "$C_GREEN" "$C_RESET" >&2
  exit 0
fi

printf '\n%sDRILL FAILED.%s At least one case did not behave as the boundary says it should.\n' \
  "$C_RED" "$C_RESET" >&2
printf 'A deny that became an allow is a hole. An allow that became a deny will stop the\n' >&2
printf 'build halfway through a window. Neither is acceptable; fix the boundary in\n' >&2
printf 'infra/guardrails and re-apply it with the admin profile before opening a window.\n' >&2
exit 1
