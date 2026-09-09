# The Karpenter controller, and then the NodePools it provisions against.
#
# The controller's IAM role, its Pod Identity association, the interruption queue
# and the node role all belong to the cluster stack's karpenter module. This
# module installs the chart and the custom resources, which is the part that
# cannot be expressed as an AWS resource.

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_chart_version
  namespace  = var.karpenter_namespace

  values = [
    templatefile("${path.module}/values/karpenter.yaml", {
      karpenter_service_account = var.karpenter_service_account
      cluster_name              = var.cluster_name
      cluster_endpoint          = var.cluster_endpoint
      interruption_queue        = var.karpenter_queue_name
      system_label_key          = var.system_node_label_key
      system_label_value        = var.system_node_label_value
    })
  ]

  # The chart creates a ServiceMonitor, which needs the Prometheus operator CRDs.
  depends_on = [helm_release.kube_prometheus_stack]

  wait    = true
  timeout = 600
  atomic  = true
}

# The NodePools and EC2NodeClasses, as a local chart rather than as
# `kubernetes_manifest` resources. See ADR 0040.
resource "helm_release" "nodepools" {
  name      = "llm-eks"
  chart     = "${path.module}/charts/llm-eks-nodepools"
  namespace = var.karpenter_namespace

  values = [
    templatefile("${path.module}/values/nodepools.yaml", {
      cluster_name                = var.cluster_name
      discovery_tag_key           = var.karpenter_discovery_tag_key
      ami_alias                   = var.ami_alias
      node_instance_profile       = local.node_instance_profile
      node_iam_role               = local.node_iam_role
      tags_json                   = jsonencode(local.tags)
      role_label_key              = var.system_node_label_key
      gpu_instance_types_json     = jsonencode(var.gpu_instance_types)
      gpu_taint_key               = var.gpu_node_taint_key
      gpu_cpu_limit               = var.gpu_nodepool_cpu_limit
      gpu_volume_size             = var.gpu_node_volume_size
      general_instance_types_json = jsonencode(var.general_instance_types)
      general_cpu_limit           = var.general_nodepool_cpu_limit
    })
  ]

  # The CRDs come with the controller chart.
  depends_on = [helm_release.karpenter]

  wait    = true
  timeout = 300
  atomic  = true
}
