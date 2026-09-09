# 0015. One kill Lambda, three modes, and a stop that means stop

Status: accepted
Date: 2026-09-09

## Context

Three different things need to stop spend, and they want different amounts of it.

The always-on sweeper runs every few minutes for the life of the project. It should act on anything
project-tagged that has been alive longer than a window could reasonably last, and leave younger things
alone, because a young instance is probably a node that is currently doing the work.

The one-shot window timer fires once, at the end of the approved window. Age is irrelevant then:
everything goes.

A spend alert is the same situation arriving from a different direction. If the budget action or a billing
alarm has fired, nothing that is running should keep running.

There is also a fourth caller that must never change anything: the drill, which needs to show what would
happen without doing it.

The first version of this decision said "terminate every project-tagged instance" and stopped there. That
was wrong, and it was wrong in the way that matters most, because it was wrong while looking right. Two
independent adversarial reviews found the same defect before anything had been applied:

- An EKS managed node group holds `desired_size` at 2. Terminating its instances does not change that, so
  its Auto Scaling group replaces them within about ninety seconds.
- The Karpenter controller runs on those replaced nodes. It sees an inference pod still pending on
  `nvidia.com/gpu` and issues a fresh `CreateFleet`, so the GPU node comes back too.
- Each replacement is a brand new instance with age zero, so the sweeper's age test never catches the
  replacements either. The control does not converge, it churns, at full hourly cost, with a model reload
  every cycle.
- The EKS control plane, the NAT gateway and its in-use public IPv4 address were never in the kill path at
  all. They bill by the hour whether or not any instance exists, so the quiet case, where the workload has
  scaled to zero and nothing is churning, was a cluster running indefinitely on an account whose credits
  are treated as cash.

So the honest description of the old kill path is that it was a reboot with an alarming name.

## Decision

One Python function, `llm-eks-kill`, with a mode taken from the event, and a stop that removes the things
that bill rather than the things that are cheapest to replace. The order is fixed and it is the reasoning,
not a preference:

1. Scale every managed node group of the project cluster to zero, `minSize` and `desiredSize` both, leaving
   `maxSize` alone because the API requires it to be at least 1. This is first because it is what stops the
   Auto Scaling group replacing the nodes, and because the Karpenter controller lives on those nodes: take
   them away and there is nowhere for the thing that would launch a replacement GPU node to run. This is
   also the only AWS-side way to neutralise Karpenter. Deleting a NodePool is a Kubernetes call, and a
   Lambda with no cluster credentials and no route to a private API endpoint cannot make it.
2. In a full stop, delete those node groups, because `DeleteCluster` refuses while a managed node group
   exists.
3. Terminate every project-tagged instance, one call per instance so a single un-terminatable instance
   cannot fail the whole batch.
4. In a full stop, delete the load balancers in the project VPCs, the NAT gateways and the cluster, and
   release the unassociated Elastic IPs.

`sweep` does steps 1 and 3 when it finds a project-tagged instance older than the derived age, and it then
terminates every project-tagged instance rather than only the aged ones, because that age is longer than
the longest window the approval form can grant: an instance older than it means no window is legitimately
open. `sweep` escalates to all four steps when it finds an hourly resource with no project-tagged instances
running, no window timer pending in the `llm-eks-windows` group, and more than `orphan_grace_minutes` on
its own clock. `kill_all`, which is what the timer sends and what any SNS envelope on the alert topic is
read as, does all four unconditionally. `report` describes the full stop and changes nothing.

The sweeper's escalation is what makes the whole thing converge, and that is its main job rather than a
side effect. Deleting a node group takes minutes and the cluster cannot be deleted until it has finished,
so the pass that fires the timer normally leaves the cluster behind with a `ResourceInUseException`.
Something has to come back and finish, and the sweeper is the only thing that runs unattended.

The sweeper reads the window timers to decide whether a node-less cluster is abandoned or in use, and any
doubt at all answers "in use". A cluster is legitimately node-less for the first ten minutes of an apply,
and a window in which a node group launch is being debugged can be node-less for much longer.

Failures are collected and re-raised once, after every other step has been attempted. Errors that mean
"already gone" count as done and errors that mean "not yet" count as pending, so a normal teardown does not
raise. Anything else does, which is what puts the event on the dead-letter queue and lights the error
alarm.

The function iterates every region in `local.allowed_regions`, the same list the boundary's `RegionLock`
permits.

`sweeper_max_age_minutes` is not a variable. It is derived from `max_window_hours` plus a margin, and both
are published to SSM for the scripts to read.

## Consequences

The kill path can now delete the cluster, and that is a real loss of work when it fires. That is the trade
being made deliberately: the timer only fires because the window ran past its approved hours with nobody
closing it, and the workspace rules already say to tear down first and investigate later. A cluster is
twelve minutes of `terraform apply`. A forgotten GPU node is credits that do not come back.

Two things are deliberately not deleted. EBS volumes, because a volume is somebody's data and not
destroying the author's data outranks cost; the node root volumes go with their instances, and a stray
unattached volume is a per-GB-month charge that the audit reports and a person deletes. And the VPC and its
subnets, route tables, security groups and internet gateway, because none of them costs anything once the
NAT gateway is gone, and unpicking a VPC's dependency order unattended is how a Lambda leaves a
half-deleted network nobody can reason about.

Running while a `terraform apply` is in flight is now a real possibility with real consequences, because
the Lambda deletes things the apply is building. The apply loses, which is the right way round. What makes
that survivable is that every step is idempotent and nothing is waited on: the next `terraform destroy`
refreshes, finds the resources gone and moves on, and `mise run audit` is what answers whether anything is
left.

The sweeper deleting a cluster it did not create is a new failure mode, and the window-timer test is the
only thing standing between it and a cluster somebody is debugging. That test fails safe in the direction
that costs an hour of a control plane rather than a window of work, and it depends on `mise run up` having
armed a timer, which the window protocol requires anyway. An apply outside a window is not protected, and
an apply outside a window is already forbidden.

Three IAM facts in the kill role are scoped on inference rather than on a citation:
`eks:UpdateNodegroupConfig` against the nodegroup ARN, and `ec2:DeleteNatGateway` and `ec2:ReleaseAddress`
which are granted account-wide because I could not confirm they take resource-level permissions and a
condition on an unsupported key is a silent deny. All three are window-0 drill cases with
`aws iam simulate-principal-policy`, and until they are drilled the strongest claim this stack can make is
that the code, not IAM, is what keeps those two calls inside the project.

The tests patch every client and the clock, so they run with no network and no credentials, which means
they run in CI where there are none. They are the only part of this stack that can be proved locally; the
IAM policies cannot, which is why the boundary is drilled against the real evaluation engine before window
0 rather than trusted on the strength of a passing unit test.

This record was rewritten rather than superseded because the decision it describes had never been applied
to an account: the reviews that found the defect ran against the Phase 1 tree before window 0 opened. The
old text is in the repository's history.

## Sources

- <https://docs.aws.amazon.com/eks/latest/APIReference/API_NodegroupScalingConfig.html>
- <https://docs.aws.amazon.com/eks/latest/APIReference/API_UpdateNodegroupConfig.html>
- <https://docs.aws.amazon.com/step-functions/latest/dg/connect-eks.html>
- <https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html>
- <https://docs.aws.amazon.com/scheduler/latest/UserGuide/security_iam_id-based-policy-examples.html>
