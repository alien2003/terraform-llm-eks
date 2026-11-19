# 0059. `mise run up` plans each phase and owns the window's inputs

Date: 2026-11-19

## Status

Accepted. Carries out the Consequences of ADR 0037 and ADR 0042, which said `scripts/` had to change
and were never followed up.

## Context

Writing the rehearsal for window 1 meant reading `window-up.sh` against everything it applies. Four
things in it would have failed after the kill timer was armed, with the EKS control plane and the NAT
gateway already billing:

- It applied `infra/cluster` once. ADR 0037 needs two applies on an empty state, the first with
  `-var platform_enabled=false`, because the `kubernetes` provider cannot be configured from an endpoint
  the same apply creates. The first plan fails with `default cluster has no server defined`.
- `grafana_admin_secret_arn` is required once the platform layer is on, the secret is created by hand
  inside a window (ADR 0042), and nothing passed its ARN in. Phase 2 fails validation.
- The inference pod syncs `s3://<weights bucket>/models/<model id>/` and the platform README says a
  mirror step puts the weights there. There was no mirror step.
- Nothing wrote a kubeconfig. `aws eks update-kubeconfig` without `--kubeconfig` writes to
  `~/.kube/config`, which is outside the workspace this project is built in.

Separately, a one-shot timer that had already fired still counted as armed. Timers are kept after they
fire (ADR 0051), and the script matched on the name only.

## Decision

Step 5 of `window-up.sh` is now, in order:

1. `infra/bootstrap`: plan, show the counts, confirm, apply that plan file.
2. The weights upload starts in the background.
3. `infra/cluster` phase 1, `platform_enabled=false`, same plan, confirm, apply. Skipped when the
   state already holds phase 2, because phase 1 over a live platform plans to destroy all of it.
4. A kubeconfig at `.kube/config` inside the checkout. `mise.toml` points `KUBECONFIG` there.
5. The Grafana secret, created if absent: a generated password in a `0600` temporary file, passed as
   `file://`, never on a command line and never printed. Tagged `Stack=cluster` so the audit finds
   it if it outlives the window.
6. Wait for the weights upload; stop if it failed.
7. `infra/cluster` phase 2 with the secret ARN.

Every apply is of a saved plan file. What the human confirmed and what runs are the same object, and
"plan before apply" from the window protocol is in the tool rather than in somebody's memory.

`window-down.sh` destroys with the inputs the apply used: the secret ARN when the platform layer is in
state, `platform_enabled=false` when it never got that far. Variable validation runs on a destroy too.
After the destroy it deletes the secret with no recovery window, because a secret pending deletion
still exists and the audit would report it, and it removes the kubeconfig.

The weights come from Hugging Face at one pinned commit, listed file by file with sizes and hashes in
`scripts/weights.json`. `scripts/weights.sh fetch` downloads and verifies them into a cache outside the
checkout, with no AWS involved, before any window. `push` uploads inside the window, while EKS is being
created. I chose this over a Job inside the cluster because S3 inbound is free and the Job would pay NAT
data processing on 15.2 GB and need a write role on a bucket the cluster otherwise only reads.
`window-up.sh` checks before arming the timer that the weights are either in the bucket already or in a
verified local copy.

A timer whose `at()` time has passed now stops `mise run up` with an instruction to run `mise run down`.

## Consequences

`mise run up` asks for confirmation four times instead of once: the cost, bootstrap, phase 1 and
phase 2. That is the point. Each prompt shows the create, update, replace and destroy counts, and warns
when anything would be destroyed.

The first window takes the 15.2 GB download out of the window's clock. It costs local disk, at
`../.weights` by default or wherever `LLM_EKS_WEIGHTS_DIR` points.

`weights.sh` refuses to run if `weights.json` and the `model_id` default in the platform module name
different models, because the upload would land on a prefix the pod never reads.

`bench.sh` still does not wake the deployment from zero, although ADR 0046 says it does. Window 1 needs
one request, not a benchmark, so that fix belongs with window 2.
