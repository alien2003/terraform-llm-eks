locals {
  # Rule 2a: the sweeper and `mise run audit` both select on Project. An IAM role
  # this module creates that loses the tag is invisible to the safety net.
  tags = merge(
    {
      Project   = "terraform-llm-eks"
      Stack     = "cluster"
      ManagedBy = "terraform"
    },
    var.window_id == "" ? {} : { Window = var.window_id }
  )

  # Helm release names. They are load bearing: the kube-prometheus-stack chart
  # names the Prometheus Service `<release>-prometheus`, and the KEDA trigger has
  # to address that Service by name.
  kps_release_name       = "kube-prometheus-stack"
  prometheus_service_url = "http://${local.kps_release_name}-prometheus.${var.monitoring_namespace}.svc.cluster.local:9090"

  # Where the Grafana admin credentials land in the cluster. The chart mounts this
  # Secret; External Secrets writes it from the Secrets Manager secret named by
  # var.grafana_admin_secret_arn. Neither half is ever a literal in this repository.
  grafana_admin_secret_name = "grafana-admin"
  grafana_admin_user_key    = "admin-user"
  grafana_admin_pass_key    = "admin-password"
  cluster_secret_store_name = "aws-secretsmanager"

  # Service accounts that need AWS permissions. Each one gets an IAM role and an
  # EKS Pod Identity association; nothing here uses IRSA, and nothing here holds a
  # static credential.
  external_secrets_service_account = "external-secrets"
  inference_service_account        = "vllm"

  # Label value the GPU NodePool puts on the nodes it provisions. The inference
  # pod selects on it; nothing else in the cluster does.
  gpu_role_label_value = "gpu"

  # Exactly one of role or instanceProfile may be set on an EC2NodeClass.
  # https://karpenter.sh/docs/concepts/nodeclasses/ under spec.role and
  # spec.instanceProfile.
  node_instance_profile = var.karpenter_node_instance_profile_name
  node_iam_role         = var.karpenter_node_instance_profile_name == "" ? var.karpenter_node_iam_role_name : ""

  # The model prefix inside the weights bucket. `Qwen/Qwen2.5-7B-Instruct` becomes
  # `models/Qwen/Qwen2.5-7B-Instruct`, which is what `mise run` mirrors into.
  model_prefix = "models/${var.model_id}"
  model_uri    = "s3://${var.weights_bucket_name}/${local.model_prefix}"
}

locals {
  # Labels on every namespace this module creates, other than the Pod Security
  # Admission level, which is per namespace below.
  namespace_common_labels = {
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = "terraform-llm-eks"
  }

  # Pod Security Admission level per namespace. Read this before assuming these
  # labels protect anything: they do not. Only the `warn` label is set, on all four
  # namespaces, and `warn` enforces nothing. It makes the API server return a
  # warning to whoever submitted the pod and then admits the pod anyway. There is
  # no `enforce` label and no `audit` label anywhere in this module, so nothing in
  # this cluster is rejected on Pod Security grounds.
  #
  # `enforce` is deliberately absent rather than forgotten. A label one level too
  # tight rejects pods at admission during a paid window, and the workloads that
  # matter are the GPU ones, which cannot be tested without an accelerator. So the
  # labels stay at `warn`, the first window collects the warnings, and turning
  # `enforce` on is a decision made with that output in hand. It is item 6 of the
  # first-window list in this module's README.
  # https://kubernetes.io/docs/concepts/security/pod-security-admission/
  #
  # `monitoring` is `privileged` because the dcgm-exporter DaemonSet adds
  # SYS_ADMIN, runs as UID 0 and mounts a hostPath at
  # /var/lib/kubelet/pod-resources. Baseline permits none of that: SYS_ADMIN is
  # not in its capability allowlist, and it forbids HostPath volumes outright.
  # Any level below `privileged` would warn on every DCGM pod, which trains the
  # reader to ignore the warnings. The other three namespaces run ordinary
  # workloads and sit at `baseline`.
  # https://kubernetes.io/docs/concepts/security/pod-security-standards/
  namespace_psa_warn = {
    monitoring       = "privileged"
    external_secrets = "baseline"
    keda             = "baseline"
    inference        = "baseline"
  }
}
