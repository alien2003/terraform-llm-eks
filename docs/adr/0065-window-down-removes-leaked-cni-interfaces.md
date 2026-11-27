# 0065. window-down removes leaked CNI interfaces before the network goes

Date: 2026-11-27

## Status

Accepted. Amends the destroy step of ADR 0060.

## Context

In window 1, attempt 5, `mise run down` destroyed the platform layer and then failed on the network:
`DependencyViolation` on a private subnet and on the node security group. The audit listed the VPC, a
subnet, a route table, a network ACL and two security groups. Nothing billable was left: no cluster, no NAT
gateway, no instance.

What held them was one network interface, status `available`, description
`aws-K8S-i-06112f2eff92273b9`. That instance was the GPU node Karpenter had launched and then terminated
during the platform destroy. The VPC CNI names the interfaces it creates `aws-K8S-<instance id>`, and this
one outlived its node. After I deleted it by hand, a second `down` destroyed the last 3 resources and the
audit was clean.

## Decision

`window-down` calls `delete_leaked_cni_enis` before the full destroy of `infra/cluster`, and once more,
followed by one retry of the destroy, if that destroy fails.

It deletes only interfaces that match all three:

- in the VPC tagged `Project=terraform-llm-eks` and `Stack=cluster`;
- status `available`, so attached to nothing;
- description matching `aws-K8S-*`.

## Consequences

A leaked interface from a Karpenter node is gone before Terraform reaches the subnets. One from a managed
node group node, which terminates inside the network destroy itself, is caught by the retry.

An interface the CNI leaks after the retry still fails the destroy, and the audit still holds the window
open. That is the right failure: the rule stays that a dirty audit is the only work.

## Sources

- EC2 filters accept `*` in values.
  https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Using_Filtering.html
- Amazon VPC CNI.
  https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html
- Evidence in the working notes: `materials/journal/w1e-down-2026-11-27.log`, `w1e-down2-2026-11-27.log`,
  `materials/measurements/provisioning/w1e-nodeclaim-ready.txt`.
