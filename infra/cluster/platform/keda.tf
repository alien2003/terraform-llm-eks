resource "helm_release" "keda" {
  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = var.keda_chart_version
  namespace  = kubernetes_namespace_v1.keda.metadata[0].name

  values = [
    templatefile("${path.module}/values/keda.yaml", {
      system_label_key   = var.system_node_label_key
      system_label_value = var.system_node_label_value
    })
  ]

  # The chart creates ServiceMonitors for all three of its deployments.
  depends_on = [helm_release.kube_prometheus_stack]

  wait    = true
  timeout = 600
  atomic  = true
}
