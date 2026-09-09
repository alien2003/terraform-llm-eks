output "state_bucket_name" {
  description = "Name of the Terraform state bucket. This is the value the cluster stack's backend.tf carries."
  value       = aws_s3_bucket.this["tfstate"].id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  value       = aws_s3_bucket.this["tfstate"].arn
}

output "weights_bucket_name" {
  description = "Name of the model weights bucket."
  value       = aws_s3_bucket.this["weights"].id
}

output "weights_bucket_arn" {
  description = "ARN of the model weights bucket."
  value       = aws_s3_bucket.this["weights"].arn
}

output "ecr_registry_url" {
  description = "Default private ECR registry URL for this account and Region."
  value       = local.ecr_registry_url
}

output "ecr_cache_repository_prefixes" {
  description = "Repository prefix per upstream registry, whether or not its cache rule has been created yet."
  value       = { for name, _ in local.pull_through_cache : name => "${var.ecr_cache_prefix}/${name}" }
}

output "ecr_cache_rules_created" {
  description = "Upstream registries that currently have a pull-through cache rule."
  value       = sort(keys(aws_ecr_pull_through_cache_rule.this))
}

output "dockerhub_credential_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Docker Hub credentials. The value is set by hand."
  value       = aws_secretsmanager_secret.dockerhub.arn
}

output "ssm_parameter_names" {
  description = "Every SSM parameter this stack publishes."
  value       = sort([for p in aws_ssm_parameter.bootstrap : p.name])
}
