# Version pins for the guardrails stack.
#
# This stack is applied by hand with the administrator profile, a handful of times
# in the life of the project, and it is the last stack destroyed. It keeps local
# state on purpose: the bucket that would hold remote state is created by the
# bootstrap stack, and guardrails must outlive it. See docs/adr/0010.

terraform {
  required_version = "~> 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.63.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.8.0"
    }
  }
}
