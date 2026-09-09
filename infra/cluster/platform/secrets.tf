# External Secrets, and the one secret the platform layer needs from AWS.
#
# Order matters and is expressed with depends_on rather than left to Terraform's
# graph: the controller has to be running and its CRDs installed before the
# ClusterSecretStore and ExternalSecret are applied.
#
# What that ordering does NOT give is a guarantee that the `grafana-admin` Secret
# exists before kube-prometheus-stack mounts it by name. `wait = true` on the
# release below is best-effort only: Helm's --wait polls readiness for the kinds
# it knows how to check (Pod, PVC, Service, Deployment, StatefulSet, DaemonSet,
# ReplicaSet, ReplicationController, Job) and returns immediately for an
# arbitrary custom resource, and this chart's only two objects are custom
# resources. So the release returns as soon as the ClusterSecretStore and
# ExternalSecret are created, before the External Secrets controller has
# reconciled the ExternalSecret and written the Secret.
# https://helm.sh/docs/intro/using_helm/#helpful-options-for-installupgraderollback
#
# The consequence is bounded and self-healing: the Grafana pod can start into
# CreateContainerConfigError and the kubelet retries until the Secret appears, a
# few seconds later. If that ever becomes more than cosmetic, the fix is to gate
# on the Secret rather than on the release, either with a post-install Job in the
# secrets chart that waits for the ExternalSecret's SecretSynced condition plus
# wait_for_jobs, or with a kubernetes_secret_v1 data source between the two
# releases.

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.external_secrets_chart_version
  namespace  = kubernetes_namespace_v1.external_secrets.metadata[0].name

  values = [
    templatefile("${path.module}/values/external-secrets.yaml", {
      service_account    = local.external_secrets_service_account
      system_label_key   = var.system_node_label_key
      system_label_value = var.system_node_label_value
    })
  ]

  # The controller is useless until it can reach Secrets Manager, and it can only
  # do that once the Pod Identity association exists.
  depends_on = [aws_eks_pod_identity_association.external_secrets]

  wait          = true
  wait_for_jobs = true
  timeout       = 600
  atomic        = true
}

resource "helm_release" "secrets" {
  name      = "llm-eks-secrets"
  chart     = "${path.module}/charts/llm-eks-secrets"
  namespace = kubernetes_namespace_v1.external_secrets.metadata[0].name

  values = [
    templatefile("${path.module}/values/secrets.yaml", {
      store_name                = local.cluster_secret_store_name
      region                    = var.region
      monitoring_namespace      = kubernetes_namespace_v1.monitoring.metadata[0].name
      grafana_admin_secret_name = local.grafana_admin_secret_name
      grafana_admin_user_key    = local.grafana_admin_user_key
      grafana_admin_pass_key    = local.grafana_admin_pass_key
      grafana_admin_secret_arn  = var.grafana_admin_secret_arn
    })
  ]

  depends_on = [helm_release.external_secrets]

  wait    = true
  timeout = 300
  atomic  = true
}
