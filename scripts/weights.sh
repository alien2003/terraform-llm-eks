#!/usr/bin/env bash
# scripts/weights.sh fetch | verify | remote | push
#
# Gets the model weights into the weights bucket, which is the step the platform
# README calls "the mirror": the inference pod's init container syncs
# s3://<weights bucket>/models/<model id>/ onto the node, and this module is the only
# thing that ever writes there. Called by window-up.sh; the subcommands exist so each
# half can be run, and rehearsed, on its own.
#
#   fetch   download every file in weights.json from Hugging Face at the pinned
#           revision into the local cache, then verify. No AWS call; LOCAL mode.
#   verify  check the local cache against weights.json: sha256 for the LFS files,
#           the git blob id for the small ones. No network at all.
#   remote  check the bucket prefix holds every file at the right size. Read-only.
#   push    upload the verified local cache to the bucket. Needs an open window.
#
# Why the download is local and the upload happens inside the window (ADR 0059):
# S3 inbound transfer is free, the download needs no account at all, and the
# alternative, a Job in the cluster pulling from Hugging Face, pays NAT data
# processing on 15 GB and needs a write role on the bucket the cluster otherwise
# only reads.
#
# The cache lives outside the checkout by default. Every lint pass in this repository
# walks the tree, and 15 GB of safetensors plus a third-party README.md is not
# something gitleaks or markdownlint should be asked to read.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd jq

MANIFEST="$REPO_ROOT/scripts/weights.json"
[ -f "$MANIFEST" ] || die "no $MANIFEST"

MODEL_ID="$(jq -r '.model_id' "$MANIFEST")"
REVISION="$(jq -r '.revision' "$MANIFEST")"
PREFIX="models/$MODEL_ID"
CACHE_DIR="${LLM_EKS_WEIGHTS_DIR:-$(cd -- "$REPO_ROOT/.." && pwd)/.weights}/$MODEL_ID"
HF_BASE="https://huggingface.co/$MODEL_ID/resolve/$REVISION"

# The bucket prefix the init container reads is models/<model_id> with the id taken
# from the platform module's variable. If the two ever disagree the upload lands
# somewhere the pod never looks, and the failure shows up twenty minutes later as an
# empty model directory.
platform_model="$(sed -n '/^variable "model_id"/,/^}/s/^[[:space:]]*default[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$REPO_ROOT/infra/cluster/platform/variables.tf")"
[ "$platform_model" = "$MODEL_ID" ] ||
  die "weights.json names $MODEL_ID but infra/cluster/platform model_id defaults to '${platform_model:-unset}'. Change both together."

weights_bucket() {
  printf '%s-weights-%s' "$NAME_PREFIX" "$(account_id)"
}

cmd_verify() {
  local name size want_sha want_blob path got bad=0
  [ -d "$CACHE_DIR" ] || { error "no local copy at $CACHE_DIR"; return 1; }
  while IFS=$'\t' read -r name size want_sha want_blob; do
    path="$CACHE_DIR/$name"
    if [ ! -f "$path" ]; then
      check FAIL "$name" "missing"; bad=1; continue
    fi
    got="$(wc -c <"$path" | tr -d ' ')"
    if [ "$got" != "$size" ]; then
      check FAIL "$name" "size $got, want $size"; bad=1; continue
    fi
    if [ "$want_sha" != "-" ]; then
      got="$(sha256sum "$path" | cut -d' ' -f1)"
      [ "$got" = "$want_sha" ] || { check FAIL "$name" "sha256 $got, want $want_sha"; bad=1; continue; }
    else
      got="$(git hash-object --no-filters "$path")"
      [ "$got" = "$want_blob" ] || { check FAIL "$name" "git blob $got, want $want_blob"; bad=1; continue; }
    fi
    check PASS "$name" "$size bytes"
  done < <(jq -r '.files[] | [.name, (.size|tostring), (.sha256 // "-"), (.git_blob // "-")] | @tsv' "$MANIFEST")
  return "$bad"
}

cmd_fetch() {
  require_cmd curl
  mkdir -p "$CACHE_DIR"
  info "fetching $MODEL_ID at $REVISION into $CACHE_DIR"
  local name size path have
  while IFS=$'\t' read -r name size; do
    path="$CACHE_DIR/$name"
    have=0
    [ -f "$path" ] && have="$(wc -c <"$path" | tr -d ' ')"
    if [ "$have" = "$size" ]; then
      note "  $name already complete"
      continue
    fi
    info "  $name ($size bytes)"
    mkdir -p "$(dirname -- "$path")"
    # -C - resumes a partial file, which matters for four files of ~3.9 GB each.
    curl --fail --location --silent --show-error --retry 5 -C - -o "$path" "$HF_BASE/$name"
  done < <(jq -r '.files[] | [.name, (.size|tostring)] | @tsv' "$MANIFEST")
  cmd_verify
}

cmd_remote() {
  require_cmd aws
  local bucket listing name size got bad=0
  bucket="$(weights_bucket)"
  if ! aws_ro s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    error "bucket $bucket does not exist yet"
    return 1
  fi
  listing="$(aws_ro s3api list-objects-v2 --bucket "$bucket" --prefix "$PREFIX/" --output json |
    jq -r '(.Contents // [])[] | [.Key, (.Size|tostring)] | @tsv')"
  while IFS=$'\t' read -r name size; do
    got="$(printf '%s\n' "$listing" | awk -F'\t' -v k="$PREFIX/$name" '$1 == k { print $2 }')"
    if [ "$got" != "$size" ]; then
      check FAIL "s3 $name" "${got:-missing}, want $size"; bad=1
    fi
  done < <(jq -r '.files[] | [.name, (.size|tostring)] | @tsv' "$MANIFEST")
  [ "$bad" -eq 0 ] && check PASS "s3://$bucket/$PREFIX/" "every file present at the right size"
  return "$bad"
}

cmd_push() {
  require_cmd aws
  [ "${LLM_EKS_WINDOW_WRITE:-0}" = "1" ] ||
    die "push refused: LOCAL mode. Uploading creates billable objects; it runs from 'mise run up'."
  if cmd_remote >/dev/null 2>&1; then
    check PASS "weights" "already in the bucket, nothing to upload"
    return 0
  fi
  cmd_verify >/dev/null || die "the local copy at $CACHE_DIR does not verify; run 'scripts/weights.sh fetch' first."
  local bucket
  bucket="$(weights_bucket)"
  info "uploading $CACHE_DIR to s3://$bucket/$PREFIX/"
  aws s3 sync "$CACHE_DIR/" "s3://$bucket/$PREFIX/" --only-show-errors --no-progress
  cmd_remote
}

case "${1:-}" in
  fetch)  cmd_fetch ;;
  verify) cmd_verify ;;
  remote) cmd_remote ;;
  push)   cmd_push ;;
  *) die "usage: scripts/weights.sh fetch | verify | remote | push" ;;
esac
