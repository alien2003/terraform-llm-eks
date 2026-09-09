#!/usr/bin/env bash
# mise run test
#
# The kind-based integration suite for the non-GPU components. This script builds the
# cluster, hands it to test/suite.sh, and tears it down again.
#
# A caveat that this script will not paper over. On the machine this was written on,
# `docker` is a shim over podman, and kind has not yet been proven to work against it
# here. kind supports podman, but through KIND_EXPERIMENTAL_PROVIDER and with a set of
# rootless and cgroup requirements that this environment has not been checked against.
# That is Phase 2's problem, not this script's.
#
# So the script detects what it has, says so precisely, and refuses to pretend. It
# does not silently pass when there is no cluster: a green suite that ran nothing is
# the single most expensive kind of test failure. To let an unprovable environment
# report a skip rather than a failure — for a CI job that has no container runtime at
# all, say — set LLM_EKS_TEST_SKIP_WITHOUT_RUNTIME=1 and read the banner it prints.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

CLUSTER_NAME="${LLM_EKS_TEST_CLUSTER:-llm-eks-test}"
KIND_CONFIG="$REPO_ROOT/test/kind-cluster.yaml"
SUITE="$REPO_ROOT/test/suite.sh"
KEEP_CLUSTER="${LLM_EKS_TEST_KEEP:-0}"

# Rule 1 of the workspace rules: nothing this repository runs writes outside the
# workspace, and the two exceptions are mise's own data directory and Docker images and
# containers. Neither covers a kubeconfig.
#
# Both `kind create cluster` and `kind export kubeconfig` write a cluster, a context and
# a client certificate into $KUBECONFIG, and into $HOME/.kube/config when KUBECONFIG is
# unset. `kind delete cluster` edits the same file again to take them out. So the one
# task that needs a cluster was also the one task that created or mutated a dotfile in
# the author's home directory on every run, silently, and left a stale context behind
# whenever a run was interrupted or LLM_EKS_TEST_KEEP was set. This is the same class
# of problem as tflint defaulting to ~/.tflint.d, and it gets the same treatment:
# redirect it into the checkout, where it is gitignored by test/.gitignore.
#
# Set explicitly rather than defaulted, because an inherited KUBECONFIG from the
# author's shell is precisely the file this must not touch. LLM_EKS_KUBECONFIG is the
# deliberate override for someone who means it.
export KUBECONFIG="${LLM_EKS_KUBECONFIG:-$REPO_ROOT/test/.kube/config}"
mkdir -p "$(dirname -- "$KUBECONFIG")"

heading "test — kind integration suite"

note "KUBECONFIG=$KUBECONFIG"

# ------------------------------------------------------------------ what we have

missing_runtime() {
  local reason="$1"
  if [ "${LLM_EKS_TEST_SKIP_WITHOUT_RUNTIME:-0}" = "1" ]; then
    cat >&2 <<EOF

${C_YELLOW}SUITE SKIPPED — NOTHING WAS TESTED.${C_RESET}

  $reason

LLM_EKS_TEST_SKIP_WITHOUT_RUNTIME=1 is set, so this is reported as a skip rather than
a failure. Nothing below has been verified. Do not read this run as evidence that the
platform charts work.
EOF
    exit 0
  fi

  error "$reason"
  cat >&2 <<'EOF'

The suite needs a local Kubernetes cluster and cannot invent one. Options, in the
order they are worth trying:

  1. Install a container runtime kind supports and re-run. With podman, kind needs
     KIND_EXPERIMENTAL_PROVIDER=podman, which this script sets for you when it finds
     podman and no real Docker daemon.
  2. Point the suite at a cluster you already have:
         kubectl config use-context <ctx> && test/suite.sh
     test/suite.sh only needs a working kubectl context; it creates no cluster, and
     unlike this script it does not redirect KUBECONFIG, so it uses whichever
     kubeconfig your shell already points at.
  3. If you genuinely have no runtime and want a skip instead of a failure, set
     LLM_EKS_TEST_SKIP_WITHOUT_RUNTIME=1 and accept that nothing is being tested.
EOF
  exit 1
}

if ! command -v kind >/dev/null 2>&1; then
  missing_runtime "kind is not on PATH. mise.toml pins it; try 'mise install' first."
fi

RUNTIME=""
RUNTIME_DETAIL=""

# Three ways to tell a real docker from podman wearing the name, cheapest first,
# because the obvious one is the least reliable: on a host where podman cannot start
# at all, `docker version` prints an error and no banner, and a check that reads only
# the banner concludes there is no runtime rather than that podman is broken.
if command -v docker >/dev/null 2>&1; then
  docker_path="$(command -v docker)"
  docker_real="$(readlink -f "$docker_path" 2>/dev/null || printf '%s' "$docker_path")"

  # 1. The command itself. On this workspace /usr/bin/docker is a four-line shell
  #    script that execs podman. -I skips binaries, so a genuine docker binary is
  #    never read looking for the word.
  if grep -qsIi podman "$docker_real"; then
    RUNTIME="podman"
    RUNTIME_DETAIL="$docker_path is a shell wrapper around podman"
  else
    # 2. What it says about itself, on both streams: the shim prints its client
    #    banner on stderr when there is no daemon to talk to.
    docker_version="$( { docker version || docker --version; } 2>&1 || true)"
    if printf '%s' "$docker_version" | grep -qi podman; then
      RUNTIME="podman"
      RUNTIME_DETAIL="docker on this host reports itself as podman"
    elif docker info >/dev/null 2>&1; then
      # 3. A daemon that answers is a real docker.
      RUNTIME="docker"
      RUNTIME_DETAIL="docker daemon reachable"
    fi
  fi
fi

if [ -z "$RUNTIME" ] && command -v podman >/dev/null 2>&1; then
  RUNTIME="podman"
  RUNTIME_DETAIL="podman on PATH, no docker daemon"
fi

# Having found a runtime is not the same as it working. Ask it something.
if [ -n "$RUNTIME" ] && ! "$RUNTIME" info >/dev/null 2>&1; then
  runtime_error="$( { "$RUNTIME" info 2>&1 || true; } | head -n 2 | tr '\n' ' ')"
  missing_runtime "$RUNTIME is installed but not usable here: $runtime_error"
fi

if [ -z "$RUNTIME" ]; then
  missing_runtime "no usable container runtime: neither a docker daemon nor podman answered."
fi

check PASS "container runtime" "$RUNTIME — $RUNTIME_DETAIL"

if [ "$RUNTIME" = "podman" ]; then
  export KIND_EXPERIMENTAL_PROVIDER=podman
  warn "kind on podman is experimental and has not been proven in this workspace."
  warn "If cluster creation fails below, that is the known gap, not a fault in the"
  warn "charts. See test/README.md."
fi

[ -f "$KIND_CONFIG" ] || die "no kind config at $KIND_CONFIG"
[ -x "$SUITE" ] || die "no executable suite at $SUITE"

# ------------------------------------------------------------------ the cluster

# Safe to run twice: an existing cluster of the same name is reused rather than
# recreated, and it is only deleted at the end if this run created it.
created_here=0
if kind get clusters 2>/dev/null | grep -Fxq "$CLUSTER_NAME"; then
  check PASS "cluster" "$CLUSTER_NAME already exists, reusing it"
else
  info "creating kind cluster $CLUSTER_NAME (this takes a minute or two)"

  create_args=(create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG" --wait 5m)
  # test/kind-cluster.yaml explains why the node image is not pinned in the file.
  [ -n "${KIND_NODE_IMAGE:-}" ] && create_args+=(--image "$KIND_NODE_IMAGE")

  if ! kind "${create_args[@]}"; then
    error "kind could not create the cluster."
    if [ "$RUNTIME" = "podman" ]; then
      cat >&2 <<'EOF'

This is the known gap. kind on podman needs rootless cgroup v2 delegation and, on
some distributions, to be started inside its own cgroup scope:

    systemd-run --scope --user kind create cluster --config test/kind-cluster.yaml

Getting this to work is Phase 2's job. Until it does, the platform charts are
covered by 'mise run lint' — helm lint, helm template and kubeconform — which is
static checking only: it renders the manifests but never asks an API server whether
it would accept them.
EOF
    fi
    exit 1
  fi
  created_here=1
  check PASS "cluster" "$CLUSTER_NAME created"
fi

cleanup() {
  local status=$?
  if [ "$created_here" -eq 1 ] && [ "$KEEP_CLUSTER" != "1" ]; then
    info ""
    info "deleting kind cluster $CLUSTER_NAME"
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    # kind takes its context out of the file but leaves the file. It held a client
    # certificate for a cluster that no longer exists, so it goes too, unless the
    # author pointed KUBECONFIG somewhere of their own.
    if [ "$KUBECONFIG" = "$REPO_ROOT/test/.kube/config" ]; then
      rm -f "$KUBECONFIG"
    fi
  elif [ "$created_here" -eq 1 ]; then
    warn "LLM_EKS_TEST_KEEP=1: leaving $CLUSTER_NAME running. Delete it with:"
    warn "    kind delete cluster --name $CLUSTER_NAME"
  fi
  exit "$status"
}
trap cleanup EXIT

kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null

# ------------------------------------------------------------------ the suite

info ""
"$SUITE"
