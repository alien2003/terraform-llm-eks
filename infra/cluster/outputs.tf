# ------------------------------------------------------------------ network

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "availability_zones" {
  description = "Availability Zones the subnets were built in."
  value       = local.azs
}

output "gpu_capable_availability_zones" {
  description = "Zones EC2 currently offers every type in gpu_instance_types in. Pin availability_zones from this."
  value       = local.gpu_capable_azs
}

output "private_subnet_ids" {
  description = "Private subnet IDs. Every billable node runs in these."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs. The NAT gateway lives here."
  value       = module.vpc.public_subnets
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs. One entry per NAT Gateway-hour being billed."
  value       = module.vpc.natgw_ids
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "interface_endpoint_ids" {
  description = "Interface VPC endpoint IDs, by short service name. Each one bills per endpoint-hour."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

# ------------------------------------------------------------------ cluster

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version the control plane is running."
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded cluster CA certificate, for building a kubeconfig."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "ID of the security group this module created for the control plane."
  value       = module.eks.cluster_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "ID of the security group EKS itself created for the cluster."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "ID of the shared node security group. Carries the karpenter.sh/discovery tag."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider, or empty when enable_irsa is false."
  value       = var.enable_irsa ? module.eks.oidc_provider_arn : ""
}

output "cluster_iam_role_arn" {
  description = "ARN of the cluster IAM role."
  value       = module.eks.cluster_iam_role_arn
}

output "access_entries" {
  description = "Access entries on the cluster and their attributes."
  value       = module.eks.access_entries
}

output "system_node_group_iam_role_arn" {
  description = "ARN of the system managed node group's IAM role."
  value       = module.eks.eks_managed_node_groups["system"].iam_role_arn
}

output "system_node_selector" {
  description = "Label the platform layer should use as a nodeSelector to pin system workloads to the managed node group."
  value = {
    (var.system_node_label_key) = var.system_node_label_value
  }
}

# ------------------------------------------------------------------ Karpenter

output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller role. Associated with the controller's service account by Pod Identity."
  value       = module.karpenter.iam_role_arn
}

output "karpenter_node_role_name" {
  description = "Name of the role nodes Karpenter launches assume."
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_node_role_arn" {
  description = "ARN of the role nodes Karpenter launches assume."
  value       = module.karpenter.node_iam_role_arn
}

output "karpenter_instance_profile_name" {
  description = "Instance profile the platform layer's EC2NodeClass sets as spec.instanceProfile."
  value       = module.karpenter.instance_profile_name
}

output "karpenter_queue_name" {
  description = "Name of the SQS interruption queue."
  value       = module.karpenter.queue_name
}

output "karpenter_queue_arn" {
  description = "ARN of the SQS interruption queue."
  value       = module.karpenter.queue_arn
}

output "karpenter_event_rules" {
  description = "EventBridge rules feeding the interruption queue, by key."
  value       = module.karpenter.event_rules
}

output "karpenter_namespace" {
  description = "Namespace the Karpenter Pod Identity association was made in."
  value       = module.karpenter.namespace
}

output "karpenter_service_account" {
  description = "Service account the Karpenter Pod Identity association was made for."
  value       = module.karpenter.service_account
}

output "karpenter_discovery_tags" {
  description = "Tag the platform layer's EC2NodeClass selects subnets and security groups on."
  value       = local.karpenter_discovery_tags
}

output "gpu_instance_types" {
  description = "GPU instance types the platform layer's NodePool may request. Spot only; the boundary enforces that."
  value       = var.gpu_instance_types
}

# ------------------------------------------------------------------ publication

output "ssm_parameter_names" {
  description = "Every SSM parameter this stack publishes under /llm-eks/cluster/."
  value = sort(concat(
    [for p in aws_ssm_parameter.cluster : p.name],
    [for p in aws_ssm_parameter.cluster_lists : p.name],
  ))
}

# ------------------------------------------------------------ in-cluster layer

# Null while `platform_enabled` is false, which is what phase one of the apply
# looks like. `one()` rather than `[0]` so that reading an output during phase one
# gives null instead of an index error.

output "platform_enabled" {
  description = "Whether this apply included the in-cluster layer. False is phase one of the two-phase apply."
  value       = var.platform_enabled
}

output "grafana_service_name" {
  description = "Name of the Grafana Service. `mise run screenshot` port-forwards to it."
  value       = one(module.platform[*].grafana_service_name)
}

output "prometheus_service_url" {
  description = "In-cluster URL of the Prometheus the KEDA trigger queries and `mise run bench` scrapes."
  value       = one(module.platform[*].prometheus_service_url)
}

output "inference_service_name" {
  description = "Name of the inference Service. `mise run bench` and `mise run demo` address it."
  value       = one(module.platform[*].inference_service_name)
}

output "dashboard_uids" {
  description = "Grafana dashboard uids, for `mise run screenshot`."
  value       = one(module.platform[*].dashboard_uids)
}

output "model_uri" {
  description = "S3 URI the inference init container syncs the model weights from."
  value       = one(module.platform[*].model_uri)
}
