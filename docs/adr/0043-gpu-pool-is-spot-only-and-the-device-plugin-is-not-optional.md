# 0043. The GPU pool is Spot only, and the device plugin is not optional

Date: 2026-09-09

## Status

Accepted.

## Context

Rule 2b says never use on-demand GPU capacity, and the operator permission boundary denies
it with a condition on `ec2:InstanceMarketType`. That is the hard control and it is where it belongs.

It is not, on its own, enough to make the cluster behave well. If the GPU NodePool is allowed to ask
for on-demand capacity, Karpenter will ask for it whenever Spot is short, the boundary will deny the
`RunInstances` call, and the symptom the operator sees is an AccessDenied in a controller log rather
than a pending pod. The scheduler needs to know the rule too.

Separately, a GPU node is not usable the moment it joins. The `nvidia.com/gpu` extended resource is
advertised by a device plugin, not by the kubelet, and Karpenter treats a node as uninitialized until
the resources its NodePool implies are actually registered. Without the plugin the node is
provisioned, billed, never schedulable, and eventually reclaimed.

## Decision

The GPU NodePool restricts `karpenter.sh/capacity-type` to `spot` and
`node.kubernetes.io/instance-type` to the GPU half of the boundary whitelist. It carries a
`nvidia.com/gpu=true:NoSchedule` taint, a `spec.limits.cpu` ceiling, `consolidationPolicy: WhenEmpty`,
an `expireAfter`, a `terminationGracePeriod` and a disruption budget of one node at a time.

`WhenEmpty` rather than `WhenEmptyOrUnderutilized`: an underutilized GPU node is the normal state
between two benchmark runs, and replacing it costs a full model load.

The general NodePool takes either market and the system half of the whitelist, with
`WhenEmptyOrUnderutilized` and a percentage budget.

The NVIDIA device plugin chart is installed as part of this layer, with a node affinity on
`karpenter.k8s.aws/instance-gpu-manufacturer: nvidia` and a toleration for the accelerator taint. The
chart's own default affinity selects on node-feature-discovery labels, which this cluster does not
run, so it is replaced.

Both node classes propagate the project tags to every instance, volume and network interface
Karpenter launches. A Karpenter node without `Project=terraform-llm-eks` is invisible to the sweeper
and to `mise run audit`, which is the one failure this project cannot absorb.

## Consequences

A Spot shortage shows up as a pending pod, which is a legible state, instead of as a denied API call.

The taint means nothing lands on an accelerator by accident. The device plugin, the DCGM exporter,
the node exporter and the inference pod carry matching tolerations; nothing else does.

Three brakes now sit in front of GPU spend, in order of authority: the permission boundary, the
NodePool's capacity-type and instance-type requirements, and the NodePool's cpu limit. The first is
the only one an operator cannot change, which is the point.

## Sources

- Karpenter well-known labels, including `karpenter.sh/capacity-type` with values `reserved`, `spot`
  and `on-demand`, and `karpenter.k8s.aws/instance-gpu-manufacturer`:
  <https://karpenter.sh/docs/concepts/scheduling/>
- Karpenter scheduling, accelerators: "If you are provisioning nodes that will utilize
  accelerators/GPUs, you need to deploy the appropriate device plugin daemonset. Without the
  respective device plugin daemonset, Karpenter will not see those nodes as initialized."
  <https://karpenter.sh/docs/concepts/scheduling/>
- Karpenter NodePool disruption budgets, `consolidationPolicy` values and the required
  `consolidateAfter`, read from the CRD shipped in the Karpenter chart 1.14.1:
  <https://karpenter.sh/docs/concepts/nodepools/>
- Amazon EKS User Guide, EKS-optimized accelerated AMIs and the instance families each variant
  supports, which is what the `al2023@` alias resolves to for a g6 instance type:
  <https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html>
