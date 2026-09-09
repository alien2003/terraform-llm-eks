# 0006. CI holds no cloud credentials, and every action is pinned to a commit SHA

Date: 2026-09-08

## Status

Accepted.

## Context

The usual shape for infrastructure CI is a workflow that assumes a role and runs `terraform plan` against
the real account, so that a pull request shows the diff it would produce. It is genuinely useful and it is
not what this repository does.

Two reasons, and the second is the one that decided it for me.

The first is that a plan needs read access across the whole account, and the role that has it is a role
that exists to be assumed by a workflow rather than by a person. This account holds Free Tier credits
treated as cash, its safety model rests on a permission boundary and on windows opened by hand, and adding
a continuously available path into it undermines both. Every apply here happens with a human watching,
inside a window, in the main conversation. A pipeline that can reach the account is a path that does not
have that property.

The second is that a plan against a real account is not what these checks need. Terraform can download
providers and modules from the public registry, resolve variables and check every expression and every
resource argument with `init -backend=false` followed by `validate`. Helm can render a chart offline and
`kubeconform` can validate the result against real CRD schemas fetched over HTTPS. tflint, trivy,
shellcheck, actionlint, markdownlint and gitleaks never needed an account in the first place. The set of
mistakes that only a real plan catches is small, and it is caught in the window's own pre-flight, which
runs `terraform plan` before anything is applied.

The related question is supply chain. A workflow with no secrets is still a workflow that executes code
from other people's repositories on a runner that has a checkout of this one. `uses: actions/checkout@v7`
resolves a tag, and a tag is a pointer its owner can move at any time.

## Decision

`.github/workflows/ci.yml` has no `configure-aws-credentials` step, no AWS secret, and a top-level
`permissions:` block granting `contents: read` and nothing else. In particular it does not grant
`id-token: write`, so the OIDC token endpoint variables are never injected and the workflow cannot mint a
token to exchange for AWS credentials even if a step tried.

A job named `no-cloud-credentials` checks that: it fails if any AWS credential variable, role variable or
credential-file path is set, if `$HOME/.aws` exists, or if the OIDC request variables are present.

That job checks out the repository and runs the mise action with its defaults, which looks like waste in a
job that runs one `grep`-shaped shell loop. It is not. `jdx/mise-action`'s `env` input defaults to `true`
and appends the output of `mise env` to `$GITHUB_ENV`, so `mise.toml`'s `[env]` block is part of the
environment every other job in the file runs in. The first version of this job skipped both steps, and the
result was an assertion about an environment no check ran in: a credential added to `mise.toml` would have
reached terraform in eight jobs while this one stayed green. Running the same setup is what makes the check
mean anything.

`AWS_PROFILE` is not on the list, and that is a decision rather than an omission. `mise.toml` sets it to
`llm-eks-operator` (Rule 2a: no local command can act as anything else) and it therefore arrives on the
runner with the rest of `[env]`. A profile name is not a credential; it names a block in `~/.aws/config`,
and the `$HOME/.aws` check is what proves there is no such file for it to resolve against.

The limit of the job is worth stating, because the first draft of this ADR overstated it. It covers the
shared environment: the workflow's top-level `env:`, and anything `mise.toml` exports. It does not cover a
step-level `env:` added to some other job, which nothing inside this workflow can observe. It is a tripwire
on the environment the checks run in, not a proof about the file as a whole. Reviewing a diff is still what
catches a deliberately added secret.

Every `uses:` is pinned to a full-length commit SHA with the tag it corresponds to in a trailing comment.

The toolchain comes from mise reading `mise.toml` (ADR 0001), and mise itself is pinned to an exact release
in the workflow's `env`, because otherwise the resolver of every pinned version would be the one unpinned
thing in the build.

CI does not simply run `mise run lint`, even though that script runs the same checks locally. The script
reports SKIP when a tool is not on PATH or a directory does not exist yet, which is the right behaviour on
a laptop and the wrong one on a build server, where a check that quietly did not run is indistinguishable
in the summary from a check that passed. Each CI job installs what it needs and fails if it is missing.

## Consequences

A pull request does not show a Terraform diff. Getting one means opening a window, which is friction I
chose rather than an oversight.

Pinning to SHAs means no action ever updates itself, and a security fix in `actions/checkout` reaches this
repository only when someone changes the SHA. That is the accepted cost, and it is the same trade the rest
of the repository makes (ADR 0001). The trailing tag comments exist so the pins can be read and compared
without resolving each SHA by hand.

`tflint --init` downloads the AWS ruleset from GitHub releases and is given `GITHUB_TOKEN` to avoid the
anonymous rate limit. That is the workflow's own automatically issued read-only token, scoped to this
repository, and it is not a cloud credential. It is the only token in the file.

The kind-based integration suite behind `mise run test` runs in CI as its own job. It is the one check in
the set that needs a live API server: it sends the rendered charts to one as server-side dry runs, which
catches what `helm template` and `kubeconform` structurally cannot, such as a field the API rejects or a
name the API considers too long. `LLM_EKS_TEST_SKIP_WITHOUT_RUNTIME` is deliberately not set on that job,
so a runner without a container runtime fails it rather than printing a skip that reads like a pass.

Custom resources whose CRDs live only on the real cluster (NodePool, EC2NodeClass, ScaledObject,
ExternalSecret, ClusterSecretStore, ServiceMonitor) report as skipped there, and the suite says so per
object. That is the honest limit of a kind cluster and it is why the job is an addition to `kubeconform`
against the CRD catalogue rather than a replacement for it.

## Sources

- GitHub Actions secure use reference: "Pinning an action to a full-length commit SHA is currently the only
  way to use an action as an immutable release."
  <https://docs.github.com/en/actions/reference/security/secure-use>
- GitHub Actions on the default token and on restricting `permissions` at the workflow level:
  <https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions>
- `jdx/mise-action`, for the `version`, `install_args` and `cache` inputs used here, and for the `env`
  input: "Automatically load mise environment variables for subsequent steps", default `true`, which is
  why the credentials job runs the action rather than skipping it:
  <https://github.com/jdx/mise-action/blob/c2a87611a18de5b3828c5652fe268e992400cb5c/action.yml>
- Terraform `init -backend=false`, which is what allows validation with no backend and no credentials:
  <https://developer.hashicorp.com/terraform/cli/commands/init>
