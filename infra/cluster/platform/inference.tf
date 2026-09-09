# The workload itself.
#
# Last in the graph on purpose: it needs the GPU NodePool to exist before a pod
# can be placed, the KEDA CRDs before its ScaledObject applies, and the Prometheus
# operator CRDs before its ServiceMonitor does.

resource "helm_release" "inference" {
  name      = "llm-eks-inference"
  chart     = "${path.module}/charts/llm-eks-inference"
  namespace = kubernetes_namespace_v1.inference.metadata[0].name

  values = [
    templatefile("${path.module}/values/inference.yaml", {
      service_account            = local.inference_service_account
      vllm_image                 = var.vllm_image
      vllm_image_tag             = var.vllm_image_tag
      vllm_image_digest          = var.vllm_image_digest
      model_id                   = var.model_id
      model_max_len              = var.model_max_len
      gpu_memory_utilization     = var.gpu_memory_utilization
      weights_bucket             = var.weights_bucket_name
      model_prefix               = local.model_prefix
      weights_sync_image         = var.weights_sync_image
      weights_sync_image_tag     = var.weights_sync_image_tag
      service_port               = var.inference_service_port
      role_label_key             = var.system_node_label_key
      gpu_role_label_value       = local.gpu_role_label_value
      gpu_taint_key              = var.gpu_node_taint_key
      min_replicas               = var.inference_min_replicas
      max_replicas               = var.inference_max_replicas
      cooldown_period            = var.inference_cooldown_period
      prometheus_address         = local.prometheus_service_url
      queue_threshold            = var.inference_queue_threshold
      queue_activation_threshold = var.inference_queue_activation_threshold
    })
  ]

  depends_on = [
    helm_release.nodepools,
    helm_release.keda,
    aws_eks_pod_identity_association.inference,
  ]

  # Do not wait. With minReplicaCount 0 the deployment is expected to have no
  # ready pod at the end of an apply, and with it above zero the first pod waits
  # on a Spot node and a multi-gigabyte model load. Neither is an apply failure.
  wait    = false
  timeout = 900
}
