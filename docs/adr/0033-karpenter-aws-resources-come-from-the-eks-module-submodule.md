# 0033. Karpenter's AWS resources come from the eks module's submodule, and Terraform owns the instance profile

Date: 2026-09-08

## Status

Accepted.

## Context

Karpenter needs a set of AWS resources before it can be installed: a controller role with a fairly
large scoped policy, a node role, an instance profile, an SQS queue for interruption notices, and the
EventBridge rules that put messages on that queue. The alternative to writing them is
`terraform-aws-modules/eks/aws//modules/karpenter`, at the same 21.25.0 pin as the cluster.

I read what that submodule creates at 21.25.0 before deciding, from its entry in the registry:

`aws_iam_role.controller`, `aws_iam_policy.controller` (or `aws_iam_role_policy.controller` when
`enable_inline_policy` is set), `aws_iam_role_policy_attachment.controller` and
`controller_additional`, `aws_eks_pod_identity_association.karpenter`, `aws_iam_role.node` with
`aws_iam_role_policy_attachment.node` and `node_additional`, `aws_eks_access_entry.node`,
`aws_iam_instance_profile.this`, `aws_sqs_queue.this` with `aws_sqs_queue_policy.this`, and
`aws_cloudwatch_event_rule.this` / `aws_cloudwatch_event_target.this`.

The event rules, from the submodule's `main.tf`, are five, all pointed at the queue: `aws.health`
with detail-type `AWS Health Event`; and four on `aws.ec2` with detail-types `EC2 Spot Instance
Interruption Warning`, `EC2 Instance Rebalance Recommendation`, `EC2 Instance State-change
Notification` and `EC2 Capacity Reservation Instance Interruption Warning`. They are created when
`enable_spot_termination` is true.

That is the whole list from the task, so there is nothing left to write by hand.

One thing in the submodule is not the default I want. `create_instance_profile` defaults to `false`,
because Karpenter's own EC2NodeClass can take `spec.role` and generate the instance profile itself at
runtime.

## Decision

Use the submodule. Duplicate none of it.

Set `create_instance_profile = true` and have the platform layer's EC2NodeClass use
`spec.instanceProfile` rather than `spec.role`.

Set fixed names rather than the module's generated prefixes, so the policy simulator drills can name
the principals they are testing.

Pass the operator permission boundary to both roles, and narrow `ami_id_ssm_parameter_arns` from the
submodule's default of every `/aws/service` parameter down to the EKS optimized AMI tree.

## Consequences

An instance profile Karpenter generates is tagged by Karpenter, not by this stack's `default_tags`.
`mise run audit` and the guardrails sweeper both select on `Project=terraform-llm-eks`, so a
Karpenter-generated profile is invisible to both. It also outlives a `terraform destroy` that removes
the controller before the controller has cleaned up after itself, which is exactly the shape of a
teardown that goes wrong. A profile Terraform created is destroyed with the stack and carries the tag.

The cost is one more thing to keep in step: if the node role is ever replaced, the instance profile
has to be replaced with it, and the platform layer's EC2NodeClass has to be pointed at the new name.
The name is published as an SSM parameter and as an output so that coupling is explicit rather than
copied.

## Sources

- terraform-aws-modules/eks/aws 21.25.0, `modules/karpenter`: resource list, input defaults, and the
  README's own summary of what it creates.
  <https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/21.25.0/submodules/karpenter>
- The five EventBridge rules and their detail-types are from the submodule's `main.tf` at tag
  `v21.25.0`.
  <https://github.com/terraform-aws-modules/terraform-aws-eks/blob/v21.25.0/modules/karpenter/main.tf>
- Karpenter NodeClasses, `spec.role`: "you must specify one of `role` or `instanceProfile`"; and
  `spec.instanceProfile`: "If you use the `instanceProfile` field instead of `role`, Karpenter will
  not manage the InstanceProfile on your behalf; instead, it expects that you have pre-provisioned an
  IAM instance profile and assigned it a role."
  <https://karpenter.sh/docs/concepts/nodeclasses/>
