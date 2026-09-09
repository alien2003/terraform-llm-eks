# ------------------------------------------------------------------ identity

variable "region" {
  description = "Region the cluster is in. Passed to the External Secrets store and to the weights sync."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also the value of the karpenter.sh/discovery tag."
  type        = string
}

variable "cluster_endpoint" {
  description = "API server endpoint. Karpenter puts it in the generated node bootstrap userdata."
  type        = string
}

variable "boundary_policy_arn" {
  description = <<-EOT
    ARN of the operator permission boundary. Every role this module creates carries
    it, because the boundary denies iam:CreateRole for a role that does not.
  EOT
  type        = string
}

variable "window_id" {
  description = "Cloud window this apply belongs to. Empty outside a window. Becomes the Window tag."
  type        = string
  default     = ""
}

# ------------------------------------------------------------------ Karpenter

variable "karpenter_namespace" {
  description = "Namespace the Karpenter controller runs in. Must match the Pod Identity association the cluster stack created."
  type        = string
  default     = "kube-system"
}

variable "karpenter_service_account" {
  description = "Service account the Karpenter controller runs as. Must match the Pod Identity association the cluster stack created."
  type        = string
  default     = "karpenter"
}

variable "karpenter_queue_name" {
  description = "Name of the SQS interruption queue the cluster stack created. Karpenter drains a node when a Spot interruption notice arrives."
  type        = string
}

variable "karpenter_node_iam_role_name" {
  description = <<-EOT
    Name of the node IAM role the cluster stack created. Used as EC2NodeClass
    spec.role when `karpenter_node_instance_profile_name` is empty; the two are
    mutually exclusive and exactly one must be set.
  EOT
  type        = string
  default     = ""
}

variable "karpenter_node_instance_profile_name" {
  description = "Name of the node instance profile the cluster stack created. Used as EC2NodeClass spec.instanceProfile. Takes precedence over the role name."
  type        = string
  default     = ""

  validation {
    condition = (
      (var.karpenter_node_instance_profile_name == "") != (var.karpenter_node_iam_role_name == "")
    )
    error_message = "Set exactly one of karpenter_node_instance_profile_name or karpenter_node_iam_role_name. An EC2NodeClass rejects both together and cannot launch a node with neither."
  }
}

variable "karpenter_chart_version" {
  description = "Karpenter controller chart version, pulled from the OCI registry public.ecr.aws/karpenter."
  type        = string
  default     = "1.14.1"
}

variable "karpenter_discovery_tag_key" {
  description = "Tag key Karpenter selects subnets and security groups by."
  type        = string
  default     = "karpenter.sh/discovery"
}

# ------------------------------------------------------------------ node pools

variable "ami_alias" {
  description = <<-EOT
    EC2NodeClass amiSelectorTerms alias, as `family@version`. An alias resolves the
    EKS optimized AMI for the instance type, which is how the GPU pool gets the
    accelerated AL2023 variant without a second AMI selector. Pinned to a release
    tag rather than `latest`, because with `latest` a new AMI release drifts every
    node in the cluster. Release tags are the GitHub release tags of
    awslabs/amazon-eks-ami; confirm the tag exists for this Kubernetes version in
    window 0 before the first apply.
  EOT
  type        = string
  default     = "al2023@v20260903"

  validation {
    condition     = can(regex("^(al2|al2023|bottlerocket|windows2019|windows2022|windows2025)@", var.ami_alias))
    error_message = "ami_alias must be one of the documented families followed by @version."
  }
}

variable "gpu_instance_types" {
  description = <<-EOT
    Instance types the GPU NodePool may ask for. Must be a subset of the GPU half of
    the operator boundary whitelist; the boundary denies anything else and denies
    these on demand.
  EOT
  type        = list(string)
  default     = ["g6.xlarge", "g6.2xlarge"]

  validation {
    condition     = length(var.gpu_instance_types) > 0
    error_message = "gpu_instance_types must name at least one type."
  }
}

variable "general_instance_types" {
  description = "Instance types the general NodePool may ask for. The system half of the boundary whitelist."
  type        = list(string)
  default     = ["t3.medium", "m7i.large"]
}

variable "gpu_node_taint_key" {
  description = "Taint key on GPU nodes, so that nothing but the inference workload and the GPU DaemonSets lands on an accelerator."
  type        = string
  default     = "nvidia.com/gpu"
}

variable "gpu_nodepool_cpu_limit" {
  description = <<-EOT
    Upper bound on total vCPU the GPU NodePool may provision, as a NodePool
    spec.limits entry. This is the second brake after the permission boundary: the
    boundary stops the wrong instance type, this stops too many of the right one.
  EOT
  type        = number
  default     = 8
}

variable "general_nodepool_cpu_limit" {
  description = "Upper bound on total vCPU the general NodePool may provision."
  type        = number
  default     = 16
}

variable "gpu_node_volume_size" {
  description = <<-EOT
    Root EBS volume for a GPU node, as a Kubernetes quantity string. It has to hold
    the vLLM image and a full copy of the model weights staged out of S3, so it is
    considerably larger than a system node's. Billed per provisioned GiB-month.
  EOT
  type        = string
  default     = "120Gi"
}

variable "system_node_label_key" {
  description = "Label key the managed node group carries. Everything in the platform layer that must not sit on a GPU node selects on it."
  type        = string
  default     = "llm-eks.io/role"
}

variable "system_node_label_value" {
  description = "Label value for system nodes."
  type        = string
  default     = "system"
}

# ------------------------------------------------------------------ monitoring

variable "monitoring_namespace" {
  description = "Namespace for Prometheus, Grafana, the image renderer and the DCGM exporter."
  type        = string
  default     = "monitoring"
}

variable "kube_prometheus_stack_chart_version" {
  description = "kube-prometheus-stack chart version from the prometheus-community repository."
  type        = string
  default     = "90.0.0"
}

variable "dcgm_exporter_chart_version" {
  description = "dcgm-exporter chart version from NVIDIA's helm-charts repository."
  type        = string
  default     = "4.8.3"
}

variable "nvidia_device_plugin_chart_version" {
  description = <<-EOT
    NVIDIA device plugin chart version. Karpenter does not consider a GPU node
    initialized until a device plugin advertises nvidia.com/gpu, so this is not
    optional on a cluster with a GPU NodePool.
  EOT
  type        = string
  default     = "0.20.0"
}

variable "grafana_image_renderer_tag" {
  description = "Image tag for the Grafana image renderer. `mise run screenshot` renders every published dashboard through it, so it is part of the stack, not an extra."
  type        = string
  default     = "v5.12.3"
}

variable "prometheus_retention" {
  description = "How long Prometheus keeps samples. A window is measured in hours and the raw output is copied out to materials/measurements before teardown, so this is short on purpose."
  type        = string
  default     = "24h"
}

variable "prometheus_storage_size" {
  description = <<-EOT
    Size limit of the emptyDir Prometheus writes its TSDB to, as a Kubernetes
    quantity string. Not a PersistentVolumeClaim: the cluster stack installs no EBS
    CSI driver, so there is no StorageClass to provision one from and a
    volumeClaimTemplate would leave the pod Pending forever. The series live as long
    as the pod does, which for a window measured in hours is the whole story; the
    raw output is copied out to materials/measurements before teardown.
  EOT
  type        = string
  default     = "20Gi"
}

variable "grafana_admin_secret_arn" {
  description = <<-EOT
    ARN of the AWS Secrets Manager secret holding the Grafana administrator
    credentials, as a JSON object with `username` and `password` keys. Created
    inside a cloud window and referenced here by ARN only: the password never
    appears in this repository, in a chart value, or in Terraform state. External
    Secrets reads it and writes the in-cluster Secret the Grafana chart mounts.
  EOT
  type        = string
}

variable "external_secrets_namespace" {
  description = "Namespace for the External Secrets controller."
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_chart_version" {
  description = "external-secrets chart version from charts.external-secrets.io."
  type        = string
  default     = "2.10.0"
}

# ------------------------------------------------------------------ autoscaling

variable "keda_namespace" {
  description = "Namespace for the KEDA operator and its metrics adapter."
  type        = string
  default     = "keda"
}

variable "keda_chart_version" {
  description = "KEDA chart version from kedacore.github.io/charts."
  type        = string
  default     = "2.20.2"
}

variable "inference_min_replicas" {
  description = <<-EOT
    Lower bound KEDA scales the inference deployment to. Zero is the point of the
    exercise: at zero the last GPU pod goes away, Karpenter consolidates the node
    and the Spot bill stops. Read ADR 0046 before changing it; at zero the vLLM
    queue metric does not exist, so waking up is not automatic.
  EOT
  type        = number
  default     = 0
}

variable "inference_max_replicas" {
  description = "Upper bound KEDA scales the inference deployment to. One replica per GPU node, so this and gpu_nodepool_cpu_limit have to agree."
  type        = number
  default     = 2
}

variable "inference_queue_threshold" {
  description = "Target value for the vLLM waiting-queue metric, in requests per replica. KEDA adds replicas while the queue is above it."
  type        = string
  default     = "4"
}

variable "inference_queue_activation_threshold" {
  description = "Value the vLLM waiting-queue metric must exceed before KEDA activates the deployment from zero."
  type        = string
  default     = "0"
}

variable "inference_cooldown_period" {
  description = "Seconds KEDA waits after the last activity before scaling back to inference_min_replicas."
  type        = number
  default     = 300
}

# ------------------------------------------------------------------ inference

variable "inference_namespace" {
  description = "Namespace for the vLLM deployment."
  type        = string
  default     = "inference"
}

variable "vllm_image" {
  description = "vLLM server image repository."
  type        = string
  default     = "vllm/vllm-openai"
}

variable "vllm_image_tag" {
  description = "vLLM server image tag."
  type        = string
  default     = "v0.28.0"
}

variable "vllm_image_digest" {
  description = <<-EOT
    Digest of the vLLM image, pinned alongside the tag so that a retagged image
    cannot change what runs. Empty falls back to the tag alone.
  EOT
  type        = string
  default     = "sha256:61fc8a896b0a4fbbbdc063bc4b0dbc25ce98e02b5050c24aeb7830ac02039b14"
}

variable "weights_sync_image" {
  description = "Image for the init container that stages model weights out of S3. The AWS CLI image at the version repo/mise.toml pins."
  type        = string
  default     = "amazon/aws-cli"
}

variable "weights_sync_image_tag" {
  description = "Tag for the weights sync image."
  type        = string
  default     = "2.36.41"
}

variable "weights_bucket_name" {
  description = "Name of the model weights bucket created by infra/bootstrap. The init container syncs one prefix out of it."
  type        = string
}

variable "model_id" {
  description = <<-EOT
    Hugging Face repository id of the model to serve. It names the prefix inside the
    weights bucket and is what vLLM reports in the model_name label on every metric.
    The default is Apache-2.0 licensed and ungated, so the weights can be mirrored
    into the bucket without a token.
  EOT
  type        = string
  default     = "Qwen/Qwen2.5-7B-Instruct"
}

variable "model_max_len" {
  description = <<-EOT
    Context length vLLM is started with. Weights plus KV cache have to fit in the
    accelerator's memory, and on the smallest whitelisted GPU type there is not much
    room left after the weights. Raise it once a window has measured what fits.
  EOT
  type        = number
  default     = 8192
}

variable "gpu_memory_utilization" {
  description = "Fraction of accelerator memory vLLM is allowed to reserve, passed as --gpu-memory-utilization."
  type        = string
  default     = "0.90"
}

variable "inference_service_port" {
  description = "Port the inference Service listens on. vLLM's OpenAI-compatible server serves both the API and /metrics on it."
  type        = number
  default     = 8000
}
