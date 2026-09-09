variable "region" {
  description = "Region this stack is applied in. Provisional; never hardcode it anywhere else."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Name of the Terraform state bucket. The cluster stack's S3 backend points at this name."
  type        = string
  default     = "llm-eks-tfstate-288497659215"
}

variable "weights_bucket_name" {
  description = "Name of the model weights bucket."
  type        = string
  default     = "llm-eks-weights-288497659215"
}

variable "ecr_cache_prefix" {
  description = "Repository prefix under which every pull-through cache rule creates its repositories."
  type        = string
  default     = "llm-eks-cache"

  validation {
    # ecr_repository_prefix is 2-30 characters. Each rule appends "/<registry>",
    # and the longest suffix in locals.tf is "/kubernetes" (11 characters).
    condition     = length(var.ecr_cache_prefix) >= 2 && length(var.ecr_cache_prefix) <= 19
    error_message = "ecr_cache_prefix must be 2-19 characters so that prefix + \"/kubernetes\" stays inside the 30-character ECR limit."
  }
}

variable "enable_dockerhub_cache" {
  description = <<-EOT
    Create the Docker Hub pull-through cache rule. Leave this false on the first
    apply: the rule is only accepted once the Secrets Manager secret this stack
    creates actually holds a username/accessToken pair, and that value is put in
    by hand. Flip it to true on a later apply. See the README.
  EOT
  type        = bool
  default     = false
}

variable "state_noncurrent_version_expiration_days" {
  description = "Days a noncurrent state file version is kept before it expires."
  type        = number
  default     = 30
}

variable "state_noncurrent_versions_retained" {
  description = "Number of newer noncurrent state file versions kept regardless of age."
  type        = number
  default     = 10
}

variable "weights_noncurrent_version_expiration_days" {
  description = "Days a noncurrent weights object version is kept before it expires."
  type        = number
  default     = 7
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Days before S3 aborts an incomplete multipart upload and stops billing for its parts."
  type        = number
  default     = 3
}

variable "force_destroy_buckets" {
  description = <<-EOT
    Allow `terraform destroy` to delete the buckets while they still hold
    objects. False everywhere except the final teardown window, where the
    weights bucket holds tens of gigabytes that would otherwise have to be
    emptied by hand first.
  EOT
  type        = bool
  default     = false
}

variable "ecr_cache_images_retained" {
  description = "Images kept per repository created by the pull-through cache. Older ones expire."
  type        = number
  default     = 10
}
