# 0060. What the first cluster teardown corrected

Date: 2026-11-20

## Status

Accepted. Amends the destroy half of ADR 0059 and the audit from ADR 0052. The permission boundary
finding from the same window is not decided here: it needs an admin apply and gets its own record.

## Context

Window 1 applied all three phases cleanly: 25 resources in bootstrap, 111 in cluster phase 1, 21 in
phase 2, 23 of 23 platform pods running. No GPU node launched, because the boundary denies Karpenter's
dry-run `ec2:CreateFleet` and both EC2NodeClasses stayed at `ValidationSucceeded=False`. So I tore
down early, and the teardown is where it went wrong. It took 2 hours 18 minutes from the first
`mise run down` to `CLOSED`, and ran 27 minutes past the approval.

Five things, in the order they happened:

1. **The NAT gateway went before the platform.** `helm_release.nodepools` timed out with
   `context deadline exceeded`. The EC2NodeClasses carry the `karpenter.k8s.aws/termination`
   finalizer, which only the Karpenter controller removes, and only after it has talked to EC2 and
   IAM. The controller runs in the private subnets. In a single destroy graph nothing orders the NAT
   gateway after the platform, so the NAT was deleted first and every Karpenter call after that
   failed with `exceeded maximum number of attempts`. I removed the finalizers by hand after checking
   that Karpenter had launched no instances and created no launch templates.
2. **The kubeconfig was already gone.** `window-down.sh` removed it right after the destroy, whether
   or not the destroy had succeeded. The cluster was still up and there was nothing local to look at
   it with. I wrote a new one into the checkout.
3. **The second destroy ran as the wrong phase.** `window-down.sh` picked the phase from the
   `platform_enabled` output. After the failed destroy that output was gone, so the script ran
   `-var platform_enabled=false`. The kubernetes and helm providers were configured against
   `https://kubernetes.invalid` (ADR 0037) while two namespaces were still in state, and refresh
   failed. I ran `terraform plan -destroy` with the secret ARN by hand, checked it was 72 deletes and
   nothing else, and applied that plan.
4. **The audit stayed dirty for over 35 minutes with nothing billing.** It listed a security group
   and two ENIs from the Resource Groups Tagging API. EC2 answered `InvalidGroup.NotFound` and
   `InvalidNetworkInterfaceID.NotFound` for all three. `GetResources` is documented to return "all the
   tagged or previously tagged resources", so this is the API working as described. The audit treated
   it as truth.
5. **An `н` read as no.** On the Russian layout `н` is the `y` key. The phase-2 prompt took it as a
   refusal and `mise run up` had to be run again under the armed timer.

Separately, the weights upload log, the plan files and the Grafana password file were written to the
system `/tmp`, outside the workspace.

## Decision

`window-down.sh` reads the phase from `terraform state list`. If anything under `module.platform[` is
in state, the destroy gets the secret ARN; otherwise it runs with `platform_enabled=false`. What is in
state is what the destroy has to reach.

When the platform is in state, `window-down.sh` destroys `-target=module.platform` first, while the NAT
gateway, the cluster and Karpenter's IAM still exist, and only then the whole stack. If the targeted
destroy fails, the full destroy does not run: taking the network out from under a half-removed platform
is how item 1 happened. Inside the module the order was already right, `nodepools` depends on
`karpenter`.

The kubeconfig is removed only when every destroy succeeded.

For an EC2 resource the tagging API reports, the audit asks EC2 with the matching `describe-*` call.
Only an error code of the form `Invalid*.NotFound` makes it a stale entry, reported as a warning and not
counted. Success, `Malformed`, `UnauthorizedOperation`, throttling, or a type outside the table of ten
EC2 resource types all leave it an orphan. A false orphan costs a re-run. A false "gone" costs money.

`confirm()` accepts `н`, `Н` and `нуы` as yes. Anything else is still no.

`scripts/lib/common.sh` sets `TMPDIR` to `../.tmp` beside the checkout, mode `0700`, the same place
the weights cache already lives, or to `LLM_EKS_TMP_DIR`. Every `mktemp` in `scripts/` already used
`${TMPDIR:-/tmp}`, and terraform, helm and the AWS CLI honour it. I first put it inside the checkout
and the next lint run failed: markdownlint and gitleaks scanned the caches other tools had written
there.

## Consequences

A clean teardown runs one more destroy, the targeted one. It costs a refresh of the stack, under a
minute.

`-target` prints Terraform's warning about targeted operations. Here that is intended: it is a fixed
ordering step, followed by an untargeted destroy of the same stack in the same run.

The audit can now pass with warnings. A warning names the ARN and says EC2 answered NotFound, so the
evidence is in the output. EC2 is eventually consistent too, but in the other direction it matters
here: a resource that was just created can briefly read NotFound. The audit runs after the destroy,
when nothing in the project is being created.

The NotFound codes were read from live calls: three on deleted resources in window 1, seven more on
IDs that never existed. `describe-security-groups`, `describe-launch-templates` and
`describe-nat-gateways` answered `Malformed` to the made-up IDs, so for those types only the window-1
evidence covers the real case.

Not fixed here: the boundary and `ec2:CreateFleet`. That is a guardrails change and an admin apply,
after a drill that makes the same dry-run call Karpenter makes.

Sources:

- https://docs.aws.amazon.com/resourcegroupstagging/latest/APIReference/API_GetResources.html
- https://docs.aws.amazon.com/ec2/latest/devguide/errors-overview.html
