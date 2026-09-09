# infra/guardrails

The money-safety stack. It is the first thing applied to the account and the last thing destroyed, and it
is the only stack in this repository whose failure mode is a bill rather than a broken cluster.

Everything else in the project assumes this stack exists. The operator role that every other apply runs
as is created here, carrying a permission boundary that this stack also creates. Destroy this stack and
the operator stops existing; destroy it too early and the sweeper that terminates forgotten instances
stops running.

## What is in it

The operator role `llm-eks-operator` and its permission boundary `llm-eks-operator-boundary`. A monthly
budget on gross spend with credits excluded, with notifications and an automatic action. A Cost Anomaly
Detection monitor and a daily email subscription. Two CloudWatch alarms on `AWS/Billing EstimatedCharges`,
one on the month-to-date total and one on the change in it. A kill Lambda, `llm-eks-kill`, that stops
project compute and deletes the project's hourly resources. An always-on sweeper schedule that invokes
it, with a dead-letter queue, `llm-eks-kill-dlq`, and four alarms on whether the kill path still works. A
schedule group, `llm-eks-windows`, that holds the one-shot window timers, plus the execution role those
timers need. Two SNS topics: `llm-eks-alerts`, where every message means stop spending now, and
`llm-eks-notices`, which is email only and carries the alarms that say the kill path itself is broken.
Service-quota targets and the stack's own window limits, published to SSM as data.

## How it is applied

With the administrator profile, by hand, in cloud window 0, and never any other way.

```console
mise run auth admin
cd infra/guardrails
terraform init
terraform plan  -var 'alert_email=...'
terraform apply -var 'alert_email=...'
```

The email and phone number are variables with empty defaults, so no address and no number is ever
written into the repository. The email subscriptions have to be confirmed out of band: the address gets a
confirmation link, and an unconfirmed subscription delivers nothing.

SMS needs more than that and it needs it before the apply. A new account is in the SNS SMS sandbox, where
a message reaches only destination numbers that have been added and verified. An SMS subscription is
created with a real ARN and no confirmation handshake, so an unverified number produces a subscription
that reads as confirmed everywhere except the phone that was supposed to ring. So `alert_phone` is gated
on a second variable: verify the number first with

```console
aws sns create-sms-sandbox-phone-number --phone-number '+...'
aws sns verify-sms-sandbox-phone-number --phone-number '+...' --one-time-password '<code>'
aws sns list-sms-sandbox-phone-numbers
```

and then pass `-var 'alert_sms_sandbox_verified=true'` alongside the number. Supplying a number without
that acknowledgement fails the plan rather than building an alerting path that silently delivers nothing.
Leaving `alert_phone` empty is the clean way to say that email is the only path.
<https://docs.aws.amazon.com/sns/latest/dg/sns-sms-sandbox.html>

`alert_email` is required and the plan fails with an explanation if it is missing. The budget's
informational notifications are delivered to it directly rather than through the alert topic, for the
reason in the two-paths section below, so an empty value would drop that whole tier silently.

State is local. That is deliberate and is recorded in `docs/adr/0010-guardrails-local-state.md`: the
bucket that would hold remote state is created by the bootstrap stack, which is applied as the operator,
which is created here. A remote backend would be a cycle. The state file is snapshotted to
`materials/guardrails/` after every apply, which is a script concern rather than a Terraform one.

Destroying it is the last step of the final window, after the final audit is clean, again with the
administrator profile. `alert_email` is required on the destroy too, because the budget and the anomaly
subscription assert on it:

```console
terraform destroy -var 'alert_email=...'
```

Pass the same `-var` values the apply used, including `alert_phone` and
`alert_sms_sandbox_verified` if SMS was ever turned on.

Comment the admin profile block back out afterwards and confirm that
`aws sts get-caller-identity --profile llm-eks-admin` fails.

## Which control stops which failure

| Failure | What stops it | Where |
| --- | --- | --- |
| A GPU node launched on-demand instead of Spot | Boundary denies `RunInstances` when the type is a GPU type and `ec2:InstanceMarketType` is not `spot` | `iam_operator.tf`, `GpuSpotOnly` |
| An instance type nobody costed | Boundary denies `RunInstances` and `CreateFleet` for any type outside the whitelist | `InstanceTypeWhitelist` |
| A launch through an API the whitelist cannot filter | Boundary denies `RequestSpotInstances` and `RequestSpotFleet` outright | `NoUnfilterableLaunchPath` |
| An instance the sweeper cannot see | Boundary denies a launch that does not carry the `Project` tag | `InstancesMustCarryProjectTag` |
| A small instance resized into a large one | Boundary denies `ModifyInstanceAttribute` and `ModifyInstancePlacement` outright | `NoResizeOrRelocate` |
| Reserved capacity, Savings Plans, Dedicated Hosts | Boundary denies the purchase and allocation calls | `NoCommittedOrReservedSpend` |
| Resources created in a region nobody watches | Boundary denies every regional call outside the configured region | `RegionLock` |
| The operator quietly widening its own limits | Boundary denies every IAM write against the boundary, the operator role, the admin role and the base user | `NoGuardrailIamWrites` |
| The operator creating a fresh role with no boundary and assuming it | Boundary denies `CreateRole` unless the new role carries this same boundary | `NewRolesMustCarryThisBoundary` |
| A new IAM user or a long-lived access key | Boundary denies user, key and login-profile creation | `NoIdentityCreation` |
| The account being upgraded to a paid plan | Boundary denies `freetier:UpgradeAccountPlan` | `NoFreeTierPlanUpgrade` |
| Credits expiring because the account joined an organization | The boundary's Allow ceiling grants only `organizations:DescribeOrganization`, and the denies policy closes the Organizations write surface, Control Tower and IAM Identity Center explicitly | `NoOrganizationsControlTowerOrIdentityCenter` |
| The safety net being switched off | Boundary denies writes against the kill Lambda, the sweeper, the window group, both SNS topics, the kill dead-letter queue and every `llm-eks-` alarm | `NoSafetyNetTampering`, `NoKillPathTampering` |
| A teardown triggered by anyone who can reach the account | Boundary denies the operator `sns:Publish` on the alert topic, and the topic policy no longer grants `SNS:Publish` to account principals at all. Publishing there invokes the kill Lambda, so a publish is a teardown | `NoSafetyNetTampering`, `sns.tf` |
| The failure-detection layer being deleted while everything still reports green | The notices topic, the dead-letter queue and the four kill-path alarms are named in the same deny as the spend alarms | `NoSafetyNetTampering` |
| A session that ends badly and leaves a node running | Sweeper schedule scales the node groups to zero and terminates every project-tagged instance once one of them has outlived the longest window the protocol allows, whether or not a window is open | `schedules.tf`, `lambda/handler.py` |
| A window that runs past its approved hours | One-shot timer in the `llm-eks-windows` group, armed by `mise run up` at now plus `WINDOW_HOURS`, which runs a full stop | created at window time |
| An Auto Scaling group or Karpenter replacing what was just terminated | Every node group is scaled to zero before anything is terminated, which also removes the only nodes the Karpenter controller can run on | `lambda/handler.py` |
| The control plane, NAT gateway, load balancer and public IPv4 hours, which bill with no instance running | A full stop deletes the node groups, the load balancers in the project VPCs, the NAT gateways and the cluster, and releases the Elastic IPs | `lambda/handler.py` |
| An hourly resource left behind after everything else is gone | The sweeper escalates to a full stop when it finds one with no instances running, no window timer pending and more than `orphan_grace_minutes` on the clock | `lambda/handler.py` |
| The kill path being broken while every indicator stays green | Dead-letter queue on the scheduler target, alarms on the function's errors, throttles and silence, and on the queue being non-empty, all delivered to the notices topic | `schedules.tf`, `lambda.tf` |
| Spend creeping up over a month | Budget notifications at each configured percentage, emailed to the human and deliberately not sent to the alert topic | `budgets.tf` |
| Spend that has already gone too far | Budget action attaches a policy that denies everything except the teardown path, and the alert also invokes the kill Lambda | `budgets.tf`, `lambda.tf` |
| A step change on one service inside a day | Cost Anomaly Detection monitor, daily email digest | `anomaly.tf` |
| Gross spend crossing a line at some point this month | Cumulative CloudWatch alarm on the account total, ALARM state only, once per calendar month | `billing_alarm.tf` |
| Gross spend running away right now | Burn-rate alarm on `DIFF` of the same metric, which can fire as often as it needs to | `billing_alarm.tf` |

## The four policy documents

The role carries four policy documents, not two, and the reason there are four is a different reason in
each case. Naming only the boundary and the permissions policy is the mistake this section exists to
stop, because the two that get left out are the two that do the stopping.

| Document | Kind | What it stops | Where |
| --- | --- | --- | --- |
| `llm-eks-operator-permissions` | Managed policy attached to the role | Nothing. It only grants. Without it the role can do nothing at all, because a boundary subtracts and never adds | `iam_operator.tf` |
| `llm-eks-operator-boundary` | The role's permission boundary | Every failure that a role the operator creates could otherwise reach: an on-demand GPU node, an instance type nobody costed, a launch with no `Project` tag, an untagged resize, a fresh role with no boundary, a deleted alarm or topic | `iam_operator.tf` |
| `llm-eks-operator-denies` | Second managed policy attached to the role | The failures only the operator itself can cause, on services outside the boundary's Allow ceiling: joining an organization, upgrading off the Free Plan, editing a budget or a quota, buying a Savings Plan, deleting the kill Lambda or the sweeper, creating an oversized EBS volume | `iam_operator.tf` |
| `llm-eks-budget-stop` | Managed policy, attached to the role by the budget action, detachable only by the administrator | An account that keeps growing after gross spend has crossed the action threshold. It is a `Deny` with a `NotAction` allow-list, so what survives it is the teardown, the audit and the pre-flight reads | `budgets.tf` |

The effective permission set is the intersection of what the permissions policy allows and what the
boundary does not take away, and an explicit `Deny` in any of them wins over any `Allow`.

That is why the boundary opens with a wide Allow across a list of services and then spends most of its
length on `Deny` statements. The Allow is a ceiling, not a grant: nothing happens because the boundary
allows it, only because the permissions policy allows it and the boundary does not take it away. Reading
the boundary top to bottom, only the `Deny` statements are load bearing.

### Which document a new `Deny` belongs in

The sorting criterion is one sentence: the boundary binds the operator and every role the operator
creates, the denies policy binds only the operator.

`NewRolesMustCarryThisBoundary` is what makes the first half true. The operator cannot create an IAM role
without attaching this same boundary to it, so the EKS cluster role, the Karpenter controller role, the
Karpenter node role and every Pod Identity role are all inside it. Those roles carry real permissions:
`AmazonEKSClusterPolicy` on the cluster role, `ec2:CreateFleet`, `ec2:RunInstances` and `ec2:CreateTags`
on the controller. A `Deny` that has to reach them has to be in the boundary.

The denies policy is attached to the operator role and to nothing else. A statement belongs there when
the action is outside the boundary's Allow ceiling to begin with, which makes it an implicit deny for the
operator and for every role the operator creates already. Writing it out anyway means that widening the
ceiling later cannot hand it back by accident.

Two worked examples, because the criterion is easier to apply than to state.

`sns:DeleteTopic` on the notices topic is in the boundary. `sns:*` is inside the ceiling, so the operator
could create a role, grant it `sns:DeleteTopic`, assume it, and delete the topic that carries every "the
kill path is broken" alarm. Only the boundary follows the operator into that new role.

`lambda:DeleteFunction` on the kill Lambda is in the denies policy. The ceiling grants `lambda:Get*` and
`lambda:List*` and nothing else, so no role the operator can create is able to reach a Lambda write in
the first place. The explicit deny is a second lock on a door that is already shut, which is worth having
and is not worth boundary characters.

Getting this backwards has a cost either way. A statement that belongs in the boundary and sits in the
denies policy is a hole. A statement that belongs in the denies policy and sits in the boundary spends
characters from the tightest budget in the stack for no security.

### The 6,144 character limit is why there are two managed policies and not one

A permission boundary has to be a customer managed policy, and a customer managed policy is capped at
6,144 characters with whitespace excluded. Nothing in the local quality bar measures that: `fmt`,
`validate`, `tflint` and `trivy` all pass on an oversized document and the only thing that objects is the
apply, with `LimitExceeded`. So all four policy resources assert their own rendered size in a
`precondition`, which fails during `terraform plan`. Every ARN they refer to is built from the account ID
and the partition in `main.tf` rather than read back off the resource it names, which is what keeps the
rendered documents known at plan time and the assertions meaningful before the window opens.

That limit is why the denies policy exists at all. The boundary ran out of room, and the statements that
moved out are the ones the sorting criterion says only have to bind the operator: the Organizations,
Control Tower and Identity Center surface, budget writes, Service Quotas writes, Cost Anomaly Detection
writes, the Free Tier plan upgrade, the Savings Plan purchase, the kill Lambda and sweeper writes, and
the three EBS volume bounds. If the ceiling in the boundary ever grows to include one of those services,
the matching statement has to move back.

### Two things the plan checks rather than trusts

`NoSafetyNetTampering` names the alarms of the safety net with one wildcard rather than one ARN each,
because naming them individually does not fit inside the boundary's character budget. A wildcard that
stops matching after a rename fails in the direction that looks fine: `guard-status` still reports the
alarm present, and nothing says the deny no longer reaches it. So a `precondition` on the boundary
matches the pattern against every alarm name in `local.limits`, which is the same list `guard-status`
reads out of SSM.

The budget stop policy has the same shape of risk one service wider. It is a `NotAction` allow-list, and
it has been short by a whole service twice, both times found by reading the list rather than by checking
it. So `budgets.tf` now also carries `local.teardown_api_calls`: the API
operations that `terraform destroy` of the cluster stack, `mise run audit`, `mise run guard-status` and
the Terraform state backend actually issue, grouped by the resource that issues them. A `precondition`
fails the plan, naming the calls, for anything on that list the policy would deny. A missing entry is now
a plan that stops rather than a cluster that bills and cannot be destroyed.

The check runs in one direction only. Everything on the call list must be covered; a `NotAction` entry
that cannot create a billable resource is allowed to stay. That is the direction the damage runs in.

### One action is deliberately outside the ceiling, and it breaks a pinned module

The Karpenter submodule at 21.25.0 renders an `AllowZonalShiftReadActions` statement on its controller
policy granting `arc-zonal-shift:GetManagedResource`. The controller role carries this boundary,
`arc-zonal-shift` is not in the ceiling, and the intersection of the two is empty, so the action resolves
to an implicit deny.

That is deliberate. Karpenter's own documentation makes the permission useful only alongside the other
half of the feature: it requires the permission and the EKS cluster to be enabled for zonal shift. This
cluster is not. `eks.tf` passes no `zonal_shift_config`, the module gates the block on that variable
being non-null, and ADR 0034 pins the zones by GPU offering behind a single NAT gateway. The action is a
read, so an implicit deny on it cannot fail a launch, an apply or a teardown; it can only log
`AccessDenied` in the controller. The boundary has very little room left, and admitting a read for a
feature that is switched off is not what the remainder is for. If zonal shift is ever enabled on the
cluster, the action goes into `BuildSurface` and the size precondition gets re-checked. ADR 0012 records
it.

### Two details that are easy to get wrong

The launch conditions are attached to the instance resource ARN. `ec2:InstanceType` and
`ec2:InstanceMarketType` are evaluated against the `instance` resource type in a `RunInstances`
statement, so a condition placed on the image, subnet or security-group ARN in the same statement is
silently ignored and the deny never fires. Every launch deny in this stack is scoped to
`arn:aws:ec2:*:*:instance/*` for that reason.

The whitelist is written as a deny of everything outside it rather than an allow of the list. That
matters because `StringNotEquals` evaluates to true when the key is absent, so a request that carries no
instance type at all is refused rather than permitted. Failing closed is the whole point.

## The three launch APIs, and where the whitelist reaches

EC2 has three ways to start an instance and the whitelist does not reach all of them equally.

`ec2:RunInstances` is the managed node group's path. Both `ec2:InstanceType` and
`ec2:InstanceMarketType` are available on its `instance` resource type, so this is the one path where
the whitelist and the Spot-only rule for GPU types both apply.

`ec2:CreateFleet` is Karpenter's path. It supports `ec2:InstanceType` on the instance resource type but
not `ec2:InstanceMarketType`, so the instance-type whitelist covers it and the Spot-only rule does not. I
have not found a documented condition key that expresses "Spot only" for `CreateFleet`, and I am not
going to invent one. What covers the gap instead: the Karpenter NodePool pins the GPU capacity type to
Spot in the cluster stack, the on-demand G quota stays at its default of zero so an on-demand GPU launch
has no headroom to succeed in, the sweeper terminates anything that outlives its age, and the one-shot
window timer terminates everything at the end of the window. Four partial controls rather than one
complete one, written down here rather than papered over, and the first thing to re-check if AWS adds the
key.

`ec2:RequestSpotInstances` is the legacy Spot API and it cannot be filtered at all. Its authorization row
has no `instance` resource type and `ec2:InstanceType` does not appear in it anywhere, so no condition
can express the whitelist for it, and scoping to `spot-instances-request` would not help either because
that resource is not evaluated when the request carries no tags on create. Nothing in this project needs
it, so it is denied outright in `NoUnfilterableLaunchPath` along with `ec2:RequestSpotFleet`. Without that
deny the whole whitelist was one API call wide open: `ec2:*` sits in the Allow ceiling, and any type with
non-zero Spot quota would have launched straight past it.

## The `Project` tag is a cross-stack requirement

`InstancesMustCarryProjectTag` denies any launch that does not tag the instance `Project` with the
project tag value. The sweeper and `mise run audit` both select on that tag, so an untagged instance is
invisible to both. An invisible running GPU node is a worse outcome than a launch that fails loudly.

This means the cluster stack has to set the tag on the instances Karpenter creates, in the EC2NodeClass,
not only in the Terraform provider's `default_tags`, which does not reach launches made by a controller
inside the cluster. If a node launch fails with an authorization error during window 1, this is the first
thing to check. `mise run guard-drill` exercises the launch matrix with `--dry-run` before a window opens
so the failure shows up locally rather than during a paid hour. The check can be turned off with
`-var 'enforce_instance_project_tag=false'`, which is an administrator action and should be recorded.

## Quotas

The targets live in `var.quota_targets`, keyed by a short identifier and carrying the quota **name**.
No `L-` code appears in this stack or in any script that reads it. Phase 0 established that the codes are
undocumented and have to be discovered at run time, and that the call to discover them is
`list-aws-default-service-quotas` rather than `list-service-quotas`, because the latter omits quotas that
have no applied value, which is exactly the state of every accelerator quota on a fresh account.

Terraform publishes the map to SSM at `/llm-eks/guardrails/quota-targets` and does not request anything.
A quota increase is a support ticket with a lead time, not a resource that converges on apply. The
request path is: read the target out of SSM, resolve the name to its code with
`aws service-quotas list-aws-default-service-quotas --service-code ec2`, raise the request with
`aws service-quotas request-service-quota-increase` under the administrator profile in window 0, and
record the request ID and its status in `materials/guardrails/`. The operator cannot do any of this: the
boundary denies the Service Quotas write surface.

Only one quota needs raising: `All G and VT Spot Instance Requests`, from its default of 0 to 8. Every
other entry in the map records a documented default that must still be in force, which is what makes an
accidental launch of an accelerator family fail twice, once at the boundary and once at the quota. Eight
of those defaults are zero. The two Standard entries are five, not zero, because five is what AWS ships:
`All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests` and
`Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances` both default to 5 vCPUs, and the
system node group needs 4 of them, two nodes at 2 vCPUs each. So the targets for those two are 5 and no
request is raised for either.

## Credits, and the thing this stack assumes

Every threshold here is on gross spend with credits excluded. `include_credit` and `include_refund` are
both false on the budget's cost types, which is how AWS expresses "count what the usage would have cost".
The account holds Free Tier credits and the project treats credits as cash, so a budget that netted them
off would read zero until the moment the credits ran out and then read the truth far too late.

Whether AWS Budgets actually observes gross pre-credit usage on a Free Plan account is an open question,
recorded in `materials/journal/STATE.md`. Until it is answered by comparing `Budget.CalculatedSpend`
against `ce get-cost-and-usage` with `UnblendedCost`, the budget is a second opinion and the sweeper and
the one-shot timer are the controls that actually stop spend. Any worst-case arithmetic should be written
against those two.

The automatic budget action attaches a policy to the operator role. It does not use `APPLY_SCP_POLICY`,
which needs an organization, and this account must never join one. It does not use `RUN_SSM_DOCUMENTS`
either, which can only stop named EC2 and RDS instance IDs that were known when the action was written.
`APPLY_IAM_POLICY` takes a policy ARN and a list of roles, users or groups; this one names the operator
role and nothing else. Only the administrator can take it back off: the boundary denies the operator
`iam:DetachRolePolicy` against its own role.

That policy is a `Deny` with `NotAction`, and the shape matters more than it looks. It used to be `Deny`
on `Action "*"`, which was the worst possible failure mode. The things that grow the account at that
point are an Auto Scaling group, the EKS control plane and the Karpenter controller role, and none of
them is the operator, so a blanket deny stopped none of them. What it did stop was the only identity that
can run `terraform destroy`, `mise run down` and `mise run audit`, because it covered the reads too. The
answer to a spending problem was a spending problem that could not be fixed without uncommenting the
admin profile.

So the deny now excludes the teardown path: `sts`, the state bucket, `scheduler`, and `Describe`, `List`,
`Get` and `Delete` across the services the cluster stack creates, plus the reads `guard-status` and the
cost review need. Everything that creates is on the denied side, including `RunInstances`, `CreateFleet`,
`CreateVolume`, `CreateCluster`, `CreateNodegroup`, `CreateRole` and `PassRole`, so the account cannot
grow while it is attached. If a destroy ever fails with an authorization error while the policy is on,
the missing action goes into that list and the reason goes in the journal.

## Two topics, because a trigger is not a mailing list

The kill Lambda is subscribed to `llm-eks-alerts`, so the handler reads any SNS envelope arriving there as
stop everything now. That makes the topic a trigger, and it decides what is allowed to publish to it.

Three things do, and all three mean stop spending: the budget action at `budget_action_threshold_usd`, the
cumulative billing alarm when it enters ALARM, and the burn-rate alarm. Everything informational goes to
the email address directly and never touches the topic: the budget's percentage notifications, its
forecast notification, and the Cost Anomaly Detection digest.

Three versions of this file got that wrong in three different ways, and every one of them would have cost
a paid window. The budget's percentage notifications published to the topic, so with the default limit of
100 dollars and the default first threshold of 25 percent, gross spend crossing 25 dollars would have torn
down a running cluster while the action at 120 dollars sat untouched. The billing alarm had an
`ok_actions` on the same topic, which fires on the transition to OK: on a fresh account the metric does
not exist yet, the alarm sits in `INSUFFICIENT_DATA`, and the first datapoint under the threshold moves it
to OK a few hours into the first window with a GPU node running, so the guardrail would have killed the
thing it was guarding because spend was fine. And the anomaly subscription published to the topic
immediately at ten dollars of impact, which on an account whose baseline is zero is what one intended GPU
afternoon looks like: the first real benchmark would have been the anomaly that tore itself down.

The rule that follows: nothing gets a subscriber on `llm-eks-alerts` unless a message from it should end
the window. If a new informational alert is wanted, it goes to the email address, or the handler learns to
read the message body first.

`llm-eks-notices` exists because of the other direction. The alarms that watch the kill path cannot report
into the topic that invokes the kill path: answering "the teardown failed" by running the teardown again
is not a control, it is a loop. So the notices topic has one email subscriber and no Lambda, and it
carries the kill function's errors and throttles, the sweeper going silent, and the dead-letter queue
being non-empty. It lives in `var.region` with the Lambda, the queue and those alarms, because a
CloudWatch alarm can only notify a topic in its own region.

## Regions

Cost Explorer and the `AWS/Billing` metric namespace only exist in us-east-1. Billing metric data is
stored there and represents worldwide charges, and the Cost Explorer API has a single endpoint at
`ce.us-east-1.amazonaws.com`. AWS Budgets is not in that group: it is a global service reached at
`budgets.amazonaws.com` rather than a regional endpoint. So the stack configures two providers, the
default one on `var.region` and an aliased one pinned to us-east-1, and the aliased one owns the budget,
the budget action, the anomaly monitor, the billing alarm and the alert topic. The billing alarm has to
be there. The topic has to be there because a CloudWatch alarm can only notify a topic in its own region.
The budget and its action are there only to stay next to the two, not because Budgets requires it, which
matters if the region ever flips: those two can move, the alarm and the topic cannot.

The kill Lambda, the sweeper, the window schedule group, the dead-letter queue, the notices topic and the
four kill-path alarms are in `var.region`, because that is where the instances are. The Lambda itself
works across every region in `local.allowed_regions`, which is `var.region` plus us-east-1, so it can
terminate an instance that a mis-set `AWS_REGION` put in the wrong one. While `var.region` is us-east-1
this distinction is invisible. If the region ever flips, re-check the cross-region subscription from the
alert topic to the Lambda before relying on it.

The billing metric only appears once charges accrue, and AWS publishes it on a several-hour cadence. A
fresh account will show the alarm in `INSUFFICIENT_DATA` for a while. The alarm is not armed until
`aws cloudwatch list-metrics --namespace AWS/Billing` returns something.

## The kill Lambda

One function, three modes, in `lambda/handler.py`. The first version of it terminated instances and
nothing else, and that was the worst defect in this repository: an EKS managed node group replaces what it
loses within minutes, Karpenter re-provisions a GPU node for a pod that is still pending, and the control
plane, the NAT gateway and its public IPv4 address bill by the hour whether or not any instance exists. A
fired timer looked decisive and was undone in about ninety seconds, and the two charges that run all night
were never in the kill path at all.

### The order, and why it is that order

1. **Scale every managed node group of the project cluster to zero.** `minSize` and `desiredSize` go to 0
   and `maxSize` is left alone, because the API requires it to be at least 1 and it is the ceiling rather
   than the thing that is running. This is first because it is what stops the Auto Scaling group putting
   the nodes back, and because the Karpenter controller lives on those nodes: take them away and there is
   nowhere left for the thing that would launch a replacement GPU node to run. That last part is a
   property of the platform layer rather than an assumption:
   `infra/cluster/platform/values/karpenter.yaml` pins the controller to the managed node group with a
   `nodeSelector`, so it cannot move onto a node it provisioned itself. Deleting a NodePool would be the
   other way to stop Karpenter, and this function cannot do it: that is a Kubernetes API call, and a
   Lambda with no cluster credentials and no route to a private endpoint has no way to make one.
2. **In a full stop, delete those node groups.** Not because the instances need deleting twice, but
   because `DeleteCluster` refuses while a managed node group exists.
3. **Terminate every project-tagged instance,** one call per instance so that a single un-terminatable
   instance cannot fail the whole batch. By this point nothing is watching for them to disappear.
4. **In a full stop, delete the charges that do not care whether an instance exists:** the load balancers
   in the project VPCs, the NAT gateways, the cluster, and then the unassociated Elastic IPs.

Load balancers are selected by VPC, not by tag. A load balancer created by a Kubernetes `Service` carries
the `kubernetes.io` tags and never `Project`, so a tag filter would miss the one case where a load
balancer appears without anybody writing Terraform for it. Both generations are checked, because a
`type: LoadBalancer` Service with no controller and no annotation produces a classic ELB that the v2 API
cannot see.

Two things are deliberately **not** deleted. EBS volumes, because a volume is somebody's data and Rule 2
is outranked by not destroying the author's data; the node root volumes go with their instances anyway,
and a stray unattached volume is a per-GB-month charge that the audit reports and a person deletes. And
the VPC, its subnets, route tables, security groups and internet gateway, because none of them costs
anything once the NAT gateway is gone, and unpicking a VPC's dependency order unattended is how a Lambda
leaves a half-deleted network nobody can reason about.

### Which mode does how much

`sweep` is what the always-on schedule sends every `sweeper_interval_minutes`. It does steps 1 and 3 when
it finds a project-tagged instance that has outlived `sweeper_max_age_minutes`, and it terminates
everything project-tagged rather than only the aged ones: that age is longer than the longest window the
approval form can grant, so an instance older than it means no window is legitimately open, and leaving
the young ones would keep a GPU node that Karpenter replaced late in the window running for hours after
everything around it had stopped.

`sweep` also escalates to a full stop, and that is what makes the whole thing converge. Deleting a node
group takes minutes, and the cluster cannot be deleted until it has finished, so the pass that fires the
timer normally leaves the cluster behind with a `ResourceInUseException`. The sweeper picks it up on the
next run, because by then the cluster is an hourly resource with no project-tagged instances running, no
window timer pending, and more than `orphan_grace_minutes` on its own clock. All three conditions have to
hold. A cluster is legitimately node-less for the first ten minutes or so of an apply, and a window in
which a node group launch is being debugged can be node-less for a lot longer than that, which is why the
window timer's fire time is the real guard: the sweeper reads the schedules in `llm-eks-windows`, and if
any of them is still in the future, or if anything about that read is unexpected, it assumes a window is
open and collects nothing. Refusing to collect an orphan costs an hour of a control plane. Collecting one
that was still in use costs the author their window.

`kill_all` is what the one-shot window timer sends and what any message arriving through the alert topic is
read as. All four steps, no age test, no window test. `full_stop` is accepted as a name for the same
thing.

`report` describes the full stop it would perform and changes nothing, which is what the drill uses.

The handler does not parse the SNS message body, so it cannot tell one publisher on the topic from
another. That is a deliberate choice and it is why the section above is strict about what may publish
there. The field names in a CloudWatch alarm's SNS payload appear in AWS blog posts but I have not found
them in the reference documentation, and Rule 4 says I do not write a field name I cannot cite. Keeping
the topic clean is the control; parsing the payload would be a second one, available the day the schema is
documented.

### Running twice, running during an apply, running when something is denied

Every step is safe to repeat. A node group already at zero is skipped. A resource that is already gone,
`ResourceNotFoundException` and its cousins, counts as done. A resource that cannot go yet because
something else is still deleting, `ResourceInUseException` on the cluster or `InvalidIPAddress.InUse` on
the NAT gateway's address, is recorded as pending rather than as a failure, which is what stops a normal
teardown from lighting the error alarm every time. Nothing waits, polls or sleeps, so no invocation can
deadlock or hit the timeout holding something open.

Running while a `terraform apply` is in flight is the ugly case and it is a real one: the timer fires on
wall-clock time and does not know what the operator is doing. The apply loses, which is the right way
round, and the state it leaves is whatever Terraform had reached minus what the Lambda deleted. The next
`terraform destroy` refreshes, finds those resources gone and moves on, and `mise run audit` is what
answers whether anything is left. That is also why the handler collects failures instead of raising at the
first one: the pass does everything it can, and only then raises, so a NAT gateway that could not be
deleted cannot prevent the cluster from being deleted.

An error at the end is the point. It is what puts the event on `llm-eks-kill-dlq` after the scheduler's
retries and what raises `llm-eks-kill-errors`, and those two are the only things that can tell the author
the kill path is broken. Without them a sweeper whose `TerminateInstances` has been failing for a week
still reports as healthy, which was true of the previous version of this stack: `guard-status` checked
that the sweeper was configured, not that it had ever worked.

### The role

Every mutating action is scoped to the project's own resource. `TerminateInstances` carries the same tag
condition as before. The node group calls are scoped to `nodegroup/llm-eks/*/*` and `DeleteCluster` to
`cluster/llm-eks`, which is the ARN shape AWS documents for those actions.

Two of them are not scoped, and the reason is worth being honest about rather than hiding. I could not
find a primary statement that `ec2:DeleteNatGateway` and `ec2:ReleaseAddress` support resource-level
permissions, and a condition on a key an action does not support is a deny in disguise: the key would be
absent, `StringEquals` would fail, and the kill path would stop working in the one moment it matters. So
those two are granted account-wide and the handler is what scopes them, because it only ever passes IDs
that came back from a describe filtered on `tag:Project`. That is the one place in this stack where the
code is the boundary rather than IAM. `eks:UpdateNodegroupConfig` is the same class of uncertainty in the
other direction: it is scoped to the nodegroup ARN on the strength of `DeleteNodegroup` and
`DescribeNodegroup` being documented against it, and if it turns out not to support resource-level
permissions the scale call comes back `AccessDenied`, the handler carries on to the node group deletion,
and the error alarm says so. All three belong in the window-0 drill with
`aws iam simulate-principal-policy` before they are trusted.

Reads are granted account-wide where the action's resource-level support is not documented. A read cannot
cost anything, and a read denied by accident breaks the whole control.

An instance whose launch time cannot be read is treated as old and terminated. The cheap mistake is
terminating something young. The expensive one is leaving a GPU node running because a field was missing.

The Lambda works across every region in `local.allowed_regions`, which is the same list the boundary's
`RegionLock` permits. It used to run in one, which meant the second region the boundary deliberately
leaves open, the one a mis-set `AWS_REGION` lands things in, was visible to `mise run audit` and invisible
to both controls that actually terminate anything.

The tests are in `lambda/test_handler.py` and run on the standard library plus `unittest.mock`. Every
client is a stub and the clock is patched, so they need no network and no credentials:

```console
cd infra/guardrails/lambda && python3 -m unittest
```

## Window limits are published, not typed twice

`mise run up` accepted up to eight hours and the sweeper terminated anything older than four. Two numbers
that have to agree, set by hand in two files, disagreed by a factor of two, and the result was that an
approved eight-hour window would have been torn down at its halfway mark by the control that is supposed
to run regardless.

So `max_window_hours` lives here and the sweeper's age is derived from it in `main.tf`:
`max_window_hours * 60 + sweeper_age_margin_minutes`. There is no `sweeper_max_age_minutes` variable to
set. Both numbers, the sweeper interval, the orphan grace, the kill Lambda's region list, the names of the
dead-letter queue and the four kill-path alarms, whether SMS is on, and the semantics of each billing
alarm are published to SSM at `/llm-eks/guardrails/limits`. `mise run up` reads its ceiling from there and
`mise run guard-status` reads the rest, so neither script holds a copy of a number this stack owns.

The billing-alarm semantics are in that parameter for a specific reason. `guard-status` has to tell two
states apart: the cumulative alarm being in ALARM means gross spend crossed the line at some point this
month and will stay there until the month rolls over, which is a warning; the burn-rate alarm being in
ALARM means spend is being added right now, which is a refusal. Treating the first as a refusal blocked
every window for the rest of the calendar month, which is exactly the kind of control that gets edited out
of the way.

## Local checks

```console
terraform fmt -check -recursive infra/guardrails
cd infra/guardrails && terraform init -backend=false && terraform validate
tflint --chdir=infra/guardrails
trivy config infra/guardrails
cd infra/guardrails/lambda && python3 -m unittest
```

A handful of `trivy` findings are accepted deliberately and each carries a scoped ignore with the reason in
the comment directly above the block: the two unencrypted SNS topics, the unencrypted Lambda log group,
X-Ray tracing left off, and the wildcards in the two IAM policy documents in `iam_operator.tf`. The
dead-letter queue is encrypted with the SQS-managed key, which is free and needs no key policy.

`terraform validate` needs no credentials, and it is worth being precise about what a green run does and
does not prove. It confirms that every resource type, argument and expression is real for the pinned
provider. It does not render a policy document and it does not measure one, so it passed happily on a
boundary that was 556 characters over IAM's hard limit and would have failed part-way through the
window-0 apply. The size assertion described above is what catches that, and it needs `terraform plan`
rather than `validate`, because a `precondition` is evaluated during plan.

Nothing in this stack can be verified against the real IAM evaluation engine locally either, which is why
the boundary is drilled with `aws iam simulate-principal-policy` and with `run-instances --dry-run` before
window 0 opens rather than trusted on the strength of a passing lint. The drill matrix has to include
`request-spot-instances --dry-run` as well as `run-instances`, because that path is denied by an
unconditioned statement rather than by the whitelist.

## Costs

No cost figure appears in this document. Nothing here has been applied yet, so there is no measurement to
cite, and Rule 5 says a number in prose has to trace to a file under `materials/`. The per-hour and
per-window figures go in `materials/costs/windows.md` as each window closes, and the summary lands in
`materials/costs/FINAL_REPORT.md`.

Placeholder, to be filled from `materials/guardrails/` and `materials/costs/` after window 0:

| Item | Value | Source |
| --- | --- | --- |
| Cost of running this stack per month | not yet measured | |
| Time from a spend alert to the last instance terminated | not yet measured | |
| Time from a fired timer to the cluster actually being gone | not yet measured | |
| What still bills between the full stop and the sweeper pass that finishes it | not yet measured | |
| Sweeper invocations per day | not yet measured | |
