# scripts

The implementations behind every `mise run` task. Nothing here is meant to be run by hand — the
tasks are the interface — but every script works when invoked directly, which is what makes them
testable.

```sh
mise run auth <admin|operator>          scripts/auth.sh
mise run guard-status                   scripts/guard-status.sh
mise run guard-drill                    scripts/guard-drill.sh
mise run up WINDOW_ID=<n> WINDOW_HOURS=<h>   scripts/window-up.sh
mise run down                           scripts/window-down.sh
mise run audit                          scripts/audit.sh
mise run lint                           scripts/lint.sh
mise run test                           scripts/test.sh
mise run bench [1|8|32|all]             scripts/bench.sh
mise run demo                           scripts/demo.sh
mise run screenshot <uid> <out.png>     scripts/screenshot.sh
mise run wiki-sync                      scripts/wiki-sync.sh
```

## The three things worth knowing before editing any of them

**Arguments do not arrive as positionals.** `mise run up WINDOW_ID=0 WINDOW_HOURS=3` sets an
environment variable `usage_vars` holding `'WINDOW_ID=0' 'WINDOW_HOURS=3'`, and leaves `$#` at zero.
Every script that takes arguments re-expands that variable when there are no positionals, and works
either way. ADR 0050.

**AWS calls go through a wrapper, and the wrapper is the mode switch.** `scripts/lib/common.sh`
provides `aws_ro` for read-only calls, `aws_dry_run` for EC2 calls carrying `--dry-run`, and
`aws_write` for anything that changes something. `aws_ro` refuses any operation whose name is not
obviously a read. `aws_write` refuses unless `LLM_EKS_WINDOW_WRITE=1`, which only `window-up.sh` and
`window-down.sh` set. That flag is an environment variable, so what it enforces is that some
ancestor process set it rather than that this process checked anything: a child of either script
inherits it, and so does anything run from a shell where it was already set. Both scripts turn it
off again across the child scripts they call, and nothing else here sets it. Default mode is LOCAL
and in LOCAL mode nothing billable is created, modified or deleted; that rule is enforced by these
wrappers rather than by anyone remembering it.

**One script writes outside the repository.** `guard-drill.sh` writes its results to
`materials/guardrails/`, because a drill whose output scrolled past in a terminal cannot be cited
later and the project's rule is that every published number traces to a file. `bench.sh` and
`screenshot.sh` write wherever they are told and warn when that is somewhere temporary; neither has
a default inside the repository. Nothing else writes outside `repo/` at all.

## What each one does

### auth.sh

Calls `sts:GetCallerIdentity` and prints the assumed-role ARN. It exists for its failure messages:
"Unable to locate credentials" is the same sentence whether the profile block is commented out, the
role was never created, or the trust policy does not admit the base user, and those are three
different problems with three different fixes. It separates them and says which.

Asked for `admin`, it prints the reminder that the admin profile belongs uncommented during exactly
two moments in this project — applying the guardrails in window 0, and destroying them in the last
step of the final window — and that the last step of each is asking the human to comment it out
again and confirming that `mise run auth admin` fails.

Any role name other than `admin` or `operator` is rejected. There is no third identity.

### guard-status.sh

The definition of green. It checks the operator role and its boundary, the budget and its automatic
action, the anomaly monitor and its subscription, the billing alarm and whether the metric it
watches has ever been published, the alert topic and — separately — whether its subscriptions are
actually confirmed, the kill Lambda and whether it is still in dry-run from a drill, the sweeper
schedule, the window schedule group, the scheduler execution role, the four alarms on the kill path,
the regions the kill Lambda sweeps against the regions the boundary permits, every quota target,
whether the account is in an AWS Organization, and the three read-only Free Tier APIs.

Present and healthy are not the same thing, and most of the interesting failures live in the gap: a
topic with an unconfirmed email subscription is present, a kill Lambda left in `DRY_RUN=true` is
present, a disabled sweeper schedule is present.

Five of those checks are worth spelling out, because each of them used to give a green answer to a
question it had not asked.

**The two billing alarms.** `AWS/Billing EstimatedCharges` is month-to-date and only ever rises
within a month, so the cumulative alarm on it crosses its threshold at most once per calendar month
and then sits in `ALARM` until the month rolls over. `ALARM` there means "gross spend has crossed
the threshold at some point this month"; failing on it would block every remaining window of the
month, which is exactly the pressure that gets a guardrail edited rather than obeyed. So it is a
warning, printed with the reason CloudWatch gives and with the timestamp of the transition into
`ALARM` from `describe-alarm-history`, so the author can compare that against the last `CLOSED`
entry in `materials/costs/windows.md`. The hard failure is the burn-rate alarm, which watches the
`DIFF` of the same metric and therefore means spend is being added *now*. Its absence is itself a
failure, because it is what makes warning on the cumulative one safe.

**SMS.** An SMS subscription is given a real `SubscriptionArn` immediately, with no confirmation
handshake, so the pending-confirmation logic counts it as confirmed the moment it exists. Whether
anything is delivered is decided elsewhere: a new account is in the SNS SMS sandbox, where a message
reaches only numbers that have been added and verified. `guard-status` now asks
`get-sms-sandbox-account-status` and `list-sms-sandbox-phone-numbers` and fails when a subscribed
number is not `Verified`. When it cannot read either, it says so and names the two commands to run
by hand rather than reporting a path it has not checked. Even a verified number is a warning and not
a pass: AWS also requires an origination identity for some destinations, which this script cannot
check, so the SMS path is unproven until one real alert has arrived.

**The sweeper age contract.** The always-on sweeper terminates project compute past `MAX_AGE_MINUTES`
whether or not a window is open. If that age is not longer than the longest window the approval form
can grant, the sweeper kills a cluster somebody is legitimately using, halfway through. The
guardrails stack derives one from the other; `guard-status` checks that the derivation is what is
actually deployed, by comparing the live Lambda's environment against the published limits and both
against the maximum window length. `mise run up` reads the same parameter and refuses to open a
window if it is unreadable or if the two disagree.

**The kill-path alarms and the region contract.** The guardrails stack publishes the names of the
four alarms that watch the kill path, and the regions it gave the kill Lambda, to
`/llm-eks/guardrails/limits`. It publishes them so that they can be checked, and until this version
nothing read either one. Now each alarm has to exist, have its actions enabled and be in `OK`;
`ALARM` means the teardown path is degraded right now, and `INSUFFICIENT_DATA` means the alarm has
never evaluated, which is indistinguishable from healthy until the moment it was needed. Both fail,
and the message prints the evaluation period and the state timestamp, because an alarm applied a
minute ago legitimately reads `INSUFFICIENT_DATA` and the answer to that is to run `guard-status`
again rather than to open a window.

The regions are checked twice. Against the published limits, which came from the same apply as the
function, so a disagreement means one of them is stale. And against the `RegionLock` statement in
the deployed boundary document, which is the list actually being enforced: a region the boundary
permits and the sweeper does not visit is a region where a mis-set `AWS_REGION` can leave a GPU node
that no automatic control will ever reach.

**Quota targets bind in a direction, and the direction is data.** A quota that has to be raised
before the project can run and a quota that has to stay small are opposite requirements, and testing
both as "at least the target" is how an account whose Standard quota AWS has quietly raised reports
`PASS`. Each target may carry a `direction` of `floor`, `ceiling` or `exact`; a target that carries
none is held to an exact match, which is the strictest reading and the safe default. That matters
more than it looks. Per the service authorization reference, `eks:CreateNodegroup` reads only
`aws:RequestTag`, `aws:ResourceTag` and `aws:TagKeys`, and `eks:UpdateNodegroupConfig` only
`aws:ResourceTag`: neither carries an instance-type, capacity-type or scaling-size condition key, so
neither can be bounded in IAM at all. The quota is the only ceiling those two calls have.

Quota codes are discovered at run time from quota names, with
`list-aws-default-service-quotas` rather than `list-service-quotas` — the latter omits every quota
that has never had an applied value, which on this account is precisely the accelerator families
that must read zero. No `L-` code appears in `scripts/` or `infra/`, and `lint.sh` fails if one
does — those are the two trees it scans, so an illustrative mention in an ADR is outside its reach
and is not what the check is for. ADR 0054.

It exits non-zero if anything is missing. A window does not open unless it is green.

### guard-drill.sh

The permission boundary drill, in three parts: `simulate-principal-policy` for the actions with no
dry-run, a `run-instances --dry-run` matrix for the launch conditions, and the kill path, which is
asked about and then run.

Every simulation names a resource ARN, and several cases are pairs — the same action against a
project ARN and a non-project one — because a simulation against `*` cannot tell a scoped deny from
a blanket one. ADR 0053.

Naming the ARN is only half of it. Every case also names the region the request is made into and
every condition key the boundary reads on that action, because the boundary's denies are written
with negated operators and AWS documents that a negated operator matches a key that has no value.
A case that leaves `aws:RequestedRegion` unset is denied by the region lock whatever else it was
testing, which means it would still report PASS with the statement it exists to prove deleted. Any
key the simulator reports as unresolved fails its case unless the case declared that the absence is
the point.

Which keys those are is not remembered, it is derived. `BOUNDARY_CONTEXT_KEYS` in the script lists
every condition key `infra/guardrails/iam_operator.tf` reads together with the statement that reads
it, and `lint.sh` re-derives the same list from that file on every run and fails if the two have
drifted. So a failure inside a window says which key was missing, which statement wants it and what
to add to the case, instead of leaving the reader to grep the boundary while a timer runs down.

Every case states the outcome it expects and the script fails if reality differs in either
direction. Results go to `materials/guardrails/drill-<timestamp>.{txt,json}`.

The simulator half also covers the statements that are not on the `run-instances` path, because the
launch matrix cannot reach them: the three volume bounds (wrong type, too large, provisioned IOPS,
each against a violating request and against the GPU node's own 120 GiB gp3 root volume, which has
to stay possible or the cluster cannot start a GPU node at all), the tag statements (`Project`
cannot be deleted or repointed, `Window` can be written freely), EKS Auto Mode, and `ec2:CreateFleet`,
which is how Karpenter actually launches.

Two of the simulator's groups are there because the control they test is the *absence* of a grant,
which is the weakest kind there is. The autoscaling cases are one: an Auto Scaling group launches
through `AWSServiceRoleForAutoScaling`, which carries no permission boundary, so none of the launch
conditions are evaluated on that path, and the narrowing is that `autoscaling:Describe*` is inside
the ceiling and every write is outside it. Each of those is an implicit deny, and a single wildcard
added to either policy document would remove all of them at once with nothing else noticing. The
blanket tag-wipe case is the other: `ec2:DeleteTags` with no `Tags` parameter removes every
user-defined tag, and the request then carries no `aws:TagKeys` at all, so the `ForAnyValue` test
that guards the `Project` tag matches nothing and denies nothing. `NoBlanketTagWipe` is a `Null` test
written for that one call, and the case that proves it is the one that leaves the key unset on
purpose. Both groups are paired with the call that must keep working: `DescribeAutoScalingGroups`,
and a `DeleteTags` that names the `Window` tag.

The third part is the kill path. The simulator says what the boundary would decide about the kill
Lambda; this asks what is actually deployed — the kill role's trust policy names only the Lambda
service and no assumable principal, the role carries no permissions boundary, and it has no attached
managed policies — and then invokes the function in `report` mode, which walks the whole full-stop
path and performs none of it. That invocation is the only thing in this repository that proves the
kill role can really see what it would have to stop, which no simulation and no local test can. Two
fields of the returned report are the proof that a report is a report: `terminated` and `done` are
appended only past the handler's `dry_run` guard and must both be empty, while `failed` holds every
read the role was not permitted to make and must be empty too.

Who may fire it is itself a control, and it decides what that case expects. The alert topic and the
scheduler execution role are the only principals the function's resource policy names, and
`lambda:InvokeFunction` is outside the operator's ceiling, so run as the operator the invoke must be
refused: an operator that could fire the kill path by hand could fire `kill_all` in the middle of a
measurement. Run as the administrator it must succeed and the report is then checked. Both are
expectations and either can fail. Because the rest of the drill measures the operator, the drill is
not re-run wholesale with administrator credentials; when the invoke is refused the script prints
the single command that exercises report mode instead.

The CreateFleet cases drill the type whitelist and the tag requirement and make no claim about the
instance market, because the CreateFleet row of the EC2 authorization reference lists no
`ec2:InstanceMarketType` and a condition key an action does not support is ignored rather than
enforced. `infra/guardrails/iam_operator.tf` says the same thing above `GpuSpotOnly` and ADR 0011
has the reasoning. What keeps the GPU pool on Spot on that path is the "Running On-Demand G and VT
instances" quota, held at a target of zero and re-checked by `guard-status` at window open. A drill
case asserting an IAM deny there would pass a simulation and prove nothing, which is worse than not
having one.

### window-up.sh

Opens a window, in a fixed order: require both arguments, require `guard-status` green, read the
window limits the guardrails stack publishes, print the estimated cost from `rates.json` at the
steady state and at the stack's own ceiling, ask for confirmation, arm the one-shot kill timer, and
only then apply.

The timer is armed before anything is applied. That is the safety property: if the apply hangs, if
the session dies, if the human walks away, the timer still fires. ADR 0051. The timer carries the
dead-letter queue the guardrails stack creates, so a kill event that cannot be delivered lands
somewhere with an alarm on it rather than being dropped after three retries.

There is no maximum window length written down here. The upper bound belongs to the guardrails
stack, which derives the always-on sweeper's age threshold from it; a copy in this file would go
stale in the direction that hurts, because a window longer than the sweeper tolerates dies
mid-benchmark. Both numbers are read from `/llm-eks/guardrails/limits`, and the script refuses to
open a window if it cannot read them, if they disagree with each other, or if the requested hours
exceed the published maximum.

Two cost figures are printed, not one. The steady state is what an idle open window costs; the
ceiling is what the stack is allowed to reach with nobody doing anything, and it is the ceiling in
the confirmation prompt because that is the number the `max $<amount>` in the approval message has
to be checked against. The GPU line is where they differ: the inference deployment scales to
`inference_max_replicas`, one replica per GPU node.

It refuses to run without `WINDOW_ID` and `WINDOW_HOURS`, refuses hours below the minimum or above
the published maximum, refuses to run as the admin profile, refuses if a timer for another window is
already armed, and refuses if any price in `rates.json` is missing. Running it twice leaves an
existing timer alone rather than pushing the deadline out; extending a window is a new approval
message.

#### What it applies, and in what order

`infra/bootstrap`, then `infra/cluster`. That is a dependency chain, not a list: bootstrap creates
the Terraform state bucket that `infra/cluster`'s backend lives in, so a cluster apply before it has
nowhere to keep its state. The script says so plainly rather than letting the raw backend error
speak, by checking the bucket exists before initialising any stack that declares an S3 backend.

`infra/cluster/platform` is not in the list. It is a child module of `infra/cluster`, not a root
stack: no backend, no provider configuration of its own, seven variables with no default. The parent
stack calls it.

`infra/guardrails` is not in the list either, and must not be. It is applied with the admin profile
in window 0 and destroyed with the admin profile in the final window.

### window-down.sh

Destroys `infra/cluster` and nothing else. Not the reverse of the apply order, deliberately:
`infra/bootstrap` holds the state bucket the cluster stack's own backend lives in, so destroying it
from here would delete the state of the stack being destroyed, mid-run. Bootstrap also holds the
weights bucket and the ECR pull-through cache, both of which exist precisely to survive between
windows. It is destroyed once, by hand, in the final window, before guardrails.

Destroy, then audit, then disarm — and the disarm only happens inside a branch guarded by the
audit's exit status. If the audit is dirty the timer stays armed and the script says so at length.
There is no flag to skip the audit and no flag to force the disarm. ADR 0052.

It prints the `materials/costs/windows.md` entry for the author to paste. It does not write it: a
cost record written by the thing being measured is not a cost record.

### audit.sh

Scans the working region and `us-east-1` for orphans. Something is an orphan if it is tagged
`Stack=cluster` and still exists, or if it has an hourly price whatever stack claims it, or if it
carries the `Project` tag with no `Stack` tag at all.

Instances, volumes, Elastic IPs, NAT gateways, interface endpoints, load balancers, EKS clusters and
node groups are checked explicitly. Everything else comes from the Resource Groups Tagging API,
which sees services this script does not name but can lag by minutes, so it supplements the explicit
checks rather than replacing them.

#### The untagged sweeps

Selecting on the `Project` tag answers "no project-tagged orphans", which is a different question
from "no orphans", and several billable things in this design never carry the tag. A load balancer
created by a Kubernetes Service carries `kubernetes.io/*` tags and nothing of ours. A volume left by
a PVC carries the CSI driver's. An Elastic IP allocated outside Terraform carries none. So four of
the priced classes get a second sweep that does not use the tag:

- Instances with no `Project` tag, in any state. Invisible to the sweeper, which is the failure the
  boundary's tag condition exists to prevent; counting them is the only way to notice the condition
  has stopped working.
- Load balancers, both APIs. `elbv2` is not the whole story: an unannotated `type: LoadBalancer`
  Service with no controller installed gets a *classic* load balancer, which lives in a different
  API and is invisible to `elbv2` before any tag is considered. Both are listed, and one is an
  orphan if it carries the tag or if it sits in a VPC this project created.
- NAT gateways in a project VPC with no `Project` tag.
- Unattached volumes and unassociated Elastic IPs with no `Project` tag. Neither is in a VPC, so
  there is nothing to attribute them by; unattached and unassociated is the discriminator, and it is
  also the state in which they bill for nothing.

Attribution by VPC id is what makes the load balancer and NAT gateway sweeps possible: the VPC is
created by the cluster stack and does carry the tag, so anything inside it is this project's
whatever its own tags say.

#### Standing costs, which are reported and are not orphans

The ECR pull-through cache repositories (untagged by design, because tagging them needs a
`custom_role_arn` the bootstrap stack does not create) and the project's CloudWatch log groups are
reported with their sizes and are not counted as orphans. Both are meant to survive a window and
both keep billing after `mise run down`; calling them orphans would leave the audit permanently
dirty and the kill timer permanently armed, which is the opposite of the intent. They are printed so
their figures reach `materials/costs/windows.md` instead of nowhere. The one exception is a log
group with no retention policy at all, which is an unbounded storage charge and is treated as an
orphan, with the one-line fix in the message.

Exit non-zero when anything is found. Read-only throughout.

### lint.sh

Every local check, run to completion rather than stopped at the first failure, with the output of
each failure printed under it. `terraform fmt`, per-stack `init -backend=false` and `validate`,
`tflint`, `trivy config` per stack, `helm lint`, `helm template` piped to `kubeconform`,
`shellcheck -x`, `markdownlint-cli2`, `actionlint`, `gitleaks`, the kill Lambda's unit tests, and
six house rules: the authorship grep, a check that no `L-` quota code has been hardcoded, a check
that the admin profile is named only in the scripts that have business naming it, a check that
`guard-drill.sh` still declares every condition key the operator boundary reads, a check that no
script writes a kubeconfig into the home directory, and a check that the pre-commit hook is
installed.

Vendored Terraform modules under `.terraform/` are excluded from `trivy`, `gitleaks` and
`markdownlint`. Their example manifests are deliberately insecure demonstrations and their READMEs
are not this project's prose.

`kubeconform` needs `-schema-location` flags for the CRDs the platform charts render.
`infra/cluster/platform/kubeconform-schemas.txt` holds them, one per line, blank lines and
`#`-comments ignored, and the order in that file is the order kubeconform tries them in.
`KUBECONFORM_SCHEMA_LOCATIONS`, a space-separated list of the same, overrides the file. With neither
present the run falls back to `-ignore-missing-schemas`, which validates the built-in objects and
skips every custom resource, and it says so loudly rather than failing: a missing file degrades the
check, it does not break the build. With the file present the charts' custom resources are validated
against real schemas and `kubeconform` reports `Skipped: 0`, which is the number to look for.

The `gitleaks` invocation is `gitleaks dir`, not `gitleaks detect --no-git -s`. Both scan a working
tree at the pinned 8.30.1, but `detect` is a compatibility alias upstream intends to drop at v9.
`lint.sh`, `wiki-sync.sh` and `.github/workflows/ci.yml` all use the `dir` form and the same config,
so none of them can disagree about what counts as a finding.

The pre-commit rule exists because `.pre-commit-config.yaml` describes a hook and does not install
one. A review found this repository carrying a fully specified config, gitleaks pinned, the
`pass_filenames` bug in the upstream `gitleaks-system` hook worked around, next to a `.git/hooks`
holding nothing but the sample files git ships. Every commit made up to that point was scanned by
nothing, and the config read like a control while being none. The check looks at the file — it
exists, it is executable, it mentions pre-commit, and `core.hooksPath` has not been pointed somewhere
else — and prints the one command that fixes it. It runs no git command and installs nothing itself,
because installing a commit hook changes how the author's own working copy behaves. Under `CI` it is
skipped: there are no local commits there and the same gitleaks scan runs as its own step.

The condition-key rule exists because `guard-drill.sh` keeps a table of the condition keys the operator
boundary and permissions policy read, so that a simulator case which leaves one unresolved can name
the statement responsible. That table is a copy of something in `infra/guardrails/iam_operator.tf`,
and a copy goes stale. Lint re-derives the list from that file on every run. Finding out that the
boundary grew a key costs nothing here; finding out inside window 0, from a case that fails for the
wrong reason with a kill timer counting down, costs the window.

### test.sh and test/

The kind-based integration suite. `test.sh` finds a container runtime, builds the cluster and calls
`test/suite.sh`, which knows nothing about how its cluster came to exist and can therefore be
pointed at any cluster with a working kubectl context.

`test.sh` exports `KUBECONFIG=test/.kube/config` before it touches kind. Both `kind create cluster`
and `kind export kubeconfig` write a cluster, a context and a client certificate into that file, and
into the home directory's kubeconfig when the variable is unset, which is the same class of problem
as tflint defaulting to `~/.tflint.d` and gets the same treatment. The file is gitignored by
`test/.gitignore`, allowlisted in `gitleaks.toml`, and deleted when the script tears its own cluster
down. `LLM_EKS_KUBECONFIG` overrides it for someone who means to. `mise run lint` has a house rule
that fails when a script runs kind or kubectl without exporting `KUBECONFIG` first; `test/suite.sh`
is its one exception, because it creates nothing and being pointable at a cluster the reader already
has is the reason it is a separate file.

On this host `docker` is a podman shim and kind is not yet proven here. The script detects that,
reports the runtime's actual error, and refuses rather than pretending. See `test/README.md` and ADR
0056.

### bench.sh and bench/

k6 load profiles at concurrency 1, 8 and 32 against the OpenAI-compatible endpoint. Requires
`BENCH_BASE_URL` and `BENCH_MODEL`; there is no default endpoint. See `bench/README.md`.

### demo.sh

Records `scripts/demo.tape` with vhs. The tape shows `mise tasks` and `mise run lint` and nothing
that touches AWS, for two reasons: it would fail on a machine with no credentials, and on a machine
with them it would put an account id into a picture destined for a public README.

### screenshot.sh

Renders a Grafana dashboard to PNG through the image renderer, with a service account token. It
refuses to write anywhere inside `repo/` or a `wiki/` clone: a render goes to
`materials/screenshots/<phase>/` first, gets checked for account identifiers, and is copied across
only after the author has looked at it. It prints the shot list row to add afterwards.

### wiki-sync.sh

Publishes `docs/` into the wiki clone. Targets `master`, which is what GitHub wikis serve; pushing
`main` creates a branch nobody reads and leaves the wiki showing the previous content.

Three gates run before anything is copied. Two cannot be overridden: the authorship grep and
`gitleaks` over `docs/`, which is a hard failure both when it finds something and when `gitleaks`
is not on `PATH` — a gate that vanishes with its tool is not a gate. The third is a warning on any
twelve-digit number, and that one is acknowledgeable with `WIKI_SYNC_ALLOW_ACCOUNT_ID=1`, because
the state bucket's name legitimately contains the account id.

By default it copies, stages and shows the diff, then stops. `WIKI_SYNC_COMMIT=1` commits and
`WIKI_SYNC_PUSH=1` pushes. Sync should not mean publish by accident.

## rates.json

The single place an hourly price lives. Every figure ships as `null` with a `source_url` and a
`sourced_on` beside it, and `mise run up` refuses to open a window while any of them is null. Filling
them in is pricing work someone has to do; nothing here invents a number. ADR 0055.

Each line carries two counts. `quantity` is the steady state; `max_quantity` is the ceiling the
stack itself permits, and every one of them names in `ceiling_source` the variable in this
repository that enforces it. Those are structural rather than priced, so they are filled in. The GPU
line is the one where they differ and it is the expensive one, which is why `mise run up` puts the
ceiling figure in the confirmation prompt.

There is deliberately no load balancer line. Every Service in this repository is ClusterIP, no AWS
Load Balancer Controller is installed, and nothing in any of the three stacks creates one, so
pricing it would put a resource in the estimate that cannot exist. There is a
`public_ipv4_address` line, because the NAT gateway's Elastic IP carries an hourly charge of its own
that is separate from the NAT gateway's.

## Conventions

Every script starts `#!/usr/bin/env bash` and `set -euo pipefail`, sources `lib/common.sh`, is clean
under `shellcheck -x` at default severity, and is safe to run twice. Failure messages say what to do
next, not only what went wrong.

Em-dashes appear in comments and in program output here, and that is a decision rather than an
oversight. The no-em-dash rule is a rule about published prose: the README, the wiki, the ADRs and
the blog drafts, which is where a punctuation tell matters. A terminal banner is not published
prose, the tree already uses them throughout its comments, and a partial cleanup would read worse
than either consistent choice. If the rule is ever extended to program output it should be extended
to comments in the same pass, mechanically, and not one file at a time.
