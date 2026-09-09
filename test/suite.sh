#!/usr/bin/env bash
# The integration cases. scripts/test.sh builds the cluster and calls this; this file
# knows nothing about how the cluster came to exist, which is what lets it also be
# pointed at a real one.
#
# It requires a working kubectl context and nothing else. It creates namespaces and
# renders manifests; it applies nothing for real. Every apply is a server-side dry
# run, which is the interesting kind: it goes through admission and schema validation
# on a live API server, so it catches the things `helm template` and kubeconform
# cannot — a field the API rejects, a name that is too long, an immutable field set.
#
# It deliberately does not set KUBECONFIG. scripts/test.sh exports a workspace-local
# one before it creates anything, because kind writes to that file; this script only
# reads the current context and talks to the API server, and being pointable at a
# cluster the reader already has is the whole reason it is a separate file.
#
# Custom resources whose CRDs are not installed here are reported SKIPPED rather than
# failed. Karpenter, KEDA and the Prometheus operator define theirs on the real
# cluster, and pretending a kind cluster can validate them would be a lie the suite
# tells itself.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)/lib/common.sh"

require_cmd kubectl helm

NAMESPACE="${LLM_EKS_TEST_NAMESPACE:-llm-eks-test}"
CHART_DIR="$REPO_ROOT/infra/cluster/platform/charts"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-eks-suite.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

heading "integration suite — context $(kubectl config current-context 2>/dev/null || echo none)"

# ------------------------------------------------------------------ the cluster

if kubectl version --request-timeout=10s >/dev/null 2>&1; then
  check PASS "api server reachable" "$(kubectl config current-context)"
else
  die "no reachable Kubernetes API server. scripts/test.sh should have created one; run it rather than this file."
fi

not_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" { print $1 }')"
node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ -z "$not_ready" ] && [ "$node_count" -gt 0 ]; then
  check PASS "nodes ready" "$node_count/$node_count"
else
  check FAIL "nodes ready" "not ready: ${not_ready:-<no nodes at all>}"
fi

# The kind config labels one worker the way the real system node group is labelled.
# A chart that selects on it has somewhere to go.
if kubectl get nodes -l llm-eks.io/role=system --no-headers 2>/dev/null | grep -q .; then
  check PASS "system role label" "llm-eks.io/role=system present"
else
  check FAIL "system role label" "no node carries llm-eks.io/role=system; test/kind-cluster.yaml sets it"
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml |
  kubectl apply -f - >/dev/null 2>&1 || true

# ------------------------------------------------------------------ the charts

if [ ! -d "$CHART_DIR" ]; then
  check SKIP "charts" "no $CHART_DIR yet"
else
  mapfile -t CHARTS < <(find "$CHART_DIR" -maxdepth 2 -name Chart.yaml -print0 2>/dev/null |
    xargs -0 -n1 dirname 2>/dev/null | sort -u)

  if [ "${#CHARTS[@]}" -eq 0 ]; then
    check SKIP "charts" "no Chart.yaml under $CHART_DIR"
  fi

  for chart in "${CHARTS[@]}"; do
    name="$(basename "$chart")"
    rendered="$WORK_DIR/$name.yaml"

    if ! helm template "$name" "$chart" --namespace "$NAMESPACE" >"$rendered" 2>"$WORK_DIR/$name.err"; then
      check FAIL "render $name" "$(head -c 160 "$WORK_DIR/$name.err" | tr '\n' ' ')"
      continue
    fi
    check PASS "render $name" "$(grep -c '^kind:' "$rendered") objects"

    # One document at a time, so that a custom resource with no CRD skips itself
    # instead of taking the whole chart down with it.
    doc_dir="$WORK_DIR/$name-docs"
    mkdir -p "$doc_dir"
    awk -v dir="$doc_dir" '
      BEGIN { n = 0; file = sprintf("%s/%04d.yaml", dir, n) }
      /^---[[:space:]]*$/ { n++; file = sprintf("%s/%04d.yaml", dir, n); next }
      { print > file }
    ' "$rendered"

    applied=0
    skipped=0
    failed=0
    for doc in "$doc_dir"/*.yaml; do
      [ -s "$doc" ] || continue
      grep -q '^kind:' "$doc" || continue

      kind_name="$(sed -n 's/^kind:[[:space:]]*//p' "$doc" | head -n 1)"

      if kubectl apply --dry-run=server --namespace "$NAMESPACE" -f "$doc" \
           >"$WORK_DIR/apply.out" 2>&1; then
        applied=$((applied + 1))
      elif grep -qiE 'no matches for kind|could not find the requested resource|ensure CRDs are installed' \
             "$WORK_DIR/apply.out"; then
        skipped=$((skipped + 1))
        note "  skipped $kind_name: its CRD is not installed on a kind cluster"
      else
        failed=$((failed + 1))
        error "  $kind_name rejected by the API server:"
        sed 's/^/      /' "$WORK_DIR/apply.out" >&2
      fi
    done

    if [ "$failed" -eq 0 ]; then
      check PASS "server dry-run $name" "$applied validated, $skipped skipped for missing CRDs"
    else
      check FAIL "server dry-run $name" "$failed rejected, $applied validated, $skipped skipped"
    fi
  done
fi

# ------------------------------------------------------------------ cleanup

kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true

check_summary "integration suite"
