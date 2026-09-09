variable "region" {
  description = "Region this stack is applied in. Provisional; never hardcode it anywhere else."
  type        = string
  default     = "us-east-1"
}

variable "window_id" {
  description = <<-EOT
    Cloud window this apply belongs to, taken verbatim from the approval message.
    Empty outside a window. When set it becomes the Window tag on every resource,
    which is what lets the audit task tell one window's leftovers from another's.
  EOT
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also the value of the karpenter.sh/discovery tag."
  type        = string
  default     = "llm-eks"
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes minor version for the control plane, as `<major>.<minor>`. Must be a
    version in EKS standard support on the day the cluster is created; a version in
    extended support is billed at a higher hourly rate. See ADR 0032.
  EOT
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a major.minor string such as \"1.35\"."
  }
}

# ------------------------------------------------------------------ networking

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the VPC. Wide enough that the VPC CNI never runs the subnets out of addresses."
  type        = string
  default     = "10.42.0.0/16"

  # The subnet plan in locals.tf cuts one /20 and one /24 per zone out of this block
  # at fixed offsets, and the public /24s start at netnum 240, which needs eight bits
  # of room below the prefix. Two things go wrong without a bound here, and neither
  # is visible to `terraform validate`. Past /24 the netnum no longer fits and
  # `cidrsubnet` fails during `terraform plan`, which needs credentials, which means
  # inside a cloud window. Between /21 and /24 the arithmetic succeeds and the plan
  # is clean, but the public subnets come out narrower than the /28 that is the
  # smallest subnet AWS will create, so the failure moves to CreateSubnet, part way
  # through building the VPC. /20 is the last prefix where every subnet in the plan
  # is still a legal size, and AWS allows a /16 at the widest for an IPv4 VPC.
  # https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && can(regex("/(1[6-9]|20)$", var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block with a prefix length between /16 and /20. AWS allows /16 at the widest for a VPC, and past /20 the per-zone public /24s in the subnet plan come out smaller than the /28 minimum AWS accepts."
  }
}

variable "az_count" {
  description = <<-EOT
    Number of Availability Zones to build subnets in, when `availability_zones` is
    empty. EKS requires at least two. More zones means more Spot pools for the GPU
    NodePool to fall back on, at no standing cost, because there is one NAT gateway
    regardless.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6. EKS requires subnets in at least two Availability Zones."
  }
}

variable "availability_zones" {
  description = <<-EOT
    Explicit Availability Zone names to build in. Leave empty and the stack picks
    them: the zones that offer every type in `gpu_instance_types`, minus
    `excluded_zone_ids`, sorted, first `az_count`. Pin this list once window 0 has
    measured Spot prices per zone, so that a change in EC2's offering table can
    never renumber the subnets and replace the cluster. See ADR 0034.
  EOT
  type        = list(string)
  default     = []
}

variable "excluded_zone_ids" {
  description = <<-EOT
    Availability Zone IDs that must never be used. AWS documents three zone IDs that
    EKS cluster subnets cannot reside in, one of which, use1-az3, is in us-east-1.
  EOT
  type        = list(string)
  default     = ["use1-az3"]
}

variable "enable_nat_gateway" {
  description = "Give the private subnets a route to the internet through a NAT gateway."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = <<-EOT
    One NAT gateway for the whole VPC rather than one per zone. This is the cost
    decision in the network: a NAT gateway bills per NAT Gateway-hour whether or not
    anything is running behind it, plus its Elastic IP's public IPv4 address hourly
    charge. Three zones would mean three of each. The price is cross-zone data
    transfer for nodes outside the gateway's zone, and a single zone of egress
    failure. See ADR 0030.
  EOT
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = <<-EOT
    Short service names to create interface VPC endpoints for, for example
    ["ecr.api", "ecr.dkr", "sts"]. Empty by default: an interface endpoint bills per
    endpoint-hour in every zone it has an ENI in, plus per GB processed, so for a
    window measured in hours a single NAT gateway is cheaper than a set of them.
    The S3 gateway endpoint is always created and is not in this list, because
    gateway endpoints carry no hourly or data-processing charge. See ADR 0030.
  EOT
  type        = list(string)
  default     = []
}

variable "vpc_flow_logs_retention_in_days" {
  description = "Retention for the VPC flow log group. Ignored when flow logs are off."
  type        = number
  default     = 7
}

variable "enable_vpc_flow_logs" {
  description = "Publish VPC flow logs to CloudWatch Logs. Off by default: log ingestion is billed per GB."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------ cluster API

variable "endpoint_public_access" {
  description = <<-EOT
    Expose the Kubernetes API endpoint publicly. True because the operator drives
    this cluster from a laptop with no VPN and no bastion, and a private-only
    endpoint would need either an EC2 jump host, which bills by the hour, or an
    EKS API interface endpoint, which bills by the endpoint-hour. Narrow
    `endpoint_public_access_cidrs` instead of turning this off.
  EOT
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "Source CIDRs allowed to reach the public API endpoint. Narrow this to the operator's address."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_log_types" {
  description = <<-EOT
    Control plane log types to publish to CloudWatch Logs. Each one is billed on
    ingestion and storage, so this is the module's default set and no more.
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Retention for the control plane log group. The module's default is 90 days, which outlives the project."
  type        = number
  default     = 7
}

variable "enable_irsa" {
  description = <<-EOT
    Create the cluster's IAM OIDC provider. Everything this project associates uses
    EKS Pod Identity instead, but an OIDC provider carries no charge and leaves a
    route open for a chart that only supports IRSA. See ADR 0031.
  EOT
  type        = bool
  default     = true
}

variable "addon_versions" {
  description = <<-EOT
    Exact addon version per addon name, for example
    { coredns = "v1.12.4-eksbuild.1" }. Empty by default because a valid version
    string depends on the cluster's Kubernetes version and cannot be written from
    memory. An addon with no entry here resolves to the most recent version at
    apply time; run `aws eks describe-addon-versions` in window 0 and pin them.
  EOT
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------ system nodes

variable "system_instance_types" {
  description = <<-EOT
    Instance types for the managed node group that carries Karpenter, CoreDNS and
    the monitoring stack. Must be a subset of the system list in the operator
    permission boundary, which denies every type outside its whitelist.
  EOT
  type        = list(string)
  default     = ["t3.medium", "m7i.large"]
}

variable "system_node_group_min_size" {
  description = "Minimum size of the system node group."
  type        = number
  default     = 2
}

variable "system_node_group_max_size" {
  description = "Maximum size of the system node group."
  type        = number
  default     = 3
}

variable "system_node_group_desired_size" {
  description = <<-EOT
    Desired size of the system node group. Two, so that the Karpenter deployment's
    replicas can sit on separate nodes and so that losing one node does not take
    CoreDNS with it. This is the standing per-hour compute cost of an open window
    before any GPU node exists.
  EOT
  type        = number
  default     = 2
}

variable "system_node_capacity_type" {
  description = <<-EOT
    ON_DEMAND or SPOT for the system node group. On demand, because Karpenter cannot
    reschedule the node Karpenter itself runs on. See ADR 0035.
  EOT
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.system_node_capacity_type)
    error_message = "system_node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "system_node_disk_size" {
  description = "Root EBS volume size in GiB for a system node. Billed per provisioned GiB-month whether used or not."
  type        = number
  default     = 40
}

variable "system_node_ami_release_version" {
  description = <<-EOT
    Exact EKS optimized AMI release version for the system node group, for example
    "1.35.0-20260115". Null by default because a valid release version depends on
    the Kubernetes version and cannot be written from memory; while it is null the
    node group tracks the latest release for its AMI type. Record the value window 0
    resolves and pin it here.
  EOT
  type        = string
  default     = null
}

variable "system_node_label_key" {
  description = "Label key the platform layer uses as a nodeSelector to keep system workloads on the managed node group."
  type        = string
  default     = "llm-eks.io/role"
}

variable "system_node_label_value" {
  description = "Label value for system nodes."
  type        = string
  default     = "system"
}

# ------------------------------------------------------------------ Karpenter

variable "gpu_instance_types" {
  description = <<-EOT
    GPU instance types the GPU NodePool will be allowed to ask for. Used here for
    two things only: choosing the Availability Zones that actually offer them, and
    publishing the list for the platform layer's NodePool. The boundary is what
    enforces the whitelist and the Spot-only rule.
  EOT
  type        = list(string)
  default     = ["g6.xlarge", "g6.2xlarge"]

  validation {
    condition     = length(var.gpu_instance_types) > 0
    error_message = "gpu_instance_types must name at least one type; the Availability Zone selection is derived from it."
  }
}

variable "karpenter_queue_name" {
  description = "Name of the SQS interruption queue. Fixed by the project naming table."
  type        = string
  default     = "llm-eks-karpenter-interruption"
}

variable "karpenter_namespace" {
  description = "Namespace the Karpenter controller runs in. Also half of the Pod Identity association."
  type        = string
  default     = "kube-system"
}

variable "karpenter_service_account" {
  description = "Service account the Karpenter controller runs as. Also half of the Pod Identity association."
  type        = string
  default     = "karpenter"
}

# ------------------------------------------------------------------ platform

variable "platform_enabled" {
  description = <<-EOT
    Whether this apply includes the in-cluster layer in `platform/`.

    This is the two-phase apply, and it is not a preference. The `kubernetes`
    provider cannot be configured from a value the same apply creates, so the
    first apply of an empty state runs with this false and builds the VPC, the
    cluster, Karpenter's AWS side and the SSM parameters, and the second runs with
    the default and installs everything inside the cluster. Once the cluster is in
    state its endpoint is a known value and every later plan, including the destroy
    `mise run down` runs, works with the default.

    Which is why the default is true rather than false: a destroy with this off
    would try to remove the in-cluster resources through a provider pointed at a
    host that does not exist, and a teardown that cannot finish is the worst
    outcome the window protocol has. The flag is only ever passed on the first
    apply. providers.tf has the measurement, the README has the sequence, and
    ADR 0037 has the decision.
  EOT
  type        = bool
  default     = true
}

variable "grafana_admin_secret_arn" {
  description = <<-EOT
    ARN of the Secrets Manager secret holding the Grafana administrator
    credentials, as a JSON object with `username` and `password` keys. External
    Secrets reads it; the password is never in this repository, in a chart value or
    in Terraform state. ADR 0042.

    Empty by default and required when `platform_enabled` is true, because the
    secret is created by hand inside a window and its ARN cannot be derived: AWS
    appends a hyphen and six random characters to the name, which is what makes the
    ARN unique across a delete and recreate.
    https://docs.aws.amazon.com/secretsmanager/latest/userguide/troubleshoot.html

    The check runs at plan time rather than at `terraform validate`, because it
    reads a second variable. That is deliberate: CI validates this stack with no
    inputs at all and must stay green, while a window's plan must not reach an
    apply without it.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = !var.platform_enabled || can(regex("^arn:[a-z0-9-]+:secretsmanager:", var.grafana_admin_secret_arn))
    error_message = "grafana_admin_secret_arn must be the full ARN of the Grafana administrator secret when platform_enabled is true. Create the secret inside the window and pass its ARN; it cannot be derived from the name."
  }
}

# ------------------------------------------------------------------ identities

variable "operator_role_name" {
  description = "Name of the operator role created by infra/guardrails. It gets a cluster-admin access entry."
  type        = string
  default     = "llm-eks-operator"
}

variable "boundary_policy_name" {
  description = <<-EOT
    Name of the operator permission boundary created by infra/guardrails. The
    boundary denies iam:CreateRole unless the new role carries this exact policy as
    its own boundary, so every role this stack creates must be given it.
  EOT
  type        = string
  default     = "llm-eks-operator-boundary"
}

variable "additional_access_entries" {
  description = "Extra EKS access entries, merged over the operator entry this stack always creates."
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string))
    user_name         = optional(string)
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        namespaces = optional(list(string))
        type       = string
      })
    })), {})
  }))
  default = {}
}
