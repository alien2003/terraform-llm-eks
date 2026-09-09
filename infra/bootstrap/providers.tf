# The tagging baseline.
#
# Every taggable resource in every stack carries Project, Stack and ManagedBy.
# `mise run audit` and the guardrails sweeper both select on
# Project=terraform-llm-eks, so an untagged resource is invisible to the safety
# net. That is why the tags are set once here through `default_tags` and never
# resource by resource.

provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }
}
