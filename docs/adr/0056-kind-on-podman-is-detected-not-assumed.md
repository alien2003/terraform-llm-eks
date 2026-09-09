# 0056. The integration suite detects its container runtime and refuses to guess

Date: 2026-09-08

## Status

Accepted.

## Context

`mise run test` is meant to run the non-GPU components on a local kind cluster: render the platform
charts, and put each rendered object through a server-side dry run against a real API server, which
catches the rejections that `helm template` and `kubeconform` cannot.

On the machine this workspace lives on, `/usr/bin/docker` is a four-line shell script that execs
podman, and podman itself cannot currently start here: it fails on a read-only `/run/user/1001`.
kind does support podman, through `KIND_EXPERIMENTAL_PROVIDER=podman`, but with rootless cgroup
requirements that have not been checked against this environment. Proving that out is Phase 2's
work, not Phase 1's.

The failure mode to avoid is a suite that reports success having tested nothing. That is worse than
a suite that fails, because it is quoted as evidence.

## Decision

`scripts/test.sh` identifies the runtime in three steps, cheapest and most reliable first:

1. Read the `docker` command itself. Where it resolves to a text file mentioning podman, it is a
   shim. `grep -I` skips binaries, so a real docker binary is never scanned for the word.
2. Otherwise, read what `docker version` says on both streams, because the shim prints its banner on
   stderr when there is no daemon.
3. Otherwise, a daemon that answers `docker info` is a real docker.

Finding a runtime is not the same as it working, so the chosen runtime is then asked `info`, and its
actual error message is reported if it cannot answer.

With no usable runtime the script exits non-zero and prints three concrete options: install a
runtime, point `test/suite.sh` at an existing cluster with a working kubectl context, or set
`LLM_EKS_TEST_SKIP_WITHOUT_RUNTIME=1` to get a skip. The skip prints "SUITE SKIPPED — NOTHING WAS
TESTED" and says in as many words that the run is not evidence.

`test/suite.sh` is separate from `scripts/test.sh` and knows nothing about how its cluster came to
exist. It needs a working kubectl context and nothing else.

## Consequences

The suite can be pointed at any cluster, which is what makes it useful before kind works here and
after: the same cases can run against a real cluster inside a window.

Custom resources whose CRDs are not installed on a kind cluster (Karpenter's, KEDA's, the Prometheus
operator's) are reported as skipped with the reason, per object, rather than failing the
chart. The count of skipped objects is printed, so the gap is visible rather than hidden.

Until a runtime works here, the platform charts are covered by `mise run lint` alone: `helm lint`,
`helm template` and `kubeconform`. That is static checking. It renders the manifests but never asks
an API server whether it would accept them, and the difference is where server-side admission lives.

## Sources

- kind's podman support and the `KIND_EXPERIMENTAL_PROVIDER` variable:
  <https://kind.sigs.k8s.io/docs/user/rootless/>
- kind cluster configuration, including per-node `labels`:
  <https://kind.sigs.k8s.io/docs/user/configuration/>
- Observed in this workspace on 2026-09-08: `docker --version` reports `podman version 4.9.3`, and
  `podman info` fails with `set sticky bit on: chmod /run/user/1001/libpod: read-only file system`.
