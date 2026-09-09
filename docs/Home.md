# terraform-llm-eks

Terraform for running an open-weights LLM on EKS with GPU Spot capacity, built so that a mistake costs
minutes of compute instead of a month of rent.

This is the published documentation. It is generated from `docs/` in the repository by `mise run wiki-sync`,
so edits belong there rather than here; anything written directly into the wiki is overwritten on the next
sync.

## Start here

The repository README explains what the project is, the three layers of the money-safety design, and the
window protocol. It is the front door and this page is not a substitute for it.

[Conventions](conventions.md) covers names, tags, the shape of a stack, and how decision records are written.

Each stack has its own README next to the code, which is where the exact commands and variables live:
`infra/guardrails`, `infra/bootstrap`, `infra/cluster` and `infra/cluster/platform`.

## Decisions

Every non-obvious choice in this repository is an architecture decision record under [`adr/`](adr/README.md),
with the source it came from, the reasoning, and what it would take to revisit it. The ones that turned out
to be wrong are there too.

The cross-cutting ones are worth reading first:

- ADR 0001, on why every version is pinned and where the toolchain lives.
- ADR 0003, on why there are three Terraform stacks rather than one.
- ADR 0004, on why two of them keep local state.
- ADR 0006, on why CI holds no cloud credentials at all.

## Results

Nothing is measured yet. The benchmark table in the README has columns and a placeholder rather than
figures, and it stays that way until a benchmark window has actually run.
