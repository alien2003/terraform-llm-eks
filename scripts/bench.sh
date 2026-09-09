#!/usr/bin/env bash
# mise run bench [1] [8] [32] | all
#
# Runs the k6 load profiles in bench/ against the inference endpoint and writes each
# run's raw JSON somewhere it can be cited later.
#
# It makes no AWS calls at all. The endpoint is an address; whether it is a load
# balancer inside a cloud window, a port-forward, or something running on a laptop is
# none of this script's business.
#
# Where the results go matters more than it looks. Rule 5 of the workspace rules says
# every number in the README, the wiki or a blog draft traces to a file under
# materials/, and no number is written from memory. So each run writes a JSON file,
# and if you have not said where, it writes to a temporary directory and tells you —
# loudly — that the results will not survive, because a benchmark whose output was
# only ever on a terminal cannot be cited by anything.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd k6

BENCH_DIR="$REPO_ROOT/bench"
PROFILES_AVAILABLE="1 8 32"

usage() {
  cat >&2 <<'USAGE'
usage: mise run bench [<concurrency> ...]

  concurrency   one or more of 1, 8, 32, or "all". Default: all three, in order.

environment:
  BENCH_BASE_URL   required. Scheme and host of the inference endpoint, no path.
  BENCH_MODEL      required. The model id the server answers to, as /v1/models lists it.
  BENCH_OUT_DIR    where the JSON goes. Point it at materials/measurements/<date>.
  BENCH_DURATION   how long each profile runs. Default 2m.
  BENCH_MAX_TOKENS output tokens to ask for. Default 128.
USAGE
}

# ADR 0050: mise passes a task's arguments as one shell-quoted string, not positionals.
if [ "$#" -eq 0 ]; then
  _usage_args="$(mise_usage_arg args)"
  if [ -n "$_usage_args" ]; then
    eval "set -- $_usage_args"
  fi
fi

PROFILES=""
if [ "$#" -eq 0 ]; then
  PROFILES="$PROFILES_AVAILABLE"
else
  for arg in "$@"; do
    case "$arg" in
      all) PROFILES="$PROFILES_AVAILABLE" ;;
      1|8|32) PROFILES="${PROFILES:+$PROFILES }$arg" ;;
      -h|--help) usage; exit 0 ;;
      *)
        usage
        die "no profile '$arg'. bench/ holds concurrency-1, concurrency-8 and concurrency-32; adding a fourth means adding the file, not the argument."
        ;;
    esac
  done
fi

if [ -z "${BENCH_BASE_URL:-}" ] || [ -z "${BENCH_MODEL:-}" ]; then
  usage
  die "BENCH_BASE_URL and BENCH_MODEL are both required. There is no default endpoint: a benchmark that silently measured the wrong thing would be worse than one that did not run."
fi

# Where results live.
if [ -n "${BENCH_OUT_DIR:-}" ]; then
  OUT_DIR="$BENCH_OUT_DIR"
  ephemeral=0
else
  OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-eks-bench.XXXXXX")"
  ephemeral=1
fi
mkdir -p "$OUT_DIR"

STAMP="$(utc_stamp)"

heading "bench — $BENCH_MODEL at $BENCH_BASE_URL"

if [ "$ephemeral" -eq 1 ]; then
  warn "BENCH_OUT_DIR is not set, so results are going to $OUT_DIR and will not survive."
  warn "Nothing measured in this run may be quoted anywhere until it is in a file under"
  warn "materials/measurements/. Set BENCH_OUT_DIR and run it again if the numbers matter."
fi

# The endpoint, once, before spending minutes discovering it is not there.
if command -v curl >/dev/null 2>&1; then
  if ! curl -fsS --max-time 10 "${BENCH_BASE_URL%/}/v1/models" >/dev/null 2>&1; then
    die "${BENCH_BASE_URL%/}/v1/models did not answer. The endpoint is not ready, or the URL is wrong. k6 would find this out too, two minutes from now."
  fi
  check PASS "endpoint reachable" "${BENCH_BASE_URL%/}/v1/models"
fi

failed=0
for profile in $PROFILES; do
  script="$BENCH_DIR/concurrency-$profile.js"
  [ -f "$script" ] || die "no such profile script: $script"

  out_json="$OUT_DIR/bench-c${profile}-$STAMP.json"

  info ""
  info "--- concurrency $profile → $out_json"

  # BENCH_OUT is read by handleSummary in bench/lib.js and becomes the file name it
  # writes the full result set to.
  if BENCH_OUT="$out_json" k6 run "$script"; then
    check PASS "concurrency $profile" "$out_json"
  else
    check FAIL "concurrency $profile" "k6 exited non-zero — a threshold failed, or the run did"
    failed=1
  fi
done

hr
info "results in $OUT_DIR"

if [ "$failed" -ne 0 ]; then
  die "at least one profile failed. Read the k6 output above before recording anything in materials/measurements/."
fi

cat >&2 <<EOF

${C_GREEN}BENCH COMPLETE.${C_RESET}

The JSON in $OUT_DIR is the only citable record of this run. Copy it into
materials/measurements/ and write the processed table next to it; a figure in the
README traces to that file or it does not go in the README.
EOF
