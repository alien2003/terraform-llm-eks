# The two project dashboards.
#
# The Grafana sidecar watches every namespace for ConfigMaps carrying the
# grafana_dashboard label and writes their contents into Grafana's provisioning
# directory, so a dashboard is a labelled ConfigMap and nothing more. That is also
# what `mise run screenshot` renders through the image renderer.
#
# `kubernetes_config_map_v1` is a typed resource; it is not `kubernetes_manifest`
# and needs no reachable API server at plan time. See ADR 0040.
#
# The JSON lives in dashboards/ rather than inside a chart because a Helm chart
# can only read files under its own directory, and these two are the deliverable,
# not an implementation detail of a chart.

resource "kubernetes_config_map_v1" "dashboards" {
  for_each = toset(["gpu", "inference"])

  metadata {
    name      = "llm-eks-dashboard-${each.key}"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

    labels = {
      # Watched by the Grafana sidecar. The key and value are set in
      # values/kube-prometheus-stack.yaml under grafana.sidecar.dashboards.
      grafana_dashboard = "1"

      "app.kubernetes.io/name"       = "llm-eks-dashboards"
      "app.kubernetes.io/part-of"    = "terraform-llm-eks"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    "${each.key}.json" = file("${path.module}/dashboards/${each.key}.json")
  }
}
