#!/usr/bin/env bash
# mise run wiki-sync
#
# Publishes repo/docs/ into the wiki clone.
#
# Two things about this script are not obvious.
#
# The branch is master, not main. GitHub wikis are served from master and a wiki
# clone's default branch is master; pushing main creates a branch nobody reads and
# leaves the wiki showing the previous content. Phase 0 recorded this specifically
# after finding it the hard way.
#
# It refuses to publish rather than warning. The checks below are the last gate
# before text becomes public, and a gate that can be walked past by ignoring a
# warning is not a gate. If a check fires, fix the source; there is no override flag.
#
# By default it copies and shows the diff and stops. Committing and pushing are
# separate, explicit steps, because "sync" should not mean "publish" by accident.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd git rsync

WIKI_BRANCH="master"
DOCS_DIR="$REPO_ROOT/docs"
WIKI_DIR="${LLM_EKS_WIKI_DIR:-$(cd -- "$REPO_ROOT/.." && pwd)/wiki}"

heading "wiki-sync — $DOCS_DIR → $WIKI_DIR ($WIKI_BRANCH)"

[ -d "$DOCS_DIR" ] || die "no $DOCS_DIR to publish."
[ -d "$WIKI_DIR/.git" ] || die "no wiki clone at $WIKI_DIR. Clone terraform-llm-eks.wiki.git there, or set LLM_EKS_WIKI_DIR."

# ------------------------------------------------------------------ gate 1: voice
#
# Rule 3 of the workspace rules. The author writes in their own voice, and the
# published documentation is the place where a slip would be most visible and least
# recoverable. The first letter of each alternative sits in a one-character class so
# that this line does not match itself.

if grep -rniE '[c]laude|[a]nthropic|ai-[g]enerated|ai-[a]ssisted|[g]enerated by' \
     "$DOCS_DIR" 2>/dev/null; then
  error "the lines above would be published."
  die "authorship check failed. Fix the source in docs/; there is no override for this."
fi
check PASS "authorship" "nothing in docs/ names an assistant or claims machine authorship"

# ------------------------------------------------------------------ gate 2: secrets

if command -v gitleaks >/dev/null 2>&1; then
  # `gitleaks dir <path>`, not `detect --no-git -s <path>`: same scan, but `detect` is a
  # hidden compatibility alias at the pinned 8.30.1 that upstream intends to drop at v9.
  # scripts/lint.sh and .github/workflows/ci.yml use the same form, and the same pinned
  # config, so this gate and those two cannot disagree about what counts as a finding.
  gitleaks_config="$REPO_ROOT/.gitleaks.toml"
  [ -f "$gitleaks_config" ] || gitleaks_config="$REPO_ROOT/scripts/gitleaks.toml"
  if gitleaks dir --no-banner --redact --config "$gitleaks_config" "$DOCS_DIR" >/dev/null 2>&1; then
    check PASS "secrets" "gitleaks found nothing in docs/"
  else
    error "gitleaks found something in docs/. Run 'mise run lint' to see it."
    die "secret check failed."
  fi
else
  # A gate that disappears when its tool is missing is not a gate. This script never
  # calls check_summary, so a WARN here changed neither the exit status nor whether the
  # copy went ahead: running wiki-sync outside mise would have published docs/ with no
  # secret scan at all.
  die "gitleaks is not on PATH, so the secret gate cannot run. Publish through 'mise run wiki-sync', which pins it; there is no override for this."
fi

# ------------------------------------------------------------------ gate 3: identifiers
#
# An account id is not a secret, but it is an identifier, and the project's own rule
# is that nothing published carries one without the author having decided it should.
# This one can be acknowledged, because the state bucket's name legitimately contains
# the account id and there is nothing to be done about that.

account_hits="$(grep -rnoE '\b[0-9]{12}\b' "$DOCS_DIR" 2>/dev/null | head -n 20 || true)"
if [ -n "$account_hits" ]; then
  warn "twelve-digit numbers in docs/ — check each one before publishing:"
  printf '%s\n' "$account_hits" | sed 's/^/    /' >&2
  if [ "${WIKI_SYNC_ALLOW_ACCOUNT_ID:-0}" != "1" ]; then
    die "set WIKI_SYNC_ALLOW_ACCOUNT_ID=1 once you have looked at each of those and decided it belongs in public."
  fi
  check WARN "identifiers" "acknowledged with WIKI_SYNC_ALLOW_ACCOUNT_ID=1"
else
  check PASS "identifiers" "no twelve-digit numbers in docs/"
fi

# ------------------------------------------------------------------ the branch

current_branch="$(git -C "$WIKI_DIR" rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" != "$WIKI_BRANCH" ]; then
  warn "the wiki clone is on '$current_branch'; GitHub serves $WIKI_BRANCH."
  git -C "$WIKI_DIR" checkout "$WIKI_BRANCH" ||
    die "cannot switch the wiki clone to $WIKI_BRANCH. Publishing to any other branch changes nothing that a reader can see."
fi
check PASS "branch" "$WIKI_BRANCH"

# ------------------------------------------------------------------ the copy
#
# --delete so that a page removed from docs/ is removed from the wiki. Without it the
# wiki accumulates pages that no longer exist in the source and nobody notices until
# one of them is wrong.

rsync -a --delete \
  --exclude '.git/' \
  --include '*/' \
  --include '*.md' \
  --include '*.png' \
  --include '*.svg' \
  --include '*.gif' \
  --exclude '*' \
  "$DOCS_DIR/" "$WIKI_DIR/"

check PASS "copied" "$(find "$DOCS_DIR" -name '*.md' | wc -l | tr -d ' ') markdown files"

# ------------------------------------------------------------------ the diff

if git -C "$WIKI_DIR" diff --quiet && [ -z "$(git -C "$WIKI_DIR" status --porcelain)" ]; then
  info ""
  check PASS "wiki" "already up to date; nothing to commit"
  exit 0
fi

info ""
info "changes staged in the wiki clone:"
git -C "$WIKI_DIR" add -A
git -C "$WIKI_DIR" status --short | sed 's/^/    /' >&2

# ------------------------------------------------------------------ commit and push

if [ "${WIKI_SYNC_COMMIT:-0}" != "1" ]; then
  cat >&2 <<'EOF'

Copied and staged, not committed. That is the default: a sync should not publish by
accident. When the diff above is what you meant:

    WIKI_SYNC_COMMIT=1 mise run wiki-sync            # commit locally
    WIKI_SYNC_COMMIT=1 WIKI_SYNC_PUSH=1 mise run wiki-sync   # commit and push
EOF
  exit 0
fi

# The identity cannot be stored with `git config` in this workspace, so it travels in
# the environment. mise.toml sets all four; without them a commit would be attributed
# to whatever the machine's default happens to be.
for var in GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
  [ -n "${!var:-}" ] || die "$var is not set. Run this through 'mise run wiki-sync', which sets the identity; a wiki commit under the wrong name is not something you can quietly fix later."
done

message="${WIKI_SYNC_MESSAGE:-docs: sync from repo/docs}"
git -C "$WIKI_DIR" commit -m "$message"
check PASS "committed" "$message"

if [ "${WIKI_SYNC_PUSH:-0}" = "1" ]; then
  git -C "$WIKI_DIR" push origin "$WIKI_BRANCH"
  check PASS "pushed" "origin/$WIKI_BRANCH"
else
  info ""
  info "committed locally. Push with WIKI_SYNC_PUSH=1, or by hand:"
  info "    git -C $WIKI_DIR push origin $WIKI_BRANCH"
fi
