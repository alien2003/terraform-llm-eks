output "monitoring_namespace" {
  description = "Namespace Prometheus, Grafana and the image renderer run in."
  value       = kubernetes_namespace_v1.monitoring.metadata[0].name
}

output "inference_namespace" {
  description = "Namespace the vLLM deployment runs in."
  value       = kubernetes_namespace_v1.inference.metadata[0].name
}

output "prometheus_service_url" {
  description = "In-cluster URL of the Prometheus that answers the KEDA trigger query. Also what `mise run bench` scrapes afterwards."
  value       = local.prometheus_service_url
}

output "grafana_service_name" {
  description = "Name of the Grafana Service. `mise run screenshot` port-forwards to it."
  value       = "${local.kps_release_name}-grafana"
}

output "grafana_admin_secret_name" {
  description = "Name of the in-cluster Secret External Secrets writes the Grafana administrator credentials into."
  value       = local.grafana_admin_secret_name
}

output "inference_service_name" {
  description = "Name of the inference Service. `mise run bench` and `mise run demo` address it."
  value       = "vllm"
}

output "inference_service_port" {
  description = "Port the inference Service listens on."
  value       = var.inference_service_port
}

output "dashboard_uids" {
  description = "Grafana dashboard uids, for `mise run screenshot`."
  value = {
    gpu       = "llm-eks-gpu"
    inference = "llm-eks-inference"
  }
}

output "external_secrets_role_arn" {
  description = "ARN of the role the External Secrets controller assumes through EKS Pod Identity."
  value       = aws_iam_role.external_secrets.arn
}

output "inference_role_arn" {
  description = "ARN of the role the vLLM pod assumes through EKS Pod Identity to read the weights bucket."
  value       = aws_iam_role.inference.arn
}

output "model_uri" {
  description = "S3 URI the init container syncs the model weights from. The mirror step has to have put them there first."
  value       = local.model_uri
}
