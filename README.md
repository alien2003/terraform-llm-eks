# terraform-llm-eks

Terraform for running an open-weights LLM on EKS with GPU Spot capacity, built so that a mistake costs
minutes of compute instead of a month of rent.

The inference part is ordinary: a VPC, an EKS cluster, Karpenter, a vLLM deployment on an L4 node, KEDA
scaling it back to zero, Prometheus and Grafana watching it. Plenty of repositories do that.

The part I actually care about is the other half. This is a personal account with Free Tier credits and no
employer behind it, and a GPU node left running over a weekend is a real amount of money. So the account
gets a guardrail stack before it gets a cluster, cloud resources only exist inside a window I open by hand
and close the same session, and a timer tears the cluster down if I walk away. All of that is Terraform and
shell, not a note in a wiki. It is described below because it is the interesting design in the repository.

## Status

Local scaffold. The stacks initialise and validate, the charts render and pass schema validation against
real CRD schemas, and nothing has been applied to an account yet. Nothing has been planned against one
either, because `terraform plan` needs credentials and there are none. There are no measurements. See
[Results](#results).

## The money-safety design

Three layers, in decreasing order of how much I trust them.

### Layer 1: the permission boundary

`infra/guardrails` creates the IAM role that every other apply runs as, and a permission boundary that role
carries. The boundary is a whitelist. It names the instance types this project may launch, requires the GPU
types to be Spot, denies everything else by instance type rather than by trying to enumerate what is
expensive, and denies the account-level actions that would break the safety model: creating IAM users or
access keys, joining an organization, upgrading the account plan, or changing the guardrails themselves.

The operator role cannot weaken its own boundary. Changing the whitelist, the Spot rule, a quota target or a
budget threshold needs an apply with the administrator role, and the administrator profile exists in my AWS
CLI configuration only during the two moments of this project that require it: the first window, when the
guardrails go up, and the last step of the last window, when they come down.

That is the layer I trust, because it is enforced by IAM and not by me remembering something.

### Layer 2: the timers

`mise run up` will not start without a window number and a duration, and both are copied verbatim from an
approval message. Before it applies anything it arms a one-shot EventBridge schedule at now plus the
duration, pointing at a Lambda whose job is to stop the money rather than to look decisive.

Terminating instances is not the same thing as stopping spend, which is what the first version of that
Lambda got wrong. A managed node group replaces what it loses within minutes, Karpenter re-provisions a GPU
node for a pod that is still pending, and the control plane and the NAT gateway bill by the hour whether or
not an instance exists. So the order is: scale the node groups to zero, delete them, terminate every
project-tagged instance, delete the load balancers and NAT gateways in the project VPCs, release the
Elastic IPs, delete the cluster. `mise run down` disarms the schedule only after `mise run audit` reports no
orphans.

Deleting a node group takes minutes and a cluster cannot go while one exists, so a fired timer usually
leaves the cluster for a second pass. The always-on sweeper is that second pass. It runs whether or not a
window is open, terminates any project-tagged instance older than its configured age, and escalates to the
full stop when it finds an hourly resource sitting there with no instances and no window timer pending. It
is the layer that survives me closing the laptop, losing the network, or the session ending badly. Neither
timer asks anyone for confirmation.

### Layer 3: the money alarms

A budget on gross spend with credits excluded, a Cost Anomaly Detection monitor, and a CloudWatch billing
alarm, all publishing to one SNS topic that goes to email. It goes to SMS too, but a new account is in the
SNS SMS sandbox, where a message only reaches a number that has been added and verified by hand first. So
the SMS subscription stays off until I tell Terraform that has been done. The budget carries an automatic
action.

These are the layer I trust least, and deliberately so. Billing data lags by hours, and whether AWS Budgets
even observes pre-credit usage on a Free Plan account is an open question I intend to answer by measurement
rather than assumption. Alarms tell me something went wrong yesterday. The boundary and the timers are what
stop it going wrong today.

## The window protocol

Default mode is local. Nothing in this repository creates, modifies or deletes a billable resource unless a
window is open. Read-only calls, `terraform plan`, `--dry-run` and Cost Explorer queries are always fine.

A window opens with one message, in one shape, written by me:

```text
APPROVE CLOUD WINDOW <n>: <purpose>; max <hours>h; max $<amount>
```

Nothing else opens one. Not "yes", not "go ahead". Extending a window is another message in the same shape.

Inside a window the order is fixed and does not vary:

```text
mise run guard-status          every guardrail present and healthy, or the window does not open
pre-flight                     profile, region, quotas, credit balance
terraform plan                 and a stated estimate per hour, with and without the GPU node
mise run up WINDOW_ID=n WINDOW_HOURS=h
...                            only the work written down in the window plan, nothing else
mise run down
mise run audit                 zero orphans
```

The window is then recorded and closed. A window never spans two sessions. If anything fails unexpectedly,
the rule is to tear down first and investigate afterwards, because investigating is cheaper than a node.

Every window is rehearsed locally before it is requested: exact commands, expected durations, the abort
procedure, and a cost estimate.

## Entry points

There is one way to run each thing, and it is a task. Nobody should have to paste a long command out of a
document.

| Task | What it does |
| --- | --- |
| `mise run auth <admin\|operator>` | Print the assumed-role ARN, or fail loudly |
| `mise run guard-status` | Report every guardrail present and healthy |
| `mise run guard-drill` | Drill the boundary: policy simulator plus a `run-instances --dry-run` matrix |
| `mise run up WINDOW_ID=<n> WINDOW_HOURS=<h>` | Arm the one-shot kill timer, then apply |
| `mise run down` | Destroy, audit, then disarm the timer if the audit is clean |
| `mise run audit` | Scan for orphaned project-tagged resources |
| `mise run lint` | Every local check, with no cloud credentials |
| `mise run test` | kind-based integration suite for the non-GPU components |
| `mise run bench` | k6 load profiles against the inference endpoint |
| `mise run demo` | Record the terminal demo with vhs |
| `mise run screenshot` | Render a Grafana dashboard to PNG |
| `mise run wiki-sync` | Publish `docs/` to the wiki |

## Layout

```text
infra/guardrails/       IAM boundary, budgets, anomaly monitor, billing alarm, kill Lambda, schedules
infra/bootstrap/        state and weights buckets, ECR pull-through cache
infra/cluster/          VPC, EKS, the system node group, the AWS half of Karpenter
infra/cluster/platform/ child module of the cluster stack: NodePools, KEDA, monitoring, secrets, vLLM
scripts/                everything behind a mise task
test/                   the kind suite
bench/                  k6 profiles
docs/                   conventions and architecture decision records
.github/workflows/      CI
```

The three stacks have three different lifecycles, which is why they are three stacks and not one. Guardrails
is applied once and destroyed last. Bootstrap holds the buckets that outlive a window. The cluster stack is
created and destroyed inside a single window, repeatedly. ADR 0003.

Guardrails and bootstrap keep local state; the cluster stack uses the S3 backend with native S3 locking and
no DynamoDB table. The reason is a circular dependency rather than a preference, and it is written down in
ADR 0004.

The platform layer is a child module of the cluster stack rather than a fourth stack, so the things running
inside the cluster share the cluster's state and the cluster's lifetime. It applies in a second pass,
because a Kubernetes provider cannot be configured from an endpoint the same apply is still creating.
ADR 0037.

## Running it yourself

You need an AWS account you are willing to spend real money in, an email address for the alerts, and
[mise](https://mise.jdx.dev). A phone number is optional and only pays off if you are willing to verify it
out of the SNS SMS sandbox first. Everything else comes from `mise.toml`.

```console
mise install                    # the pinned toolchain
mise run lint                   # no credentials needed for any of this
```

Then apply `infra/guardrails` with an administrator identity, once. That is the only apply that happens by
hand and the only one the administrator role is used for. Everything after it happens inside a window:
`mise run up` applies `infra/bootstrap` and then `infra/cluster` as the operator, and `mise run down`
destroys only the cluster, so the buckets and the cache survive between windows. Each stack has its own
README with the variables it expects.

I would read `infra/guardrails/README.md` before applying anything. That stack is the one whose failure mode
is a bill.

## Results

Nothing here is measured yet. Phase 1 produced the scaffold and no benchmarks, and this project's rule is
that a number in a document has to trace back to a file that recorded it, so the table below has columns and
no figures rather than plausible ones.

| Model | Instance | Concurrency | Output tokens/s | p50 latency | p99 latency | Cost per 1M output tokens |
| --- | --- | --- | --- | --- | --- | --- |
| not yet measured | | | | | | |

`mise run bench` produces the raw k6 output; the processed tables are kept with my working notes under
`materials/measurements/` and get copied here once a benchmark window has actually run.

## Local checks and CI

Everything that can run without an AWS account runs without one:

```console
mise run lint
```

That is `terraform fmt` and `validate` for each stack, `tflint`, `trivy config`, `helm lint`,
`helm template` piped to `kubeconform`, `shellcheck`, `markdownlint`, `actionlint`, `gitleaks`, and the kill
Lambda's unit tests.

`kubeconform` validates the custom resources these charts render, not just the built-in kinds. Its schema
locations come from `infra/cluster/platform/kubeconform-schemas.txt`: kubeconform's own default location
first, for Deployments and Services and the rest, then the public CRD catalogue for NodePool, EC2NodeClass,
ScaledObject, ExternalSecret, ClusterSecretStore and ServiceMonitor. The number to read in the summary is
`Skipped 0`. There is an `-ignore-missing-schemas` fallback for the case where that file has gone missing,
and lint warns loudly whenever it takes it, because a partial check that looks like a full one is worse than
no check at all.

CI runs the same checks on every push and pull request, with one difference that is worth knowing about: it
fails where the local script reports SKIP for a tool that is not installed, because on a build server a
check that quietly did not run looks exactly like a check that passed. It also runs the one check that lint
leaves out, `mise run test`: a kind cluster, and every chart pushed at its API server as a server-side dry
run. Custom resources whose CRDs exist only on the real cluster report as skipped there, one line each.

CI holds no cloud credentials at all: no `configure-aws-credentials` step, no AWS secret, and no
`id-token: write` permission, so the workflow cannot mint an OIDC token even if a future edit tried to. One
job checks that, on a runner set up the way the check jobs are. Every action is pinned to a commit SHA.
ADR 0006.

`gitleaks` also runs as a pre-commit hook, over the staged diff rather than the working tree. The hook does
not arrive with the clone: run `mise exec -- pre-commit install` once, per clone. Nothing yet fails when you
have not, and that is the weak point of this section, because an uninstalled hook and a passing hook look
identical from outside `.git/hooks/`.

## Decisions

Anything non-obvious is an ADR in [`docs/adr/`](docs/adr/), with the source it came from and the reasoning,
including the ones that turned out to be wrong. Naming, tagging and the ADR process are in
[`docs/conventions.md`](docs/conventions.md).

## License

Apache 2.0. See [LICENSE](LICENSE).
