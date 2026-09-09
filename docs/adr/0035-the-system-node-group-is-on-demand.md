# 0035. The system node group is on demand, and Karpenter does not manage it

Date: 2026-09-08

## Status

Accepted.

## Context

Rule 2b says never use on-demand GPU capacity, and the Phase 1 contract turns that into the rule the
permission boundary implements: GPU types are Spot only, system types may be either market. So the
system node group's capacity type is a decision this stack has to make rather than inherit.

The temptation is to make everything Spot. It is the cheaper hour and the whole project is about
running an expensive workload on interruptible capacity.

The reason not to is circular. Karpenter is what reschedules a pod when its node is reclaimed.
Karpenter runs in a pod. If Karpenter's own node is reclaimed, the thing that would have moved
Karpenter is Karpenter. The same argument applies, less sharply, to CoreDNS: a cluster with no
working DNS cannot pull an image to start the pod that would fix it.

## Decision

An EKS managed node group named `system`, `capacity_type = "ON_DEMAND"`, on the system instance types
from the contract, `desired_size = 2`.

It carries a label, `llm-eks.io/role = system`, and no taint.

Everything else in the cluster, which in practice means the GPU nodes, comes from Karpenter and is
Spot.

## Consequences

Two on-demand system instances are the standing compute cost of an open window before a single GPU
node exists. That number goes in the window plan's estimate, and the actual figure goes in
`materials/costs/windows.md` afterwards; nothing is written here from memory.

`desired_size = 2` rather than 1 because the Karpenter chart runs two replicas with an anti-affinity
that wants them on different nodes, and because losing the only node would take CoreDNS with it. The
maximum is 3 so a rolling AMI update has somewhere to go.

No taint, which is the part I expect to be argued with. A `CriticalAddonsOnly` taint is the
conventional way to keep general workloads off the system group, but every chart in the platform layer
would then need a matching toleration, and that stack is owned separately. A label plus a
`nodeSelector` puts the coupling in one direction: the platform layer opts in to the system nodes and
nothing has to opt out of them. The label is published as an output and as an SSM parameter so the
platform layer does not have to guess it.

The system node group cannot itself be reclaimed, so there is one class of failure this project will
not get to demonstrate on video. The GPU node is where the interesting interruption happens anyway.

## Sources

- Phase 1 contract, "The instance whitelist and the Spot rule": GPU types Spot only, system types
  either market, everything else denied. Private working material, not in this repository.
- terraform-aws-modules/eks/aws 21.25.0, `eks_managed_node_groups`: `capacity_type` valid values
  `ON_DEMAND` and `SPOT`, defaulting to `ON_DEMAND`; `ami_type` defaulting to
  `AL2023_x86_64_STANDARD`.
  <https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/21.25.0>
- Karpenter, Getting Started: the reference install puts the `kube-system` namespace, and Karpenter
  itself, on an EKS managed node group rather than on Karpenter-managed capacity.
  <https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/>
