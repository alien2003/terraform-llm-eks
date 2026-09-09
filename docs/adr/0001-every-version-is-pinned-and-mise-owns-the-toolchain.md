# 0001. Every version is pinned, and mise owns the toolchain

Date: 2026-09-08

## Status

Accepted.

## Context

This project is built in short, expensive bursts. Cloud resources exist only inside a window I open by
hand and close the same session, and the whole point of the window protocol is that the work inside it is
rehearsed and predictable. A toolchain that drifts underneath me breaks that in the worst possible place:
a `terraform plan` that produced one diff during the rehearsal and a different one inside the window,
because the provider moved in between.

The ordinary version of this problem is annoying. Here it costs money, because the fix happens while a GPU
node is running.

There is a second reason, which is that this repository is meant to be readable a year from now. A README
that says "install terraform" and a CI file that says `terraform_version: latest` describe a build that
nobody can reproduce. Almost every non-obvious decision in `docs/adr/` was made against the behaviour of a
specific version of something, and a decision record whose subject has silently moved on is worse than no
record.

## Decision

Nothing floats. Concretely:

`mise.toml` is the single place tool versions are written, with exact versions and no ranges: terraform,
kubectl, helm, kind, k6, vhs, tflint, trivy, gitleaks, terraform-docs, kubeconform, shellcheck,
markdownlint-cli2, actionlint, pre-commit, s5cmd, yq, jq and the AWS CLI. CI installs its toolchain with
the mise GitHub action reading that same file, so a check that passes on my laptop passes on a runner for
the same reason and not by coincidence.

Terraform providers are pinned to an exact version in each stack's `required_providers`, and
`.terraform.lock.hcl` is committed. Registry modules are pinned to an exact version. Helm charts are pinned
to an exact chart version, and the chart version used by CI's offline render is read from the same
Terraform variable the apply uses, so there is one pin rather than two that can disagree. Container images
are pinned by tag, with a digest where the upstream publishes one usefully. GitHub Actions are pinned to a
full commit SHA, which is ADR 0006.

The one deliberate range is `required_version = "~> 1.16"` in every stack. That constrains the Terraform
CLI a person runs rather than something this repository downloads, and pinning it to a single patch release
would reject a colleague on 1.16.2 for no benefit. The floor is 1.16 because 1.16.1 is the CLI `mise.toml`
pins, so what the constraint buys is that a stack cannot be applied by an older CLI than the one it was
rehearsed with. It is not a feature requirement, and an earlier draft of this ADR claimed it was. The
feature that looked like one is S3-native state locking, and it does not need 1.16: `use_lockfile` became
generally available in Terraform 1.11, and the S3 backend documentation states no minimum version for it at
all.

Upgrading anything is a deliberate commit with the new number in it. Where the upgrade was not obvious, it
gets an ADR.

## Consequences

Nothing updates itself, which means nothing updates. That is the real cost of this decision and I would
rather pay it than the alternative: the six-month-old repository whose CI is red for reasons that have
nothing to do with the last commit. If this repository grows past one person, Dependabot configured for
GitHub Actions and Terraform is the standard remedy, and the pins above are exactly what it needs in order
to open a readable pull request.

`mise install` is a real download on a cold machine. CI installs only the tools each job needs, by naming
them in the action's `install_args`, and the versions still come from `mise.toml`.

Two version numbers describe the same thing in different places and can drift: the Helm CLI in `mise.toml`
and the Helm SDK vendored by the Terraform helm provider. ADR 0002 covers that pair specifically.

## Sources

- mise dev tools documentation, on writing exact versions in `mise.toml` and on `mise install`:
  <https://mise.jdx.dev/dev-tools/>
- Terraform version constraints, including the meaning of `~>`:
  <https://developer.hashicorp.com/terraform/language/expressions/version-constraints>
- Terraform dependency lock file, on why `.terraform.lock.hcl` belongs in version control:
  <https://developer.hashicorp.com/terraform/language/files/dependency-lock>
- Terraform 1.11 changelog, on S3-native state locking: "S3 native state locking is now generally
  available. The `use_lockfile` argument enables users to adopt the S3-native mechanism for state locking."
  <https://github.com/hashicorp/terraform/blob/v1.11.0/CHANGELOG.md>
- Terraform S3 backend, which documents `use_lockfile` as an optional argument defaulting to `false` and
  names no minimum CLI version for it:
  <https://developer.hashicorp.com/terraform/language/backend/s3>
