#!/usr/bin/env bash
# mise run screenshot <dashboard-uid> <output.png> [from] [to]
#
# Renders a Grafana dashboard to PNG through the image renderer. This is the machine
# half of the capture work: anything that can be produced from the environment is
# taken without asking, and only browser, phone and human-terminal shots are
# requested from the author.
#
# Server-side rendering is a GET on /render/d/<uid> with a service account token.
# width and height have documented minimums of 1000 and 500; scale asks the renderer
# for a higher device pixel ratio, which is what makes a dashboard legible when it
# ends up at half size in a blog post.
# https://grafana.com/docs/grafana/latest/dashboards/share-dashboards-panels
# https://grafana.com/docs/grafana/latest/setup-grafana/image-rendering
#
# It makes no AWS calls. Safe to run twice; it overwrites the file it is given.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd curl

MIN_WIDTH=1000
MIN_HEIGHT=500

usage() {
  cat >&2 <<'USAGE'
usage: mise run screenshot <dashboard-uid> <output.png> [<from>] [<to>]

  dashboard-uid  the uid from the dashboard URL, not its title
  output.png     where to write it. Must be outside repo/ and wiki/.
  from, to       Grafana time range, default now-1h to now

environment:
  GRAFANA_URL     required. Base URL, e.g. http://localhost:3000
  GRAFANA_TOKEN   required. A service account token with viewer rights.
  SHOT_WIDTH      default 1600, minimum 1000
  SHOT_HEIGHT     default 900, minimum 500
  SHOT_SCALE      device pixel ratio, default 2
USAGE
}

# ADR 0050: mise passes a task's arguments as one shell-quoted string, not positionals.
if [ "$#" -eq 0 ]; then
  _usage_args="$(mise_usage_arg args)"
  if [ -n "$_usage_args" ]; then
    eval "set -- $_usage_args"
  fi
fi

if [ "$#" -lt 2 ]; then
  usage
  die "a dashboard uid and an output path are both required."
fi

UID_ARG="$1"
OUT_PATH="$2"
FROM="${3:-now-1h}"
TO="${4:-now}"

: "${GRAFANA_URL:?GRAFANA_URL is not set. It is the base URL of the Grafana this project runs, reachable from here — usually through a port-forward.}"
: "${GRAFANA_TOKEN:?GRAFANA_TOKEN is not set. Create a service account token with viewer rights; do not use the admin password.}"

WIDTH="${SHOT_WIDTH:-1600}"
HEIGHT="${SHOT_HEIGHT:-900}"
SCALE="${SHOT_SCALE:-2}"

[ "$WIDTH" -ge "$MIN_WIDTH" ] || die "SHOT_WIDTH must be at least $MIN_WIDTH; Grafana's renderer documents that as the minimum."
[ "$HEIGHT" -ge "$MIN_HEIGHT" ] || die "SHOT_HEIGHT must be at least $MIN_HEIGHT; Grafana's renderer documents that as the minimum."

# A rendered dashboard can carry a cluster name, an account id in a label, or a
# metric series that names something private. Nothing lands inside the published
# tree without a human deciding it should.
# The directory is resolved in a statement of its own. Folded into the assignment
# below it, the exit status would be basename's — always zero — so the die was
# unreachable and a missing directory silently produced /<file>.png, which the
# containment check would then have cleared as being outside the repository.
out_dir="$(cd -- "$(dirname -- "$OUT_PATH")" 2>/dev/null && pwd)" ||
  die "the directory of $OUT_PATH does not exist. Create it first; this script will not guess where you meant."
ABS_OUT="$out_dir/$(basename -- "$OUT_PATH")"

case "$ABS_OUT" in
  "$REPO_ROOT"/*)
    die "refusing to write into the repository. A render goes to materials/screenshots/<phase>/ first, is checked for account identifiers, and is copied into repo/ or wiki/ only after the author has looked at it."
    ;;
  */wiki/*)
    die "refusing to write into the wiki clone, for the same reason. Render it into materials/screenshots/<phase>/ and copy it across once it has been checked."
    ;;
esac

heading "screenshot — dashboard $UID_ARG"

BASE="${GRAFANA_URL%/}"
URL="$BASE/render/d/$UID_ARG/dashboard?orgId=1&from=$FROM&to=$TO&width=$WIDTH&height=$HEIGHT&scale=$SCALE&tz=UTC&kiosk"

info "GET $BASE/render/d/$UID_ARG (${WIDTH}x${HEIGHT} at ${SCALE}x, $FROM to $TO)"

status="$(curl -sS -o "$ABS_OUT" -w '%{http_code}' \
  --max-time "${SHOT_TIMEOUT:-120}" \
  -H "Authorization: Bearer $GRAFANA_TOKEN" \
  "$URL" || true)"

if [ "$status" != "200" ]; then
  rm -f "$ABS_OUT"
  case "$status" in
    401|403) die "Grafana answered $status. The token is wrong, expired, or lacks viewer rights on this dashboard." ;;
    404)     die "Grafana answered 404. Check the uid '$UID_ARG', and check that the image renderer plugin or a remote rendering service is configured — server-side rendering needs one of the two." ;;
    500)     die "Grafana answered 500. Usually the renderer timed out on a heavy dashboard; raise SHOT_TIMEOUT, or narrow the time range." ;;
    000)     die "no answer from $BASE. Is the port-forward up?" ;;
    *)       die "Grafana answered $status." ;;
  esac
fi

# A 200 is not proof of a PNG, so the bytes are checked rather than the status code.
# This is the only sound test of the two: what Grafana documents is that server-side
# rendering requires the image renderer plugin or a remote rendering service and
# fails with an error without one. It does not document which status code or body any
# particular failure produces, and this script does not guess.
# https://grafana.com/docs/grafana/latest/setup-grafana/image-rendering
if ! head -c 8 "$ABS_OUT" | grep -q 'PNG'; then
  rm -f "$ABS_OUT"
  die "the response was 200 but the body is not a PNG. Check that the image renderer plugin or a remote rendering service is configured, and look at what $BASE/render/d/$UID_ARG actually returns."
fi

size="$(du -h "$ABS_OUT" | cut -f1)"
check PASS "rendered" "$ABS_OUT ($size)"

# Every capture is a row in the shot list, mine as much as the author's.
slug="$(basename "$ABS_OUT" .png)"
cat >&2 <<EOF

Add this to materials/blog/SHOTLIST.md, or update the row that asked for it:

  | $slug | <phase> | me | grafana | dashboard $UID_ARG, $FROM to $TO | $ABS_OUT | <post> | done |

Then look at it before it goes anywhere. Panel titles and legend labels are the usual
place an account id or a private hostname turns up in a render.
EOF
