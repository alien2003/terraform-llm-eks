# The AWS side of Karpenter.
#
# I checked what the eks module's karpenter submodule creates at 21.25.0 before
# writing anything by hand. From the module's registry entry for that version it
# creates exactly: aws_iam_role.controller, aws_iam_policy.controller (or an
# inline aws_iam_role_policy), the two policy attachments, aws_iam_role.node with
# its attachments, aws_eks_access_entry.node, aws_eks_pod_identity_association,
# aws_iam_instance_profile, aws_sqs_queue with aws_sqs_queue_policy, and
# aws_cloudwatch_event_rule/aws_cloudwatch_event_target pairs. Its own README
# lists the same set. So none of it is duplicated here; this file is the
# submodule call and the settings that differ from its defaults.
#
# The five event rules the submodule creates when enable_spot_termination is true
# are, from its main.tf: aws.health "AWS Health Event", aws.ec2 "EC2 Spot Instance
# Interruption Warning", aws.ec2 "EC2 Instance Rebalance Recommendation", aws.ec2
# "EC2 Instance State-change Notification", and aws.ec2 "EC2 Capacity Reservation
# Instance Interruption Warning". All five target the queue.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.25.0"

  cluster_name = module.eks.cluster_name

  # The queue name is fixed by the project naming table, because `mise run audit`
  # and the teardown checklist both look for it by name.
  queue_name = var.karpenter_queue_name

  # Spot interruption handling is the reason the queue exists at all. Every GPU
  # node in this project is Spot, so the two minutes of warning this delivers are
  # the difference between a drained node and a killed request.
  enable_spot_termination = true

  # Pod Identity rather than IRSA. See ADR 0031. The eks-pod-identity-agent addon
  # in eks.tf is what makes the association resolve on the node.
  create_pod_identity_association = true
  namespace                       = var.karpenter_namespace
  service_account                 = var.karpenter_service_account

  # Fixed names instead of the module's generated prefixes, so that the policy
  # simulator drills in materials/guardrails/ can name the principals they test.
  iam_role_name              = "${var.cluster_name}-karpenter-controller"
  iam_role_use_name_prefix   = false
  iam_policy_name            = "${var.cluster_name}-karpenter-controller"
  iam_policy_use_name_prefix = false
  iam_role_description       = "Karpenter controller role for the ${var.cluster_name} cluster"

  node_iam_role_name            = "${var.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false
  node_iam_role_description     = "Role assumed by nodes Karpenter launches for the ${var.cluster_name} cluster"

  # Rule 2a again: the boundary denies iam:CreateRole unless the new role carries
  # the boundary. Both of these roles are created by the operator.
  iam_role_permissions_boundary_arn  = local.boundary_policy_arn
  node_iam_role_permissions_boundary = local.boundary_policy_arn

  # Only add the SourceAccount condition to the node role's trust policy; there is
  # one account and the confused-deputy shape it closes costs nothing to close.
  node_iam_role_source_account_condition = true

  # SSM Session Manager on the GPU nodes. It is the only way onto a node in a
  # private subnet without a bastion, and a bastion is an instance that bills by
  # the hour.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Create the instance profile in Terraform rather than letting the controller
  # generate one at runtime from spec.role. Karpenter's own documentation says
  # that with spec.role it manages the instance profile itself and with
  # spec.instanceProfile it expects a pre-provisioned one. A profile Karpenter
  # creates carries Karpenter's tags, not this stack's default_tags, so it is
  # invisible to `mise run audit` and survives a `terraform destroy` that removes
  # the controller before it has cleaned up. A profile Terraform owns is
  # destroyed with the stack. The platform layer's EC2NodeClass therefore sets
  # spec.instanceProfile, not spec.role.
  # https://karpenter.sh/docs/concepts/nodeclasses/
  create_instance_profile = true

  # The submodule's default SSM read scope is every /aws/service parameter. The
  # controller only ever resolves EKS optimized AMI IDs, which live under
  # /aws/service/eks/optimized-ami/<version>/..., so narrow it to that tree.
  # The parameter path is the one Karpenter's own getting-started guide reads:
  # https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/
  ami_id_ssm_parameter_arns = [
    "arn:${local.partition}:ssm:${var.region}::parameter/aws/service/eks/optimized-ami/*",
  ]
}
