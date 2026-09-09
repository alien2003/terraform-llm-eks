# Prometheus, Grafana and the image renderer, then the two GPU DaemonSets that
# feed them.

resource "helm_release" "kube_prometheus_stack" {
  name       = local.kps_release_name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [
    templatefile("${path.module}/values/kube-prometheus-stack.yaml", {
      prometheus_retention      = var.prometheus_retention
      prometheus_storage_size   = var.prometheus_storage_size
      system_label_key          = var.system_node_label_key
      system_label_value        = var.system_node_label_value
      grafana_admin_secret_name = local.grafana_admin_secret_name
      grafana_admin_user_key    = local.grafana_admin_user_key
      grafana_admin_pass_key    = local.grafana_admin_pass_key
      image_renderer_tag        = var.grafana_image_renderer_tag
    })
  ]

  # Grafana mounts the Secret by name at pod start, so the ExternalSecret that
  # writes it has to have run first.
  depends_on = [helm_release.secrets]

  # The chart brings a large set of CRDs and a webhook. Fifteen minutes is the
  # time a cold install takes on a two-node managed group, not a guess at how
  # long it should take.
  wait    = true
  timeout = 900
  atomic  = true
}

# The device plugin is what makes a GPU node usable at all: Karpenter does not
# consider the node initialized until something advertises nvidia.com/gpu on it.
# https://karpenter.sh/docs/concepts/scheduling/
resource "helm_release" "nvidia_device_plugin" {
  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  version    = var.nvidia_device_plugin_chart_version
  namespace  = var.karpenter_namespace

  values = [
    templatefile("${path.module}/values/nvidia-device-plugin.yaml", {
      gpu_taint_key = var.gpu_node_taint_key
    })
  ]

  # A DaemonSet with a node affinity no current node satisfies has zero pods and
  # never becomes ready, which is the normal state between windows. Waiting for
  # it would block the apply until a GPU node exists.
  wait    = false
  timeout = 600
}

resource "helm_release" "dcgm_exporter" {
  name       = "dcgm-exporter"
  repository = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart      = "dcgm-exporter"
  version    = var.dcgm_exporter_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [
    templatefile("${path.module}/values/dcgm-exporter.yaml", {
      gpu_taint_key = var.gpu_node_taint_key
    })
  ]

  # The chart creates a ServiceMonitor, so the Prometheus operator CRDs have to be
  # in place first.
  depends_on = [helm_release.kube_prometheus_stack]

  # Same as the device plugin: no GPU node, no pods, never ready.
  wait    = false
  timeout = 600
}
