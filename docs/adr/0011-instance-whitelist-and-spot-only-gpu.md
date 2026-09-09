# 0011. The instance whitelist and the Spot-only GPU rule live in the permission boundary

Status: accepted
Date: 2026-09-08
Revised: 2026-09-09

## Context

Rule 2b says never use on-demand GPU capacity and that the boundary denies it. The expensive mistake this
project can make is launching the wrong instance type, or the right type in the wrong market, and then
not noticing for a few hours.

Three things had to be settled: which condition keys express this, which resource ARN they have to be
attached to, and whether to write the rule as an allow of the good cases or a deny of everything else.

The condition keys are documented. `ec2:InstanceType` filters on the type of instance.
`ec2:InstanceMarketType` filters on the market or purchasing option, and takes `capacity-block`,
`on-demand` or `spot`.

The resource scoping is the part that fails quietly. Both keys are evaluated against the `instance`
resource type and against nothing else. The `RunInstances` row in the Service Authorization Reference
lists eighteen resource types, five of them required, which I counted off that page: capacity-reservation,
elastic-gpu, elastic-inference, group, image, instance, key-pair, launch-template,
license-configuration, network-interface, placement-group, secondary-interface, secondary-subnet,
security-group, snapshot, spot-instances-request, subnet and volume. Only the `instance` row carries
`ec2:InstanceType` and `ec2:InstanceMarketType`. A condition
attached to any of the other seventeen is not an error: the statement simply never matches and the deny
never fires. A policy that looks correct and does nothing is worse than no policy at all, because it
gets trusted.

There is a second version of that same failure, and the first revision of this stack contained it. A
condition key that the action does not support is ignored rather than rejected, so a statement can be
widened to cover a new action and quietly stop enforcing anything for it. That is what makes the
`CreateFleet` question below worth settling from the reference table rather than from a comment in the
code.

## Decision

The launch rules are `Deny` statements in `llm-eks-operator-boundary`, all scoped to
`arn:aws:ec2:*:*:instance/*`.

`InstanceTypeWhitelist` denies `ec2:RunInstances` and `ec2:CreateFleet` when `ec2:InstanceType` is not one
of the whitelisted types. It is a deny of everything outside the list rather than an allow of the list,
because `StringNotEquals` is true when the key is absent, so a request that carries no instance type is
refused rather than permitted.

`GpuSpotOnly` denies `ec2:RunInstances` when `ec2:InstanceType` is a GPU type and `ec2:InstanceMarketType`
is not `spot`. The negated test also catches a request with no market in it at all. It names
`ec2:RunInstances` and nothing else, for the reason in the first Consequences section.

`InstancesMustCarryProjectTag` denies a launch that does not tag the instance with `Project`, because the
sweeper and the audit task both select on that tag and an untagged instance is invisible to both.

`NoProjectTagRemoval` denies `ec2:DeleteTags` on instances, volumes and NAT gateways when the request
names `Project` or `Stack` among its keys, `NoBlanketTagWipe` denies the same action on the same
resources when `aws:TagKeys` is absent from the request altogether, and `NoProjectTagRepoint` denies
`ec2:CreateTags` on the same three resource types when the request sets `Project` to anything other than
this project's value.
Requiring the tag at launch is decoration on its own: the same principal that had to set it can remove it
a second later, and after that the instance is invisible to the sweeper's describe filter, to every
resource query in the audit, and to the kill role, whose `TerminateInstances` statement carries a
condition on `aws:ResourceTag/Project` and therefore stops matching.

Three further denies close the ways around the whitelist rather than through it. `NoResizeOrRelocate`
denies `ec2:ModifyInstanceAttribute` and `ec2:ModifyInstancePlacement` outright, because resizing a
stopped whitelisted instance into a large one is a launch that never goes through the launch path.
`NoCommittedOrReservedSpend` denies the purchase, reservation, dedicated-host and scheduled-instance
calls, which bill on a different mechanism entirely. `NoUnfilterableLaunchPath` denies
`ec2:RequestSpotInstances` and `ec2:RequestSpotFleet`, the two launch APIs no condition can filter at
all; the Consequences section below is where that one is argued.

`NoEksAutoModeCompute` denies `eks:CreateCluster` and `eks:UpdateClusterConfig` when
`eks:computeConfigEnabled` is true, and `autoscaling` is in the Allow ceiling as `autoscaling:Describe*`
rather than `autoscaling:*`. Both of those close a path to running instances that never calls an EC2
launch action at all; the second Consequences section is where they are argued.

The EBS bound is three statements in `llm-eks-operator-denies` rather than in the boundary:
`VolumeTypeMustBeGp3`, `VolumeSizeCeiling` and `NoProvisionedIops` deny `ec2:CreateVolume` and
`ec2:ModifyVolume` on `arn:aws:ec2:*:*:volume/*` when the type is not `gp3`, when `ec2:VolumeSize` is
above 120, or when `ec2:VolumeIops` is above 3,000. Three statements and not one, because conditions
inside a statement are ANDed and what is wanted here is three independent matches. 120 is the GPU node's
root volume (`gpu_node_volume_size` in the platform stack); the system node's is 40
(`system_node_disk_size` in the cluster stack); 3,000 IOPS is the gp3 baseline included in the price of
storage, so the bound is exactly "no provisioned IOPS". `ec2:VolumeSize` and `ec2:VolumeIops` are Numeric
and `ec2:VolumeType` is String in the reference table, and all three appear on the `volume` row of both
actions.

## Consequences: Spot-only is not an IAM rule on the Karpenter path

EC2 has more than one way to start an instance and the whitelist does not reach them the same way. The
`CreateFleet` case had been asserted in the code and in this ADR from two different readings, so I settled
it off the actions table for Amazon EC2. `CreateFleet` defines seven resource types: fleet, image,
instance, launch-template, placement-group, subnet and volume. Its `instance` row is
`aws:RequestTag/${TagKey}`, `aws:TagKeys`, `ec2:AvailabilityZone`, `ec2:AvailabilityZoneId`,
`ec2:CpuOptionsAmdSevSnp`, `ec2:EbsOptimized`, `ec2:InstanceBandwidthWeighting`, `ec2:InstanceID`,
`ec2:InstanceProfile`, `ec2:InstanceType`, `ec2:PlacementGroup`, `ec2:Region`, `ec2:RootDeviceType` and
`ec2:Tenancy`. `ec2:InstanceMarketType` is not in it, and it is not on any other `CreateFleet` resource
type either. The `RunInstances` `instance` row does list it.

So the type whitelist covers `CreateFleet` and the market rule cannot. Adding `ec2:CreateFleet` to
`GpuSpotOnly` would produce a statement that renders, validates, simulates and enforces nothing, which is
strictly worse than the honest gap, because a drill would print a pass for it. The header comment in
`infra/guardrails/iam_operator.tf` that claimed the two actions evaluate the same keys was wrong and has
been corrected, and it says the same thing there.

Karpenter launches through `CreateFleet`. So the primary control on the on-demand GPU launch is not IAM.
It is the service quota "Running On-Demand G and VT instances", which `var.quota_targets` in the
guardrails stack holds at a target of 0. A quota of zero running on-demand G vCPUs makes an on-demand
`g6.xlarge` or `g6.2xlarge` fail at the API regardless of what any policy says, and it fails for every
caller and every launch path, including the ones the boundary is not evaluated for at all. That is a
stronger control than the IAM deny it replaces, and it is the one to name first.

It is also data rather than code, and that is the honest caveat. Nobody has queried the account yet, so
whether the account's current value for that quota is in fact 0 is unverified; AWS can raise a quota on
its own as usage grows. `mise run guard-status` reads the live value against the target at window open,
which is what turns a recorded intention into a checked precondition, and no window opens if it does not
match. Behind that sit the GPU NodePool's `capacityTypes: [spot]`, the sweeper's age limit and the window
timer.

`ec2:RequestSpotInstances` was a second hole of the same family, and it is shut rather than mitigated only
because I went looking for it. Its authorization row has no `instance` resource type at all, and
`ec2:InstanceType` does not appear anywhere in it, so there is no condition form of the whitelist that can
attach to that action. Scoping the deny to the `spot-instances-request` resource it does list would not
help either: the only condition keys on that row are the request-tag keys and `ec2:Region`, none of which
can express an instance type. With `ec2:*` sitting in the Allow ceiling, one call to a legacy API would
have walked around a whitelist that reads as airtight, into any family with non-zero Spot quota.
`NoUnfilterableLaunchPath` therefore denies it outright, together with `ec2:RequestSpotFleet`. Nothing here
needs either: this project launches through the managed node group and through Karpenter, and through
nothing else. An action that cannot be filtered and is not needed is an action to deny, not an action to
watch.

## Consequences: three compute paths never call a launch action

The three statements above are conditions on API calls, evaluated against the principal making the call.
There are three ways to reach a running instance in this account without the operator, or any
boundary-carrying role, ever making one of those calls.

An Auto Scaling group is the first. An ASG does not launch instances as whoever created it: AWS documents
that Amazon EC2 Auto Scaling calls other services on your behalf through a service-linked role named
`AWSServiceRoleForAutoScaling`, and creates that role for you if it does not exist in the account. It is
therefore not a role the operator creates, so `NewRolesMustCarryThisBoundary` never applies to it and it
carries no boundary. None of the three launch denies is evaluated for an ASG launch, the instances need no
`Project` tag and the type is unfiltered. The fix is that the
project needs no autoscaling write at all, so `autoscaling` is in both Allow surfaces as
`autoscaling:Describe*`. I established the "no write needed" part four ways: the cluster stack declares
`eks_managed_node_groups` and no self-managed group, whose Auto Scaling group is created and owned by EKS;
the pinned `terraform-aws-modules/eks` root module and its `eks-managed-node-group` submodule declare no
`aws_autoscaling_*` resource on that path, only the `self-managed-node-group` submodule does; the
Karpenter controller policy the pinned `karpenter` submodule renders names no autoscaling action in any of
its statements; and `AmazonEKSClusterPolicy` does carry autoscaling writes but AWS documents that they
"aren't used by Amazon EKS but remain in the policy for backwards compatibility", so leaving them outside
the ceiling costs the EKS cluster role nothing. Narrowing an Allow rather than adding a Deny also closes
the actions I did not enumerate, and it made the boundary smaller instead of larger.

EKS managed node group scaling is the second, and this one cannot be closed in IAM. I read the EKS
condition-key table in full: there is no instance-type, capacity-type or scaling-size key anywhere in it.
`eks:CreateNodegroup` is authorized against the `cluster` resource type with only the three tag keys, and
`eks:UpdateNodegroupConfig` against the `nodegroup` resource type with only `aws:ResourceTag/${TagKey}`.
So `aws eks update-nodegroup-config --scaling-config desiredSize=10` is expressible and unfilterable, and
`eks:UpdateNodegroupConfig` is also exactly how Terraform applies the node group's own scaling
configuration, so denying it would break the cluster apply rather than protect anything. The ceiling here
is again a quota: "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances" is held at its
documented default of 5 vCPUs, and the note in `var.quota_targets` records that the two 2-vCPU system
nodes need 4 of them. A third node does not fit. Ten do not fit ten times over. The same quota caps a
`CreateNodegroup` call asking for a large on-demand Standard type, and the G and VT quotas cap the GPU
equivalents.

EKS Auto Mode is the third, and here AWS does publish a usable key. `eks:computeConfigEnabled` is a Bool
key on both `eks:CreateCluster` and `eks:UpdateClusterConfig`, filtering on the compute config enabled
parameter in the request, which is what turns Auto Mode on. `NoEksAutoModeCompute` denies both actions
when it is true. This cannot fire on the legitimate apply: the cluster stack passes no `compute_config`,
the module's variable defaults to null so the block is not emitted, the key is therefore absent from the
request context, and a `Bool` test against an absent key does not match.

## Consequences: what the whitelist actually binds

Following the Auto Scaling reasoning through has one uncomfortable implication worth writing down. The
system node group's instances are launched by the EKS-owned Auto Scaling group, not by the operator, so
`InstanceTypeWhitelist` and `InstancesMustCarryProjectTag` are not evaluated for them either. What keeps
those nodes small is the `instance_types` list in the node group definition plus the Standard vCPU quota,
and what keeps them tagged is the launch template's `tag_specifications`, which is why the cluster stack
passes `tags` to the module explicitly rather than relying on provider `default_tags`. The boundary's
launch statements bind Karpenter's `CreateFleet`, because the Karpenter controller role is created by the
operator and therefore carries the boundary, and they bind any `RunInstances` the operator makes by hand.
That is a narrower claim than "the boundary controls every launch in this account", and it is the true
one.

## Other consequences

The tag requirement reaches across stacks. Provider `default_tags` does not apply to instances Karpenter
launches from inside the cluster, so the EC2NodeClass has to set the tag itself or node launches fail
with an authorization error. Better a loud failure than an invisible instance.

The two tag denies are shaped so that a normal apply cannot trip them, and the shape is the whole point.
`NoProjectTagRepoint` requires both that `Project` is among the request's tag keys and that the value it
is being set to is not this project's, and both have to hold for the deny to match. A create-time tag set
of `{Project, Stack, ManagedBy, Name}` at the right values does not match. A tag update that rewrites
`Project` to the value it already has does not match. A `CreateTags` that never mentions `Project` does
not match. Karpenter is untouched twice over: its create-time tagging statement carries the EC2NodeClass
tags, `Project` among them at this value, and its post-launch tagging statement is capped by a
`ForAllValues:StringEquals` on `aws:TagKeys` to `eks:eks-cluster-name`, `karpenter.sh/nodeclaim` and
`Name`. `NoProjectTagRemoval` needs no such care, because nothing in this project removes either tag: the
tags come from `default_tags`, so Terraform sets them on create and leaves them alone, and no policy the
operator creates carries `ec2:DeleteTags` at all.

`NoBlanketTagWipe` exists because `NoProjectTagRemoval` on its own has a hole with the same shape as the
`CreateFleet` one: a condition that is not in the request context does not match. The `Tags` parameter of
`DeleteTags` is optional, and AWS documents that omitting it deletes every user-defined tag on the
resources named. In that request there are no tag keys to put in `aws:TagKeys`, so the
`ForAnyValue:StringEquals` test is false and the deny that exists to protect the `Project` tag does not
fire on the one call that removes all of it. `Null` with a value of true is the documented test for "this
key is absent from the request", which is that call and nothing else, because every `DeleteTags` a person
or a provider issues on purpose names the keys it is removing. I did not deny `ec2:DeleteTags` outright
instead, even though nothing here calls it, because a tag key disappearing from a NAT gateway's
configuration is a legitimate reason for Terraform to issue one and a failed apply inside a window costs
more than this pair of statements.

The EBS bound is in the attached deny policy rather than in the boundary because nothing in the normal
build calls either action. Both node root volumes are block device mappings inside a launch template, and
those are authorized against the `volume` resource type of `RunInstances` and `CreateFleet` rather than
against `ec2:CreateVolume`. There is no EBS CSI driver in the addon set and ADR 0044 keeps no persistent
volume, so no PersistentVolumeClaim reaches `CreateVolume` either. If a CSI driver is ever added that
changes: the EKS cluster role carries volume permissions through `AmazonEKSClusterPolicy`, so the three
statements have to move into the boundary and the size bound has to be re-checked against the largest
claim the cluster is allowed to make. The bound as written also does not reach a large root volume asked
for through a launch template, because that authorizes on a different action; the `volume` rows of
`RunInstances` and `CreateFleet` do carry `ec2:VolumeSize`, `ec2:VolumeType` and `ec2:VolumeIops`, so it
is expressible, and it is the next thing to add when there is room in the boundary for it.

`ModifyInstanceAttribute` being denied outright means the operator also cannot set termination protection
or change an ENI's source/destination check. Neither is needed here, and the first of those is a
capability I would rather the operator did not have.

Every finding above should become a case in `mise run guard-drill` before window 0. The drill currently
exercises `run-instances --dry-run` and a handful of simulated `RunInstances` calls, which means none of
`CreateFleet`, `CreateAutoScalingGroup`, `CreateNodegroup`, `CreateVolume`, `DeleteTags` or
`SetSubscriptionAttributes` can fail it. A drill that cannot fail on a hole is not evidence that the hole
is closed.

## Sources

- Actions, resources, and condition keys for Amazon EC2. The `RunInstances`, `CreateFleet`,
  `RequestSpotInstances`, `RequestSpotFleet`, `CreateVolume`, `ModifyVolume`, `CreateTags` and
  `DeleteTags` rows are where the resource types and the per-resource condition keys were counted, and
  the condition-key table at the foot of that page is where `ec2:VolumeSize` and `ec2:VolumeIops` are
  Numeric and `ec2:VolumeType` and `ec2:CreateAction` are String:
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html>
- Actions, resources, and condition keys for Amazon Elastic Kubernetes Service, for
  `eks:computeConfigEnabled` and for the absence of any capacity key on `eks:CreateNodegroup` and
  `eks:UpdateNodegroupConfig`:
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_eks.html>
- Tag-based condition keys for Amazon EC2: "These condition keys can be applied to resource-creating
  actions that support tagging, as well as the ec2:CreateTags and ec2:DeleteTags actions":
  <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/supported-iam-actions-tagging.html>
- AWS managed policies for Amazon EKS, on `AmazonEKSClusterPolicy`: the autoscaling permissions in it
  "aren't used by Amazon EKS but remain in the policy for backwards compatibility":
  <https://docs.aws.amazon.com/eks/latest/userguide/security-iam-awsmanpol.html>
- Service-linked roles for Amazon EC2 Auto Scaling: the service "uses service-linked roles for the
  permissions that it requires to call other AWS services on your behalf", and "by default, Amazon EC2
  Auto Scaling uses a service-linked role named AWSServiceRoleForAutoScaling and creates it for you if
  the role doesn't exist in your account":
  <https://docs.aws.amazon.com/autoscaling/ec2/userguide/autoscaling-service-linked-role.html>
- Actions, resources, and condition keys for Amazon EC2 Auto Scaling, for
  `autoscaling:InstanceTypes` and `autoscaling:MaxSize`, the keys a conditioned grant would have used had
  one been needed:
  <https://docs.aws.amazon.com/service-authorization/latest/reference/list_autoscaling.html>
- Amazon EBS General Purpose SSD volumes: gp3 "deliver a consistent baseline IOPS performance of 3,000
  IOPS, which is included with the price of storage":
  <https://docs.aws.amazon.com/ebs/latest/userguide/general-purpose.html>
- Amazon EC2 instance type quotas, for the documented defaults the quota targets record:
  <https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-quotas.html>
- DeleteTags in the Amazon EC2 API Reference, on the optional `Tags` parameter: "If you omit this
  parameter, we delete all user-defined tags for the specified resources":
  <https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DeleteTags.html>
- IAM JSON policy elements: Condition operators, for the `Null` operator ("use either true (the key
  doesn't exist [...]) or false (the key exists and its value is not null)") and on an absent key: "If
  the key that you specify in a
  policy condition is not present in the request context, the values do not match and the condition is
  false. If the policy condition requires that the key is not matched [...] the condition is true." That
  is what makes a `StringNotEquals` deny fail closed:
  <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition_operators.html>
- <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ExamplePolicies_EC2.html>
