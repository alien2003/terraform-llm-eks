#!/usr/bin/env bash
# mise run auth <admin|operator>
#
# Pre-flight only. It calls sts:GetCallerIdentity, prints the assumed-role ARN and
# says nothing else. It creates nothing, and it never touches a credential: role
# assumption is the CLI's job, driven by the profile named on the command line.
# Rule 2c of the workspace rules.
#
# The point of the script is the failure messages. "Unable to locate credentials" is
# the same sentence whether the profile block is commented out, the role was never
# created, or the trust policy does not admit the base user, and those are three very
# different problems with three different fixes.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: mise run auth <admin|operator>

  operator  the only identity for cloud work outside window 0 and the final
            teardown step. This is what you want.
  admin     valid only in cloud window 0 and in the very last step of the final
            window. Its profile block should be commented out at every other
            moment.
USAGE
}

# ADR 0050: mise exports a task's declared argument as one shell-quoted string in
# usage_<argname>, not as positionals. Re-expand it only when no real positional was
# given, so direct invocation still works.
if [ "$#" -eq 0 ]; then
  _usage_role="$(mise_usage_arg role)"
  if [ -n "$_usage_role" ]; then
    eval "set -- $_usage_role"
  fi
fi

if [ "$#" -ne 1 ]; then
  usage
  die "expected exactly one role name, got $#."
fi

role="$1"

case "$role" in
  operator) profile="$OPERATOR_ROLE_NAME"; role_name="$OPERATOR_ROLE_NAME" ;;
  admin)    profile="$ADMIN_ROLE_NAME";    role_name="$ADMIN_ROLE_NAME" ;;
  *)
    usage
    die "unknown role '$role'. Only 'admin' and 'operator' exist in this project; there is no third identity to check."
    ;;
esac

require_cmd aws

# The CLI reads its own configuration; this script never opens it (workspace rules, Rule 1).
# `aws configure list-profiles` returns profile names only, no credential material,
# and it is what separates "the block is commented out" from "the role is missing".
#
# Guard first on the CLI seeing NO profiles at all. That is not a real state of any
# configured machine, and it is what the command sandbox produces: ~/.aws is on its
# read deny list, so `aws configure list-profiles` exits 0 and prints nothing. Without
# this guard the admin branch below reports a correctly-uncommented profile as absent
# and calls that "the expected state", which is a reassuring lie told at the first
# pre-flight command of a cloud window. Zero profiles is distinguishable and
# impossible, so checking it is free.
all_profiles="$(command aws configure list-profiles 2>/dev/null || true)"
if [ -z "$all_profiles" ]; then
  die "the AWS CLI can see no profiles at all, which means it cannot read its own configuration rather than that no profile exists. On this machine that is the command sandbox: ~/.aws is not readable inside it. Re-run this with the sandbox disabled. Nothing about the profile blocks has been established either way."
fi

profile_known=0
if printf '%s\n' "$all_profiles" | grep -Fxq -- "$profile"; then
  profile_known=1
fi

if [ "$profile_known" -eq 0 ]; then
  if [ "$role" = "admin" ]; then
    cat >&2 <<EOF
$(printf '%s' "${C_YELLOW}")The '$profile' profile is not configured.${C_RESET}

That is the expected state. Rule 2a of the workspace rules: the admin profile block exists in the
CLI configuration only during cloud window 0 and during the very last step of the
final window. If you are not in one of those two moments, nothing is wrong and there
is nothing to fix.

If you are opening window 0, or destroying the guardrails at the end of the project,
ask the human to uncomment the '$profile' block and run this again. Ask them to
comment it out again the moment that step is finished, and confirm it with:

    mise run auth admin      # must fail again afterwards
EOF
    exit 1
  fi
  die "the '$profile' profile is not configured. mise.toml sets AWS_PROFILE=$OPERATOR_ROLE_NAME and expects a profile of that name that assumes the operator role. Ask the human to add the block from materials/journal/PREFLIGHT.md; do not work around it by exporting credentials."
fi

# Ask. Keep stderr so the failure can be classified rather than guessed at.
stderr_file="$(mktemp "${TMPDIR:-/tmp}/llm-eks-auth.XXXXXX")"
trap 'rm -f "$stderr_file"' EXIT

if identity_json="$(command aws sts get-caller-identity --profile "$profile" --output json 2>"$stderr_file")"; then
  arn="$(printf '%s' "$identity_json" | grep -o '"Arn"[^,]*' | cut -d'"' -f4)"
  account="$(printf '%s' "$identity_json" | grep -o '"Account"[^,]*' | cut -d'"' -f4)"

  printf '%sassumed%s  %s\n' "$C_GREEN" "$C_RESET" "$arn" >&2
  printf 'account  %s\n' "$account" >&2
  printf 'profile  %s\n' "$profile" >&2
  printf 'region   %s\n' "$WORK_REGION" >&2

  case "$arn" in
    *":assumed-role/${role_name}/"*) : ;;
    *)
      die "the '$profile' profile resolved to $arn, which is not the ${role_name} role. Someone has pointed the profile somewhere else; do not proceed until it is fixed."
      ;;
  esac

  if [ "$role" = "admin" ]; then
    cat >&2 <<EOF

${C_YELLOW}Reminder, Rule 2a of the workspace rules.${C_RESET} The administrator is used exactly twice in this
project: to apply the guardrails, request quotas and run the drills in cloud window 0,
and to destroy the guardrails in the last step of the final window. Nothing else.

When the current step is finished, the last thing you do is ask the human to comment
the '$profile' block out again, then confirm with:

    mise run auth admin      # must fail

Never keep it uncommented for convenience.
EOF
  fi
  exit 0
fi

# The call failed. Say which of the three problems it is.
message="$(cat "$stderr_file")"

case "$message" in
  *"could not be found"*|*"The config profile"*)
    error "the '$profile' profile disappeared between the profile listing and the call."
    ;;
  *NoSuchEntity*|*"cannot be found"*|*"does not exist"*)
    error "the profile '$profile' exists but the role it assumes does not."
    log ""
    log "The profile is configured, so the block is uncommented; the role behind it is"
    log "missing. For the operator role that means infra/guardrails has not been applied"
    log "yet: it is what creates ${OPERATOR_ROLE_NAME} and its boundary, and it is applied"
    log "with the admin profile in cloud window 0."
    ;;
  *AccessDenied*|*"not authorized to perform: sts:AssumeRole"*)
    error "the role exists but this caller may not assume it."
    log ""
    log "The trust policy on ${role_name} does not admit the base user ${BASE_USER_NAME},"
    log "or the base key has been disabled. This is an identity problem, not a project"
    log "problem: nothing in repo/ can fix it. See materials/journal/PREFLIGHT.md."
    ;;
  *ExpiredToken*|*InvalidClientTokenId*|*SignatureDoesNotMatch*)
    error "the credentials behind '$profile' are not usable."
    log ""
    log "The base access key has expired, been rotated or been disabled. Exactly one"
    log "static credential exists in this project and the human owns it; ask them to"
    log "check it. Do not create a second one (workspace rules, Rule 2c)."
    ;;
  *"Unable to locate credentials"*)
    error "the '$profile' profile is configured but has no source credentials."
    log ""
    log "The profile assumes a role from the base IAM user's key. If source_profile or"
    log "credential_source is missing from the block, the CLI has nothing to sign with."
    ;;
  *)
    error "sts:GetCallerIdentity failed for profile '$profile' and the reason is not one this script recognises."
    ;;
esac

log ""
log "AWS CLI said:"
printf '%s\n' "$message" | sed 's/^/    /' >&2
exit 1
