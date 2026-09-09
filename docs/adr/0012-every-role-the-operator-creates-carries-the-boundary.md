# 0012. Every role the operator creates must carry the same permission boundary

Status: accepted
Date: 2026-09-08
Revised: 2026-09-09

## Context

A permission boundary limits the identity it is attached to. It does not follow that identity into the
roles it creates.

The operator has to be able to create IAM roles: EKS needs a cluster role and a node role, Karpenter
needs a controller role and an instance profile, and every Pod Identity association needs one. So
`iam:CreateRole` is inside the ceiling.

Which means that without something else, the whole design is one call deep. Create a role with a trust
policy naming the operator, attach `AdministratorAccess` to it, assume it, and every deny in the boundary
is behind you. The boundary limits the operator; it says nothing about the new role.

This is the standard trap with delegated permissions management, and AWS documents the standard answer:
condition the create on `iam:PermissionsBoundary`, so the delegate can only create identities that carry
a boundary the delegate cannot edit.

## Decision

`NewRolesMustCarryThisBoundary` denies `iam:CreateRole` and `iam:PutRolePermissionsBoundary` unless
`iam:PermissionsBoundary` equals the ARN of `llm-eks-operator-boundary`. `StringNotEquals` is true when
the key is absent, so a `CreateRole` call with no boundary at all is denied.

`NoBoundaryRemoval` denies `iam:DeleteRolePermissionsBoundary` and `iam:DeleteUserPermissionsBoundary` on
every resource, so a boundary that has been attached cannot be taken back off.

`NoGuardrailIamWrites` denies every IAM write against a fixed list of ARNs: the boundary policy itself,
the operator role and both policies attached to it, the administrator role, the base user, the
deny-everything policy the budget action uses, and the three service roles in this stack. The ARNs are
constructed from the account ID and the names rather than referenced from the resources, because the role
carries the boundary and the boundary names the role, and referencing both ways would be a cycle in the
graph.

The action list on that statement is nine verb wildcards, `iam:Attach*`, `iam:Create*`, `iam:Delete*`,
`iam:Detach*`, `iam:Put*`, `iam:Set*`, `iam:Tag*`, `iam:Untag*` and `iam:Update*`, rather than the twenty
individual actions it used to enumerate. Scoped to ten named ARNs the wildcards deny strictly more than
the enumeration did, they cost about a third of the characters, and everything the operator legitimately
needs against those ARNs is outside all nine: `iam:PassRole` to the scheduler role, and `iam:Get*` and
`iam:List*` for `guard-status`. `iam:CreateServiceLinkedRole` is outside them too, because a service-linked
role ARN sits under `role/aws-service-role/` and is not in the list.

`NoAdminAssumption` denies `sts:AssumeRole` against the administrator role ARN.

## Decision: three policy documents, and which statement goes where

A permission boundary has to be a customer managed policy, and a customer managed policy is capped at
6,144 characters with whitespace excluded. Closing the gaps found in review pushed the boundary over that,
so the operator role now carries three documents instead of two: the boundary,
`llm-eks-operator-permissions`, which is Allow statements only, and `llm-eks-operator-denies`, a second
attached managed policy. All three assert their own rendered size in a `terraform plan` precondition,
because nothing else in the local quality bar renders or measures a policy body: `fmt`, `validate`,
`tflint` and `trivy` all pass on an oversized document and the failure surfaces at apply time as
`LimitExceeded`, in the middle of the one apply that must not fail.

The split is not by convenience. A Deny belongs in the boundary when a role the operator creates during a
normal build could otherwise reach the action, because the boundary is the only one of the three documents
that reaches those roles. Concretely: the EKS cluster role carries `AmazonEKSClusterPolicy`, the node role
carries `AmazonEKSWorkerNodePolicy` and the CNI policy, and the Karpenter controller role carries
`ec2:RunInstances`, `ec2:CreateFleet` and `ec2:CreateTags`. Anything one of those could do that would
defeat a money control has to be denied in the boundary.

A Deny may move to the attached policy when the action is not inside the boundary's Allow ceiling at all,
because then it is already an implicit deny for the operator and for every role the operator creates, and
the explicit statement is only there so that a later widening of the permissions policy cannot hand it
back by accident. The ceiling grants, outside the wide service-level Allow, only
`organizations:DescribeOrganization`, `budgets:Describe*` and `budgets:View*`, `ce:Describe*`, `ce:Get*`
and `ce:List*`, `servicequotas:Get*` and `servicequotas:List*`, `lambda:Get*` and `lambda:List*`,
`pricing:Get*`, four `freetier` reads, and for `scheduler` the reads plus create and delete on the window
timer's own ARN shape. So the Organizations, Control Tower and Identity Center closure, the budget writes,
the service-quota writes, the Cost Explorer writes, the Free Tier plan upgrade, the Savings Plan purchase
and every `lambda` and `scheduler` write against the safety net sit in `llm-eks-operator-denies`. What
stayed in the boundary from the safety-net statement is the part that names `sns` and `cloudwatch`, because
both of those are inside the ceiling as `sns:*` and `cloudwatch:*`.

The EBS volume bound is the one judgement call in that sorting, and ADR 0011 argues it: it is in the
attached policy because nothing in the normal build calls `ec2:CreateVolume` or `ec2:ModifyVolume` at all,
with the condition under which it has to move into the boundary written down there.

## Decision: the failure-detection layer is protected by the same statement as the spend alarms

A later review round added a second half to the safety net: the `llm-eks-notices` topic, the
`llm-eks-kill-dlq` dead-letter queue, and four alarms on the kill Lambda's errors, its throttles, the
sweeper going silent and the queue being non-empty. That layer exists to say that the kill path itself
has stopped working, and it was named in no Deny at all, so the operator could delete all six with
ordinary permissions and `guard-status` would keep reporting green: nothing in it looks at whether the
alarms it read still exist tomorrow.

They are now in `NoSafetyNetTampering`, in the boundary, and by the criterion above they belong there.
`sns:*`, `sqs:*` and `cloudwatch:*` are all inside the boundary's Allow ceiling, so the operator can
create a role, grant it `sns:DeleteTopic`, assume it and delete the notices topic. Only the boundary
follows the operator into a role it creates.

Three additions to the action list, and the reason for each. `sns:Publish`, because publishing to
`llm-eks-alerts` is a teardown rather than a message: the kill Lambda is subscribed to that topic and
reads any envelope as stop everything now, and the Lambda now scales node groups to zero and deletes the
hourly resources, so one `aws sns publish` from an unprivileged caller is a cluster teardown. The topic
policy in `sns.tf` no longer grants `SNS:Publish` to account principals either; the three publishers that
matter are service principals and are granted in their own statement. `sqs:DeleteQueue` and
`sqs:SetQueueAttributes` on the dead-letter queue, because rewriting the queue policy or the retention
period breaks the queue as thoroughly as deleting it and leaves the ARN in place to be reported healthy.

The alarms are named with one wildcard, `arn:aws:cloudwatch:*:<account>:alarm:llm-eks-*`, and not with
six ARNs, because six ARNs do not fit in what is left of the boundary. The region is a wildcard because
the two billing alarms live in us-east-1 with the metric while the four kill-path alarms live in
`var.region` with the Lambda. The wildcard is checked rather than trusted: a `precondition` on
`aws_iam_policy.operator_boundary` matches the pattern against every alarm name in `local.limits`, which
is the same list `guard-status` reads out of SSM, so a rename that moves an alarm outside the pattern
fails the plan instead of quietly unprotecting it.

## Decision: `arc-zonal-shift` stays outside the ceiling, and one statement of a pinned module goes with it

The `karpenter` submodule at 21.25.0 renders an unconditional `AllowZonalShiftReadActions` statement on
its controller policy granting `arc-zonal-shift:GetManagedResource`, scoped by
`arc-zonal-shift:ResourceIdentifier` to the cluster ARN. The controller role carries this boundary,
`arc-zonal-shift` is not in the ceiling, and the intersection is empty, so the action resolves to an
implicit deny. This is a pinned module losing a permission its own template grants, which is the kind of
thing that should be a decision rather than an accident.

It is a decision, and the decision is to leave it out. Karpenter's documentation states the requirement
as a conjunction: it requires permission to call `arc-zonal-shift:GetManagedResource` and the EKS cluster
must be enabled for zonal shift. This cluster is not. `eks.tf` passes no `zonal_shift_config`, the module
gates the block on that variable being non-null, and ADR 0034 pins the zones by GPU offering behind a
single NAT gateway, so there is no zonal shift for the controller to watch. The action is a read: an
implicit deny on it cannot fail a launch, an apply or a teardown, and the worst case is an `AccessDenied`
line in the controller log.

Against that, the boundary is the tightest character budget in the stack and the same review round needed
the room for the safety-net denies above, which stop something. Admitting a read for a feature that is
switched off is not what that room is for. If zonal shift is ever enabled on the cluster, the action goes
into `BuildSurface`, the size precondition gets re-checked, and this section gets revised.

## Decision: the window timer is constrained rather than denied

The one-shot kill timer is the control that stops a window that outlives the author's attention, and the
operator has to be able to create it and delete it, because `mise run up` and `mise run down` are the two
tasks that do. So it cannot simply be denied. Three narrowings instead.

`WindowTimerLifecycle` grants `scheduler:CreateSchedule`, `scheduler:DeleteSchedule`,
`scheduler:TagResource` and `scheduler:UntagResource` against
`schedule/llm-eks-windows/llm-eks-window-*` rather than against the whole group, so the operator cannot
park a differently named schedule in the group where the audit would not look for it.

`scheduler:UpdateSchedule` is gone from that grant, in both the boundary and the permissions policy, and
is denied explicitly in `llm-eks-operator-denies` against the schedules in that group. Nothing in
`scripts/` calls `update-schedule`, so nothing legitimate loses anything. The point is the difference
between the two ways of defeating the timer: an in-place update can push the fire time to next year and
leave a timer that still exists and still looks armed, while a delete leaves an absence that the audit
path can be made to notice.

The reason this needed fixing rather than documenting is that the previous `NoSafetyNetTampering`
statement denied `scheduler:DeleteSchedule` and `scheduler:UpdateSchedule` against the
`schedule-group/llm-eks-windows` ARN. EventBridge Scheduler defines `schedule` and `schedule-group` as two
separate resource types, `arn:...:schedule/${GroupName}/${ScheduleName}` and
`arn:...:schedule-group/${GroupName}`, and a Deny applies only when both the action and the resource in
the request match the statement. A deny scoped to the group ARN therefore never matched an individual
timer. The new statement names both shapes.

## Consequences

Every role the cluster stack creates inherits this boundary, which means Karpenter's controller role is
also subject to the instance-type whitelist and the region lock. That is a feature, and it is why the
whitelist covers `CreateFleet` as well as `RunInstances`.

It also means a role created by the operator may end up with less permission than its attached policy
suggests, and the symptom will be an authorization failure that the policy does not explain. Anyone
debugging one has to read the boundary too. That is the price of the design, and `mise run guard-drill`
exercises it with `aws iam simulate-principal-policy` so the surprises happen locally.

Splitting the denies across two documents has the same cost in a different place: an authorization failure
now has three policy bodies behind it rather than two, and the deny that caused it may be in either of the
attached ones. The `guard-drill` output is where that has to be legible, and every statement in the new
document should get a simulator case.

## Consequences: the trust policy is the hole this design does not close

`NewRolesMustCarryThisBoundary` controls what a new role may do. It does not control who may assume it,
and I could not find a way to make it.

I read the `iam:CreateRole` row of the IAM authorization reference. Its condition keys are
`aws:RequestTag/${TagKey}`, `aws:TagKeys`, `iam:PermissionsBoundary`, `iam:ResourceTag/${TagKey}` and
`iam:RoleTemplateARN`. There is nothing that reads the `AssumeRolePolicyDocument` in the request.
`iam:UpdateAssumeRolePolicy` has `aws:ResourceTag/${TagKey}`, `iam:PermissionsBoundary` and
`iam:ResourceTag/${TagKey}`, and again nothing that reads the document being installed. So a policy
condition that says "the trust policy may not name a principal outside this account" does not exist, and
no amount of writing will make one exist. Any claim that the boundary prevents a durable credential from
being minted is a claim about what the credential can do, not about whether it can exist, and Rule 2c is
about the second thing.

The clean IAM-level fix is a path. Role ARNs contain the path, so denying `iam:CreateRole` on
`NotResource` anything under `role/llm-eks/*` would force every role the operator creates into one place,
which makes the inventory enumerable and makes an unexpected role obvious. I am not shipping that today,
and the reason is the trap this whole review round is about: the `eks` and `karpenter` modules create their
roles at the default path unless `iam_role_path` is set, and that input is set in the cluster stack, not
here. Shipping the deny before the cluster stack sets the path would turn the window-1 apply into an
authorization failure with the kill timer armed, which is worse than the hole it closes. Setting
`iam_role_path = "/llm-eks/"` on the `eks` module, its node group definitions and the `karpenter`
submodule, and then adding the deny, is the fix; it is one change in each of two stacks and it is recorded
for the author rather than half-applied here.

`iam:UpdateAssumeRolePolicy` is denied against the protected ARNs and is deliberately not denied
everywhere. Terraform issues that call whenever a managed role's `assume_role_policy` re-renders
differently, so a blanket deny would fail an apply on a provider upgrade, and it would not close the hole
anyway while `iam:CreateRole` remains open.

Until the path is in place, the control is detective rather than preventive, and it belongs in
`guard-status`: list every role in the account whose permissions boundary is `llm-eks-operator-boundary`,
compare the count against `PermissionsBoundaryUsageCount` from `iam:GetPolicy` and against the set of
roles the stacks are expected to have created, and fail the pre-flight when a trust policy on one of them
names a principal outside account 288497659215 or the AWS services this project uses. That check is
cheap, it is read-only, and it runs before every window. It is also the honest description of where this
particular guarantee lives: in a check that runs at window open, not in a Deny statement.

The other thing this does not defend against is the base user assuming the administrator role directly.
`sts:AssumeRole` takes a role ARN and never consults the local profile list, so the commented-out admin
profile block is a convenience, not a control. That is recorded as open question 6 in
`materials/journal/STATE.md` and its fix is a condition on the administrator role's trust policy, which
is outside this stack.

## Sources

- <https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html>
- Actions, resources, and condition keys for AWS Identity and Access Management, for the `iam:CreateRole`
  and `iam:UpdateAssumeRolePolicy` condition-key columns:
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_iam.html>
- IAM JSON policy elements: Principal, for the `{"AWS": "*"}` any-principal form a trust policy can name:
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_principal.html>
- Actions, resources, and condition keys for Amazon EventBridge Scheduler, for `schedule` and
  `schedule-group` being separate resource types with different ARN shapes:
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_scheduler.html>
- Policy evaluation logic, on a Deny applying only when both the action and the resource in the request
  match the statement:
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html>
- IAM and AWS STS quotas, for the 6,144 character limit on a customer managed policy:
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html>
- Karpenter scheduling documentation, for zonal shift needing both the permission and the cluster to be
  enabled for it: <https://karpenter.sh/docs/concepts/scheduling/>
- Karpenter's own CloudFormation reference, for the `AllowZonalShiftStatusReadOnly` statement the
  submodule renders: <https://karpenter.sh/docs/reference/cloudformation/>
- Actions, resources, and condition keys for Amazon SNS, Amazon SQS and Amazon CloudWatch, for the topic,
  queue and alarm resource ARN shapes the safety-net Deny is scoped to:
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonsns.html>,
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonsqs.html>,
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazoncloudwatch.html>
