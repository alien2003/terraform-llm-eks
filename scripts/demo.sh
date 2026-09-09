#!/usr/bin/env bash
# mise run demo
#
# Records the README demo with vhs. The tape is scripts/demo.tape and the recording
# is the local checks running — nothing in it touches AWS, for two reasons: it would
# fail on any machine without credentials, and on a machine with them it would put an
# account id into a picture destined for a public README.
#
# Safe to run twice; it overwrites its own output.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd vhs

TAPE="${LLM_EKS_DEMO_TAPE:-$REPO_ROOT/scripts/demo.tape}"

[ -f "$TAPE" ] || die "no tape at $TAPE"

# The tape names its own output path, and it is relative to the working directory.
# Running from anywhere else silently writes the GIF somewhere else.
OUTPUT="$(sed -n 's/^Output[[:space:]]\+//p' "$TAPE" | head -n 1)"
[ -n "$OUTPUT" ] || die "$TAPE has no Output line, so there is nothing to record to."

heading "demo — $TAPE → $OUTPUT"

mkdir -p "$REPO_ROOT/$(dirname "$OUTPUT")"

if ! env -C "$REPO_ROOT" vhs "$TAPE"; then
  die "vhs failed. It needs a terminal it can drive and ttyd and ffmpeg on PATH; check 'vhs doctor'."
fi

[ -f "$REPO_ROOT/$OUTPUT" ] || die "vhs reported success but $OUTPUT is not there."

info ""
check PASS "recorded" "$OUTPUT ($(du -h "$REPO_ROOT/$OUTPUT" | cut -f1))"

cat >&2 <<EOF

Before this goes anywhere public, watch it through once. A recording is a screenshot
that moves, and the same rule applies: no account id, no ARN, no email address, no
key id. If the terminal showed a prompt with a hostname or a path you would rather
not publish, re-record with a plainer prompt rather than cropping.
EOF
