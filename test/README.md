# test

The kind-based integration suite for the non-GPU components.

```sh
mise run test
```

## What it covers

`scripts/test.sh` creates a two-node kind cluster from `kind-cluster.yaml` and runs `suite.sh`
against it. The suite:

- checks the API server answers and every node is Ready;
- checks a node carries `llm-eks.io/role=system`, which is the label the real managed node group
  carries and the one the platform charts select on;
- renders every chart under `infra/cluster/platform/charts/` with `helm template`;
- splits each rendered chart into single objects and puts each through
  `kubectl apply --dry-run=server`.

The server-side dry run is the point. It goes through schema validation and admission on a live API
server, so it catches what `helm template` and `kubeconform` cannot: a field the API rejects, a name
that is too long, an immutable field set on an object that already exists.

## Where the kubeconfig goes

`scripts/test.sh` exports `KUBECONFIG=test/.kube/config` before it runs kind, and creates the
directory. This matters more than it looks. Both `kind create cluster` and `kind export kubeconfig`
write a cluster, a context and a client certificate into `$KUBECONFIG`, and into the home
directory's kubeconfig when the variable is unset; `kind delete cluster` edits the same file again
to take them out. Left alone, the one task that needs a cluster was also the one task that created
or mutated a dotfile outside the workspace on every run, and left a stale context and its
certificate behind whenever a run was interrupted or `LLM_EKS_TEST_KEEP=1` was set.

The redirect is the same treatment `mise.toml` already gives tflint's `~/.tflint.d`. The file is
gitignored by `test/.gitignore`, allowlisted in `scripts/gitleaks.toml` so a kind certificate does
not turn the secret scan red, and deleted when `scripts/test.sh` tears down a cluster it created.
`LLM_EKS_KUBECONFIG` overrides the location for someone who means to. `mise run lint` fails if a
script under `scripts/` or `test/` runs kind or kubectl without exporting `KUBECONFIG` first.

`suite.sh` is the exception and does not set it: it creates nothing, it only reads the current
context, and being pointable at a cluster you already have is the reason it is a separate file.

## What it does not cover

There is no GPU node here and there never will be. Anything that needs an L4 is window work.

Custom resources whose CRDs are not installed on a kind cluster — Karpenter's `NodePool` and
`EC2NodeClass`, KEDA's `ScaledObject`, the Prometheus operator's `ServiceMonitor` — are reported as
skipped, per object, with the reason. The count is printed. Pretending a bare kind cluster can
validate them would be a lie the suite tells itself.

To cover them, install the CRDs into the kind cluster first and re-run; the suite will pick them up
without changes, because it decides per object rather than per chart.

## The container runtime, and why this may not run for you

On the machine this was written on, `/usr/bin/docker` is a four-line shell script that execs podman,
and podman itself cannot start here: it fails with `set sticky bit on: chmod /run/user/1001/libpod:
read-only file system`. kind does support podman, through `KIND_EXPERIMENTAL_PROVIDER=podman`, but
with rootless cgroup requirements that have not been checked against this environment. Proving that
out is Phase 2's work.

So `scripts/test.sh` detects what it has, reports the runtime's actual error, and exits non-zero
rather than passing having tested nothing. A green suite that ran nothing is the most expensive kind
of test failure, because it gets quoted as evidence.

Three ways forward when it refuses:

1. Install a runtime kind supports. With podman on a systemd distribution, kind sometimes needs its
   own cgroup scope: `systemd-run --scope --user kind create cluster --config test/kind-cluster.yaml`.
2. Point the suite at a cluster you already have. `suite.sh` needs a working kubectl context and
   nothing else:

   ```sh
   kubectl config use-context <ctx>
   test/suite.sh
   ```

3. `LLM_EKS_TEST_SKIP_WITHOUT_RUNTIME=1 mise run test` reports a skip instead of a failure, and
   prints "SUITE SKIPPED — NOTHING WAS TESTED" so that nobody reads the run as evidence.

ADR 0056 has the detection logic and the reasoning.

## The node image

`kind-cluster.yaml` does not pin a node image digest. The image is pinned by the kind binary
version, which `mise.toml` fixes at 0.33.0, and each kind release ships with one default node image;
pinning a digest as well means two versions to keep in step and one of them will drift. To pin
explicitly, set `KIND_NODE_IMAGE` to the `kindest/node` reference with the `sha256` digest from the
kind release notes, and `scripts/test.sh` passes it through.

## Environment

| variable | effect |
| --- | --- |
| `LLM_EKS_TEST_CLUSTER` | cluster name, default `llm-eks-test` |
| `LLM_EKS_TEST_NAMESPACE` | namespace the suite renders into, default `llm-eks-test` |
| `LLM_EKS_TEST_KEEP` | `1` leaves the cluster running after the suite |
| `LLM_EKS_TEST_SKIP_WITHOUT_RUNTIME` | `1` turns "no runtime" from a failure into a skip |
| `LLM_EKS_KUBECONFIG` | overrides the workspace-local kubeconfig, default `test/.kube/config` |
| `KIND_NODE_IMAGE` | overrides the node image |
