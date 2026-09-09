#!/usr/bin/env bash
# mise run lint
#
# Every local check the workspace rules ask for, in one place, with no cloud credentials.
#
# It runs all of them. A linter that stops at the first failure turns a ten-minute
# fix into ten one-minute fixes with a build in between each, so every step here runs
# whatever the previous one did, output is kept, and the exit status at the end says
# whether anything failed.
#
# Nothing in this script talks to AWS. `terraform init -backend=false` reaches the
# public registry and needs no credentials; that is the only network access.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# tflint defaults to ~/.tflint.d, which is outside the workspace. mise.toml redirects
# it into the repository; this line is what makes the script work when it is invoked
# directly rather than through mise.
export TFLINT_PLUGIN_DIR="${TFLINT_PLUGIN_DIR:-$REPO_ROOT/.tflint.d/plugins}"

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-eks-lint.XXXXXX")"
trap 'rm -rf "$LOG_DIR"' EXIT

FAILED_STEPS=()

# step <name> <command...> — run it, keep the output, report, carry on.
step() {
  local name="$1"
  shift
  local slug log
  slug="$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '-')"
  log="$LOG_DIR/$slug.log"

  if "$@" >"$log" 2>&1; then
    check PASS "$name" ""
    return 0
  fi

  check FAIL "$name" "output below"
  FAILED_STEPS+=("$name")
  printf '%s--- %s ---%s\n' "$C_DIM" "$name" "$C_RESET" >&2
  sed 's/^/    /' "$log" >&2
  printf '\n' >&2
  return 0
}

skip() { check SKIP "$1" "$2"; }

# terraform_stacks — every directory holding .tf files, .terraform caches excluded.
terraform_stacks() {
  find "$REPO_ROOT/infra" -name '*.tf' -not -path '*/.terraform/*' -print0 2>/dev/null |
    xargs -0 -n1 dirname 2>/dev/null | sort -u
}

heading "lint — $(date -u '+%Y-%m-%d %H:%M:%SZ')"

require_cmd terraform

# ------------------------------------------------------------------ terraform

heading "terraform"

step "terraform fmt" terraform fmt -check -recursive "$REPO_ROOT"

STACKS="$(terraform_stacks)"
if [ -z "$STACKS" ]; then
  skip "terraform validate" "no .tf files under infra/ yet"
else
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    rel="${dir#"$REPO_ROOT"/}"
    # -backend=false is what lets validate run with no bucket and no credentials.
    step "terraform init  $rel" terraform -chdir="$dir" init -backend=false -input=false
    step "terraform validate  $rel" terraform -chdir="$dir" validate
  done <<<"$STACKS"
fi

# ------------------------------------------------------------------ tflint

heading "tflint"

if ! command -v tflint >/dev/null 2>&1; then
  skip "tflint" "not on PATH; run through mise"
elif [ ! -d "$TFLINT_PLUGIN_DIR" ]; then
  skip "tflint" "no plugin directory at $TFLINT_PLUGIN_DIR. The AWS ruleset is installed once, out of band; do not run 'tflint --init' from here."
else
  step "tflint" tflint --recursive --config "$REPO_ROOT/.tflint.hcl" --chdir "$REPO_ROOT"
fi

# ------------------------------------------------------------------ trivy

heading "trivy"

if ! command -v trivy >/dev/null 2>&1; then
  skip "trivy config" "not on PATH; run through mise"
elif [ -z "$STACKS" ]; then
  skip "trivy config" "no .tf files under infra/ yet"
else
  # One invocation per stack, with the stack as the working directory, so that a
  # .trivyignore sitting next to the configuration is the one that applies. A single
  # run from the repository root would silently ignore all of them.
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    rel="${dir#"$REPO_ROOT"/}"

    # .terraform holds downloaded modules, and their examples are full of
    # deliberately insecure demonstration manifests. They are not this project's
    # code and a finding in one is not this project's finding.
    trivy_args=(config --exit-code 1 --skip-dirs .terraform)

    # A stack nested inside another — platform inside cluster — is scanned on its
    # own pass, with its own .trivyignore. Scanning it twice means the outer stack's
    # ignore file has to cover the inner stack's accepted findings, which is how an
    # acceptance ends up written down in the wrong place.
    while IFS= read -r other; do
      case "$other" in
        "$dir"/*) trivy_args+=(--skip-dirs "${other#"$dir"/}") ;;
      esac
    done <<<"$STACKS"

    step "trivy config  $rel" env -C "$dir" trivy "${trivy_args[@]}" .
  done <<<"$STACKS"
fi

# ------------------------------------------------------------------ helm

heading "helm"

CHART_DIR="$REPO_ROOT/infra/cluster/platform/charts"
CHARTS=""
if [ -d "$CHART_DIR" ]; then
  CHARTS="$(find "$CHART_DIR" -maxdepth 2 -name Chart.yaml -print0 2>/dev/null |
    xargs -0 -n1 dirname 2>/dev/null | sort -u)"
fi

# kubeconform schema locations.
#
# The platform charts render Karpenter, KEDA, External Secrets and Prometheus custom
# resources, and kubeconform has no schema for a CRD it has never seen. It needs
# -schema-location flags pointing at the JSON schemas for those CRDs, and the
# authoritative list of them belongs to whoever wrote the charts, so it is read from
# their module rather than written down here:
#
#     infra/cluster/platform/kubeconform-schemas.txt
#
# one -schema-location value per line, blank lines and #-comments ignored. Order is
# significant and belongs to that file: kubeconform tries each location in turn and
# the first one that returns a schema wins, so a miss falls through instead of
# failing. KUBECONFORM_SCHEMA_LOCATIONS overrides the file as a space-separated list
# of the same, which is what makes this testable without editing the platform module.
#
# The fallback, when neither exists, is -ignore-missing-schemas: the built-in
# Kubernetes objects are validated and every custom resource is silently skipped.
# That is a partial check, and it warns loudly every time it runs, because a partial
# check that looks like a full one is worse than no check. Lint does not fail merely
# because the file is missing — it degrades and says so.
#
# Checked with the file present: every resource the three charts render validates and
# kubeconform reports Skipped 0, and an unknown field injected under an EC2NodeClass
# spec is rejected by -strict against the catalogue schema. Skipped 0 is the number
# that matters; it is what -ignore-missing-schemas could never produce.
kubeconform_args() {
  local -a args=(-strict -summary -output text)
  local schema_file="$REPO_ROOT/infra/cluster/platform/kubeconform-schemas.txt"

  # The cluster's Kubernetes version, read from the stack rather than repeated here.
  local k8s_version
  k8s_version="$(sed -n 's/.*default *= *"\(1\.[0-9][0-9]*\)".*/\1/p' \
    "$REPO_ROOT/infra/cluster/variables.tf" 2>/dev/null | head -n 1)"
  [ -n "$k8s_version" ] && args+=(-kubernetes-version "${k8s_version}.0")

  local -a locations=()
  if [ -n "${KUBECONFORM_SCHEMA_LOCATIONS:-}" ]; then
    read -r -a locations <<<"$KUBECONFORM_SCHEMA_LOCATIONS"
  elif [ -f "$schema_file" ]; then
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue ;; esac
      locations+=("$line")
    done <"$schema_file"
  fi

  if [ "${#locations[@]}" -gt 0 ]; then
    local loc has_default=0
    for loc in "${locations[@]}"; do
      args+=(-schema-location "$loc")
      [ "$loc" = "default" ] && has_default=1
    done
    # Core objects have to resolve alongside the CRD schemas. The file is expected to
    # list `default` itself, and where it does, repeating the flag here would only put
    # the same location in the chain twice.
    if [ "$has_default" -eq 0 ]; then
      args+=(-schema-location default)
    fi
  else
    args+=(-ignore-missing-schemas)
  fi

  printf '%s\n' "${args[@]}"
}

if [ -z "$CHARTS" ]; then
  skip "helm lint" "no charts under infra/cluster/platform/charts yet"
  skip "kubeconform" "no charts to render"
elif ! command -v helm >/dev/null 2>&1; then
  skip "helm lint" "helm not on PATH; run through mise"
else
  mapfile -t KUBECONFORM_ARGS < <(kubeconform_args)
  if printf '%s\n' "${KUBECONFORM_ARGS[@]}" | grep -Fxq -- '-ignore-missing-schemas'; then
    warn "kubeconform is running with -ignore-missing-schemas: no CRD schema locations are"
    warn "wired in, so every custom resource in the charts is being skipped rather than"
    warn "validated. The locations come from infra/cluster/platform/kubeconform-schemas.txt;"
    warn "this fallback means that file is missing and KUBECONFORM_SCHEMA_LOCATIONS is unset."
  fi

  while IFS= read -r chart; do
    [ -n "$chart" ] || continue
    rel="${chart#"$REPO_ROOT"/}"
    step "helm lint  $rel" helm lint "$chart"

    if command -v kubeconform >/dev/null 2>&1; then
      rendered="$LOG_DIR/$(basename "$chart").yaml"
      if helm template "$(basename "$chart")" "$chart" >"$rendered" 2>"$LOG_DIR/template.err"; then
        step "kubeconform  $rel" kubeconform "${KUBECONFORM_ARGS[@]}" "$rendered"
      else
        check FAIL "helm template  $rel" "see below"
        FAILED_STEPS+=("helm template $rel")
        sed 's/^/    /' "$LOG_DIR/template.err" >&2
      fi
    else
      skip "kubeconform  $rel" "kubeconform not on PATH; run through mise"
    fi
  done <<<"$CHARTS"
fi

# ------------------------------------------------------------------ shell

heading "shell"

mapfile -t SHELL_FILES < <(find "$REPO_ROOT/scripts" "$REPO_ROOT/test" "$REPO_ROOT/bench" \
  -name '*.sh' -type f 2>/dev/null | sort)

if [ "${#SHELL_FILES[@]}" -eq 0 ]; then
  skip "shellcheck" "no shell scripts found"
else
  # -x so that the shared library is followed rather than reported as unfollowable.
  step "shellcheck" shellcheck -x "${SHELL_FILES[@]}"
fi

# ------------------------------------------------------------------ markdown

heading "markdown"

if command -v markdownlint-cli2 >/dev/null 2>&1; then
  # The globs are given here rather than left to the config file, because a
  # vendored Terraform module's README is not this project's prose and its line
  # lengths are not this project's problem.
  step "markdownlint" env -C "$REPO_ROOT" markdownlint-cli2 \
    '**/*.md' '!**/.terraform/**' '!**/node_modules/**' '!.tflint.d/**' \
    '!.pre-commit-cache/**'
else
  skip "markdownlint" "markdownlint-cli2 not on PATH; run through mise"
fi

# ------------------------------------------------------------------ workflows

heading "workflows"

if [ ! -d "$REPO_ROOT/.github/workflows" ]; then
  skip "actionlint" "no .github/workflows yet"
elif ! command -v actionlint >/dev/null 2>&1; then
  skip "actionlint" "actionlint not on PATH; run through mise"
else
  step "actionlint" env -C "$REPO_ROOT" actionlint
fi

# ------------------------------------------------------------------ secrets

heading "secrets"

if command -v gitleaks >/dev/null 2>&1; then
  # `gitleaks dir <path>` is the documented command for scanning a working tree at the
  # pinned 8.30.1, and it is what `detect --no-git -s <path>` became. `detect` still
  # resolves, as a hidden compatibility alias upstream intends to drop at v9, which is
  # not something to build on in a repository whose whole point is that versions do not
  # move underneath it. .github/workflows/ci.yml uses the same form.
  #
  # A working-tree scan rather than a history scan, which is what a pre-commit check
  # wants: it sees untracked and unstaged files too. --redact so a finding does not
  # itself become the leak.
  #
  # gitleaks has no path-exclusion flag, so the exclusions live in a config file. A
  # .gitleaks.toml at the repository root wins if one exists; otherwise the one in
  # scripts/ is used, which allowlists the vendored Terraform modules under
  # .terraform/ — their example manifests carry demonstration credentials that are
  # neither ours nor secret. The allowlist applies under `dir` exactly as it did under
  # `detect`; checked against a scratch tree with a planted token inside and outside
  # .terraform/, where one finding was reported and the vendored copy was not.
  gitleaks_config="$REPO_ROOT/.gitleaks.toml"
  [ -f "$gitleaks_config" ] || gitleaks_config="$REPO_ROOT/scripts/gitleaks.toml"
  step "gitleaks" gitleaks dir --no-banner --redact --config "$gitleaks_config" "$REPO_ROOT"
else
  skip "gitleaks" "gitleaks not on PATH; run through mise"
fi

# ------------------------------------------------------------------ python

heading "python"

LAMBDA_DIR="$REPO_ROOT/infra/guardrails/lambda"
if [ ! -d "$LAMBDA_DIR" ]; then
  skip "kill Lambda tests" "no $LAMBDA_DIR yet"
elif ! command -v python3 >/dev/null 2>&1; then
  skip "kill Lambda tests" "python3 not on PATH"
else
  step "kill Lambda tests" env -C "$LAMBDA_DIR" python3 -m unittest discover -v
fi

# ------------------------------------------------------------------ house rules
#
# Things this repository gets wrong easily and that no off-the-shelf linter checks.
# Each is cheap and each has already cost time once.

heading "house rules"

# Rule 3 of the workspace rules: the author writes in their own voice, and nothing
# anywhere in the repository says otherwise.
#
# Each alternative below wraps its first letter in a one-character class. The regex
# still matches the words; the pattern written here does not match itself, so this
# line is not eternally its own first finding. Same trick as `grep [s]shd`.
# shellcheck disable=SC2329  # invoked indirectly, by name, through step()
rule3() {
  ! grep -rniE '[c]laude|[a]nthropic|ai-[g]enerated|ai-[a]ssisted' "$REPO_ROOT" \
    --exclude-dir=.git --exclude-dir=.terraform --exclude-dir=.tflint.d \
    --exclude-dir=.pre-commit-cache \
    --exclude-dir=node_modules --exclude='*.log'
}
step "authorship (Rule 3)" rule3

# Phase 0: the L- quota codes are undocumented and must be discovered at run time
# with list-aws-default-service-quotas. One hardcoded here is a check that silently
# stops checking the day AWS renumbers it. ADR 0054.
# shellcheck disable=SC2329  # invoked indirectly, by name, through step()
no_quota_codes() {
  ! grep -rnE '"L-[0-9A-F]{8}"|\bL-[0-9A-F]{8}\b' \
    "$REPO_ROOT/scripts" "$REPO_ROOT/infra" \
    --exclude-dir=.terraform --include='*.sh' --include='*.tf' --include='*.json'
}
step "no hardcoded quota codes" no_quota_codes

# Rule 2a of the workspace rules: the admin profile is used in window 0 and in the
# final teardown step, and nowhere else.
#
# The first version of this check grepped for the literal string llm-eks-admin under
# scripts/. No script contains it — common.sh derives the name as
# "${NAME_PREFIX}-admin" and everything else refers to $ADMIN_ROLE_NAME — so the
# check matched only its own source and passed vacuously, which is worse than not
# having it. What it now looks for is the thing Rule 2a actually forbids: choosing a
# profile at all. Every script inherits AWS_PROFILE from mise.toml, so a --profile
# flag anywhere outside auth.sh is a script picking its own identity, and auth.sh is
# the one whose entire job is to check a named profile. Naming the admin role in a
# comparison or in an ARN is not the offence and is not flagged; assigning it to
# AWS_PROFILE is.
# shellcheck disable=SC2329  # invoked indirectly, by name, through step()
admin_profile_confined() {
  local rc=0 hits

  # A --profile flag outside auth.sh. This is the arm that catches a new script
  # running aws --profile "$ADMIN_ROLE_NAME"; the old literal grep could not.
  hits="$(grep -rn --include='*.sh' -e '--profile' "$REPO_ROOT/scripts" |
    grep -vE '/(auth|lint)\.sh:' || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed 's/^/    a --profile flag outside auth.sh: /'
    rc=1
  fi

  # Pointing AWS_PROFILE at the admin role, by variable or by name.
  hits="$(grep -rnE 'AWS_PROFILE=[\"'"'"']?(\$\{?ADMIN_ROLE_NAME|llm-eks-admin)' \
    "$REPO_ROOT/scripts" --include='*.sh' | grep -vE '/lint\.sh:' || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed 's/^/    AWS_PROFILE set to the admin role: /'
    rc=1
  fi

  # The literal name, which would mean a profile written down rather than derived.
  hits="$(grep -rn 'llm-eks-admin' "$REPO_ROOT/scripts" --include='*.sh' |
    grep -vE '/lint\.sh:' || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed 's/^/    admin profile named literally: /'
    rc=1
  fi

  return "$rc"
}
step "admin profile confined (Rule 2a)" admin_profile_confined

# guard-drill.sh declares every condition key the operator's boundary and permissions
# policy read, so that a simulator case which leaves one unresolved can name the
# statement responsible instead of printing a bare key. That declaration is a copy of
# something that lives in infra/guardrails/iam_operator.tf, and a copy goes stale: the
# boundary has already gained a statement and an action since the list was first
# derived. So the derivation is re-run here, on every lint, and a key the drill has
# never heard of fails locally — rather than inside window 0, as a case that fails for
# the wrong reason with a timer counting down.
#
# aws_iam_policy_document spells a condition key as `condition { variable = ... }` and
# `variable` appears nowhere else in that file, which is what makes a grep sufficient.
BOUNDARY_TF="$REPO_ROOT/infra/guardrails/iam_operator.tf"
# shellcheck disable=SC2329  # invoked indirectly, by name, through step()
boundary_context_keys_declared() {
  local in_tf declared missing="" key

  in_tf="$(grep -oE 'variable[[:space:]]*=[[:space:]]*"[^"]+"' "$BOUNDARY_TF" |
    sed 's/.*"\(.*\)"/\1/' | sort -u)"
  declared="$(grep -oE '^[[:space:]]*\["[^"]+"\]=' "$REPO_ROOT/scripts/guard-drill.sh" |
    sed 's/.*\["\(.*\)"\]=/\1/' | sort -u)"

  if [ -z "$in_tf" ]; then
    printf 'no condition keys found in %s. Either the boundary has no conditions left,\n' "$BOUNDARY_TF"
    printf 'which would be a much larger problem, or this derivation has stopped working.\n'
    return 1
  fi

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '%s\n' "$declared" | grep -Fxq "$key" || missing="${missing:+$missing }$key"
  done <<<"$in_tf"

  if [ -n "$missing" ]; then
    printf 'condition keys read by infra/guardrails/iam_operator.tf that\n'
    printf 'BOUNDARY_CONTEXT_KEYS in scripts/guard-drill.sh does not declare: %s\n' "$missing"
    printf '\n'
    printf 'Add each one there with the statement sid that reads it, and give every\n'
    printf 'simulator case whose action that statement matches a ContextKeyName entry\n'
    printf 'for it. A case that leaves the key unresolved tests nothing.\n'
    return 1
  fi
  return 0
}

if [ ! -f "$BOUNDARY_TF" ]; then
  skip "drill declares the boundary context keys" "no $BOUNDARY_TF yet"
else
  step "drill declares the boundary context keys" boundary_context_keys_declared
fi

# Rule 1 of the workspace rules: nothing this repository runs writes outside the
# workspace, and the two exceptions are mise's own data directory and Docker images and
# containers. The tools that break this are the ones with a home-directory default:
# tflint writes plugins to ~/.tflint.d (redirected in mise.toml), and kind writes a
# cluster, a context and a client certificate to ~/.kube/config. The kind one shipped
# undetected until a review found it, which is the argument for a check rather than a
# convention.
#
# The rule is narrow on purpose: a script that runs kind or kubectl must set KUBECONFIG
# itself, in its own file, before it runs them. Inheriting one from the author's shell
# is the failure being prevented, so an inherited value does not count.
# shellcheck disable=SC2329  # invoked indirectly, by name, through step()
kubeconfig_redirected() {
  local rc=0 file rel
  for file in "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/test/*.sh; do
    [ -f "$file" ] || continue
    rel="${file#"$REPO_ROOT"/}"
    # test/suite.sh is the deliberate exception and says so in its own header: it
    # creates no cluster, it only reads the current context, and being pointable at a
    # cluster the reader already has is the reason it exists as a separate file.
    [ "$rel" = "test/suite.sh" ] && continue
    # lint.sh names the commands in this comment and must not match on itself.
    [ "$rel" = "scripts/lint.sh" ] && continue

    # Comments are stripped first: "the kind of pressure" is prose, and a house rule
    # that fires on English is a house rule people learn to ignore. What is left has to
    # look like a command in command position, which is the only thing that can write a
    # kubeconfig.
    grep -vE '^[[:space:]]*#' "$file" |
      grep -qE '(^|[;&|(]|\$\()[[:space:]]*(kind|kubectl)[[:space:]]' || continue
    grep -qE '^[[:space:]]*export[[:space:]]+KUBECONFIG=' "$file" && continue

    printf '    %s runs kind or kubectl and never exports KUBECONFIG, so it writes
' "$rel"
    printf '    to the kubeconfig in the home directory. Export a workspace-local one
    before the first kind or kubectl call, the way scripts/test.sh does.
'
    rc=1
  done
  return "$rc"
}
step "kubeconfig stays in the workspace (Rule 1)" kubeconfig_redirected

# Rule 2c of the workspace rules: gitleaks runs as a pre-commit hook in this
# repository. It runs there only if the hook is installed, and installing it is a
# separate act from writing .pre-commit-config.yaml. The config describes what the
# hook should do; .git/hooks is where it does it, and nothing in a checkout puts it
# there. A review found this repository carrying a fully specified config next to a
# .git/hooks holding nothing but the sample files git ships, which means every commit
# made so far was scanned by nothing at all. That is a worse position than having no
# hook configured, because the config reads like a control and is not one.
#
# This check reads files. It runs no git command, and it does not install anything:
# lint's job is to say what is wrong, and installing a commit hook is a change to how
# the author's own working copy behaves.
#
# Skipped rather than failed under CI. There are no local commits there, the hook
# guards a working tree, and the same gitleaks scan runs as its own step above.
# shellcheck disable=SC2329  # invoked indirectly, by name, through step()
pre_commit_hook_installed() {
  local hook="$REPO_ROOT/.git/hooks/pre-commit"
  local fix="    mise exec -- pre-commit install"

  # A redirected hooks path would make the file below dead, and a check that passed on
  # a file git never executes is exactly the failure this rule exists to catch.
  if [ -f "$REPO_ROOT/.git/config" ] &&
     grep -qE '^[[:space:]]*hooksPath[[:space:]]*=' "$REPO_ROOT/.git/config"; then
    printf '.git/config sets core.hooksPath, so git does not look in .git/hooks at all.\n'
    printf 'Whatever is in there is dead. Point the hooks path back at .git/hooks, or\n'
    printf 'install pre-commit into the path it does use.\n'
    return 1
  fi

  if [ ! -f "$hook" ]; then
    printf 'there is no .git/hooks/pre-commit.\n\n'
    printf '.pre-commit-config.yaml describes the hook; it does not install it. Until it is\n'
    printf 'installed, gitleaks sees nothing at commit time and the first secret that reaches\n'
    printf 'a working tree reaches the public repository with it. Install it:\n\n'
    printf '%s\n' "$fix"
    return 1
  fi

  if [ ! -x "$hook" ]; then
    printf '.git/hooks/pre-commit exists and is not executable, so git skips it silently.\n\n'
    printf '%s\n' "$fix"
    return 1
  fi

  # The generated hook execs pre-commit; anything else in that file is somebody's own
  # script and does not run the config above.
  if ! grep -q 'pre-commit' "$hook"; then
    printf '.git/hooks/pre-commit exists but never mentions pre-commit, so it is not the hook\n'
    printf '.pre-commit-config.yaml describes and gitleaks is not what runs at commit time.\n'
    printf 'Read it, then replace it:\n\n'
    printf '%s\n' "$fix"
    return 1
  fi

  return 0
}

if [ -n "${CI:-}" ]; then
  skip "pre-commit hook installed (Rule 2c)" "CI makes no local commits; gitleaks runs as its own step above"
elif [ ! -d "$REPO_ROOT/.git/hooks" ]; then
  skip "pre-commit hook installed (Rule 2c)" "no .git/hooks directory here, so there is nothing to install into"
else
  step "pre-commit hook installed (Rule 2c)" pre_commit_hook_installed
fi

# ------------------------------------------------------------------ verdict

if check_summary "lint"; then
  printf '\n%sLINT CLEAN.%s\n' "$C_GREEN" "$C_RESET" >&2
  exit 0
fi

printf '\n%sLINT FAILED:%s %s\n' "$C_RED" "$C_RESET" "$(printf '%s; ' "${FAILED_STEPS[@]}")" >&2
exit 1
