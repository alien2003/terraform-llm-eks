locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  # Rule 2a: the sweeper and `mise run audit` select on Project. A resource that
  # loses this tag stops being visible to the safety net. Window is only set
  # inside a cloud window, and is what separates one window's leftovers from
  # another's.
  default_tags = merge(
    {
      Project   = "terraform-llm-eks"
      Stack     = "cluster"
      ManagedBy = "terraform"
    },
    var.window_id == "" ? {} : { Window = var.window_id }
  )

  # infra/guardrails keeps local state, so its outputs cannot be read with a
  # remote state data source. Both ARNs are deterministic from the account and the
  # names in the project naming table, which is how the other stacks reach them.
  boundary_policy_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${var.boundary_policy_name}"
  operator_role_arn   = "arn:${local.partition}:iam::${local.account_id}:role/${var.operator_role_name}"

  # Managed by AWS, not by this account. Documented at
  # https://docs.aws.amazon.com/eks/latest/userguide/access-policies.html
  eks_cluster_admin_policy_arn = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  # --------------------------------------------------------------- zone choice

  # Zones that offer every GPU type, and that the account can use. `locations`
  # holds zone names here because the data source was read with
  # location_type = "availability-zone".
  gpu_capable_azs = sort(setintersection(
    toset(data.aws_availability_zones.available.names),
    setintersection([for t in var.gpu_instance_types : toset(data.aws_ec2_instance_type_offerings.gpu[t].locations)]...)
  ))

  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    local.gpu_capable_azs,
    0,
    min(var.az_count, length(local.gpu_capable_azs))
  )

  # One /20 per zone for the private subnets, because pods take addresses from
  # them and the VPC CNI hands out whole /28 prefixes per node. One /24 per zone
  # for the public subnets, which hold nothing but the NAT gateway and any
  # internet-facing load balancer's ENIs.
  #
  # The two plans must not collide, and they are cut from the same /16 with
  # different prefix lengths, so the public block starts high instead of just
  # after the private one. az_count may be up to 6: the private /20s run to
  # 10.42.80.0/20 (10.42.80.0 - 10.42.95.255) at i = 5, and the public /24s start
  # at 10.42.240.0/24. An earlier layout put the public subnets at netnum 48,
  # which is inside the fourth private /20, so any az_count above 3 failed at
  # CreateSubnet with InvalidSubnet.Conflict part way through building the VPC.
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 240 + i)]

  # --------------------------------------------------------------- discovery

  # Karpenter finds subnets and security groups by tag. The key and the shape are
  # documented at https://karpenter.sh/docs/concepts/nodeclasses/ under
  # spec.subnetSelectorTerms and spec.securityGroupSelectorTerms.
  karpenter_discovery_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  # The AWS Load Balancer Controller finds subnets by role tag: elb for
  # internet-facing, internal-elb for internal.
  # https://docs.aws.amazon.com/eks/latest/userguide/tag-subnets-auto.html
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = merge(
    { "kubernetes.io/role/internal-elb" = "1" },
    local.karpenter_discovery_tags,
  )

  # --------------------------------------------------------------- addons

  # vpc-cni and the Pod Identity agent have to be running before the first node
  # joins: without the CNI a node never becomes Ready, and without the agent the
  # Karpenter controller has no credentials.
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  # An addon with a pinned version uses it; one without resolves to the most
  # recent version at apply time. See the addon_versions variable.
  addons_with_versions = {
    for name, cfg in local.addons :
    name => merge(
      cfg,
      contains(keys(var.addon_versions), name)
      ? { addon_version = var.addon_versions[name], most_recent = false }
      : {}
    )
  }

  # --------------------------------------------------------------- access

  access_entries = merge(
    {
      operator = {
        principal_arn = local.operator_role_arn
        type          = "STANDARD"
        policy_associations = {
          cluster_admin = {
            policy_arn = local.eks_cluster_admin_policy_arn
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    },
    var.additional_access_entries,
  )

  # ------------------------------------------------------- in-cluster providers

  # What the `kubernetes` and `helm` provider blocks in providers.tf are configured
  # from. The conditional is the two-phase apply: with `platform_enabled` false
  # there is no in-cluster resource in the graph and the providers only have to
  # configure cleanly, so they get a host that cannot resolve and no CA
  # certificate. With it true these are `module.eks` outputs, which are known
  # values once the cluster is in state and unknown before that, which is why phase
  # one exists at all. The reasoning and the measurement are in providers.tf.
  #
  # `.invalid` is reserved by RFC 2606 precisely so that a name is guaranteed never
  # to resolve, which is the property wanted here: if a phase-one plan ever did try
  # to reach an API server, it would fail loudly rather than reach something real.
  # https://www.rfc-editor.org/rfc/rfc2606#section-2
  unresolvable_kube_host = "https://kubernetes.invalid"

  platform_kube_host = var.platform_enabled ? module.eks.cluster_endpoint : local.unresolvable_kube_host

  # null is "attribute not set", which the provider accepts. An empty string is not:
  # it is parsed as a PEM bundle and rejected.
  platform_kube_ca_certificate = var.platform_enabled ? base64decode(module.eks.cluster_certificate_authority_data) : null

  # Only ever used to build the `aws eks get-token` argument list. In phase one the
  # exec plugin is never invoked, so the value only has to be a known string.
  platform_kube_cluster_name = var.platform_enabled ? module.eks.cluster_name : var.cluster_name

  # --------------------------------------------------------------- publication

  # Cross-stack values for the platform layer, published as SSM parameters under
  # /llm-eks/cluster/ as well as as outputs. The platform layer reads them with a
  # data source; I read them with the CLI during a window. See ADR 0022.
  ssm_string_parameters = merge(
    {
      "cluster-name"                         = module.eks.cluster_name
      "cluster-endpoint"                     = module.eks.cluster_endpoint
      "cluster-arn"                          = module.eks.cluster_arn
      "cluster-version"                      = module.eks.cluster_version
      "cluster-security-group-id"            = module.eks.cluster_security_group_id
      "cluster-primary-security-group-id"    = module.eks.cluster_primary_security_group_id
      "node-security-group-id"               = module.eks.node_security_group_id
      "region"                               = var.region
      "vpc-id"                               = module.vpc.vpc_id
      "vpc-cidr"                             = module.vpc.vpc_cidr_block
      "karpenter-queue-name"                 = module.karpenter.queue_name
      "karpenter-controller-role-arn"        = module.karpenter.iam_role_arn
      "karpenter-node-role-name"             = module.karpenter.node_iam_role_name
      "karpenter-node-role-arn"              = module.karpenter.node_iam_role_arn
      "karpenter-node-instance-profile-name" = module.karpenter.instance_profile_name
      "karpenter-namespace"                  = module.karpenter.namespace
      "karpenter-service-account"            = module.karpenter.service_account
      "karpenter-discovery-tag-key"          = "karpenter.sh/discovery"
      "karpenter-discovery-tag-value"        = var.cluster_name
      "system-node-label-key"                = var.system_node_label_key
      "system-node-label-value"              = var.system_node_label_value
    },

    # SSM refuses a parameter with an empty value, and there is no OIDC provider
    # ARN to publish when enable_irsa is off. So the key is added or left out
    # here rather than filtered out of a finished map further down. The
    # difference matters: ssm.tf uses this map as `for_each`, Terraform has to
    # know the key set at plan time, and every value in the map above is a module
    # output that is unknown until apply. A `for ... if v != ""` over those
    # values makes the whole map unknown and the plan fails outright with
    # "Invalid for_each argument". `var.enable_irsa` is an input, so it is known
    # at plan time and the key set stays static.
    # https://developer.hashicorp.com/terraform/language/meta-arguments/for_each
    var.enable_irsa ? { "oidc-provider-arn" = module.eks.oidc_provider_arn } : {},
  )

  # Same rule here. These four are always populated (az_count is at least 2 and
  # gpu_instance_types is validated non-empty), so there is nothing to filter and
  # the key set is written out flat.
  ssm_stringlist_parameters = {
    "private-subnet-ids" = module.vpc.private_subnets
    "public-subnet-ids"  = module.vpc.public_subnets
    "availability-zones" = local.azs
    "gpu-instance-types" = var.gpu_instance_types
  }
}
