# Namespaces are Terraform resources rather than `create_namespace` on the Helm
# releases. Two releases share the monitoring namespace, and `create_namespace`
# gives no ordering guarantee between them; a namespace resource does, and it is
# also what the Pod Identity associations depend on.
#
# `kubernetes_namespace_v1` is a typed resource with a schema the provider knows
# at plan time. It is not `kubernetes_manifest`, which would need a reachable API
# server during plan. See ADR 0040.
#
# The only Pod Security Admission label set below is `warn`, which enforces
# nothing: every pod is admitted, warnings and all. See local.namespace_psa_warn
# in locals.tf for why `enforce` is absent and when it gets turned on.

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = var.monitoring_namespace
    labels = merge(local.namespace_common_labels, {
      "pod-security.kubernetes.io/warn" = local.namespace_psa_warn.monitoring
    })
  }
}

resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = var.external_secrets_namespace
    labels = merge(local.namespace_common_labels, {
      "pod-security.kubernetes.io/warn" = local.namespace_psa_warn.external_secrets
    })
  }
}

resource "kubernetes_namespace_v1" "keda" {
  metadata {
    name = var.keda_namespace
    labels = merge(local.namespace_common_labels, {
      "pod-security.kubernetes.io/warn" = local.namespace_psa_warn.keda
    })
  }
}

resource "kubernetes_namespace_v1" "inference" {
  metadata {
    name = var.inference_namespace
    labels = merge(local.namespace_common_labels, {
      "pod-security.kubernetes.io/warn" = local.namespace_psa_warn.inference
    })
  }
}
