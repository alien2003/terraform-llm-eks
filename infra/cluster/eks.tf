# The cluster.
#
# terraform-aws-modules/eks/aws v21. The v19 and v20 examples that dominate search
# results do not apply: v21 renamed cluster_* inputs to their bare form (name,
# kubernetes_version, endpoint_public_access), moved cluster_addons to addons, and
# changed several defaults. Every input below was read from the module's own
# registry entry for 21.25.0.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # The control plane's network interfaces go in the same private subnets as the
  # nodes. There is no separate control plane subnet tier to keep the address
  # plan small and the teardown short.
  control_plane_subnet_ids = module.vpc.private_subnets

  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # API only. The aws-auth ConfigMap is the older mechanism and keeping both
  # would mean two places where cluster access is decided.
  authentication_mode = "API"

  # The cluster creator here is the operator role, and it gets its access entry
  # explicitly in locals.tf rather than implicitly from the caller identity, so
  # that the entry survives being applied from a different session.
  enable_cluster_creator_admin_permissions = false
  access_entries                           = local.access_entries

  enabled_log_types                      = var.enabled_log_types
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days

  # No customer-managed KMS key, so no `encryption_config` block on the cluster.
  # Both lines are needed and both are a deviation from the module's defaults: at
  # 21.25.0 `create_kms_key` defaults to true and `encryption_config` defaults to
  # `{}`, whose own default fills in `resources = ["secrets"]`. Left alone the
  # module would create a customer-managed key through
  # terraform-aws-modules/kms/aws 4.0.0 with automatic rotation on, and attach an
  # extra IAM policy to the cluster role so the control plane can use it. The
  # module gates the block on `var.encryption_config != null`, so passing null is
  # what actually switches it off; create_kms_key = false alone would leave the
  # block in place with an empty key ARN.
  #
  # What this gives up is a key encryption key this account owns and can audit,
  # not encryption itself. On Kubernetes 1.28 and above, which includes the 1.35
  # this cluster runs, EKS envelope-encrypts all Kubernetes API data with an
  # AWS-owned key, and AWS-owned keys carry no charge. A customer-managed key
  # bills per key per month for as long as it exists, and pointing a cluster at
  # one is a one-way door: secrets encryption cannot be disabled or repointed
  # afterwards. ADR 0036 has the whole trade-off and the sources. trivy raises
  # AVD-AWS-0039 against the module's own aws_eks_cluster resource, so the
  # acceptance is recorded in .trivyignore rather than as an inline comment.
  create_kms_key    = false
  encryption_config = null

  enable_irsa = var.enable_irsa

  addons = local.addons_with_versions

  # The same tag baseline the provider's default_tags block carries, passed in
  # explicitly. This is not redundant. Provider default_tags reach a resource's
  # own `tags` attribute, and they do reach aws_launch_template.tags, but they do
  # not reach the launch template's `tag_specifications` blocks, which are what
  # tag the instances, the root volumes and the ENIs the node group launches.
  # This module builds those blocks as merge(var.tags, { Name = var.name },
  # var.launch_template_tags), so with no `tags` here the system nodes and their
  # gp3 volumes would come up carrying nothing but a Name tag. EKS node group tags
  # do not fill the gap either: AWS documents that node group tags do not
  # propagate to any other resource associated with the node group, including the
  # EC2 instances. An instance with no Project tag is invisible to the guardrails
  # sweeper and to `mise run audit`, which is exactly the hole Rule 2a exists to
  # close.
  tags = local.default_tags

  # Rule 2a: the boundary denies iam:CreateRole unless the new role carries the
  # boundary itself. Every role this stack creates has to say so.
  iam_role_permissions_boundary = local.boundary_policy_arn

  # Karpenter's EC2NodeClass selects security groups by tag. Tagging the node
  # shared security group here is what makes that selector resolve.
  node_security_group_tags = local.karpenter_discovery_tags

  # A small managed node group for the things Karpenter cannot schedule: the
  # Karpenter controller itself, CoreDNS, and the monitoring stack. See ADR 0035.
  eks_managed_node_groups = {
    system = {
      # AL2 EKS-optimized AMIs are out of support; AL2023 is the module's own
      # default and the value the EKS API expects.
      # https://docs.aws.amazon.com/eks/latest/APIReference/API_Nodegroup.html#AmazonEKS-Type-Nodegroup-amiType
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_instance_types
      capacity_type  = var.system_node_capacity_type

      min_size     = var.system_node_group_min_size
      max_size     = var.system_node_group_max_size
      desired_size = var.system_node_group_desired_size

      subnet_ids = module.vpc.private_subnets

      # The root volume is sized in block_device_mappings below, not with
      # `disk_size`. `disk_size` is only read when use_custom_launch_template is
      # false; setting block_device_mappings puts a custom launch template in
      # play, and the module then passes disk_size to the node group as null. Two
      # arguments that look like the same control, one of them inert, is how a
      # later edit silently does nothing.

      # Null until window 0 resolves a real release version; while it is null the
      # group tracks the latest release for its AMI type.
      ami_release_version            = var.system_node_ami_release_version
      use_latest_ami_release_version = var.system_node_ami_release_version == null

      labels = {
        (var.system_node_label_key) = var.system_node_label_value
      }

      # No taint. The platform layer's charts would all need a matching
      # toleration, and that stack is owned separately; a label plus a
      # nodeSelector puts the coupling in one direction only.

      iam_role_permissions_boundary = local.boundary_policy_arn

      # IMDSv2 only, and one hop, so a container off the host network cannot
      # reach the instance metadata service and borrow the node role.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
        instance_metadata_tags      = "disabled"
      }

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.system_node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }
}
