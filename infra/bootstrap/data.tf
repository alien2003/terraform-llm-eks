data "aws_caller_identity" "current" {}

# Both bucket names carry the account ID as their suffix, which is what makes
# them globally unique. If this stack is ever applied against a different
# account the names would either collide with somebody else's bucket or quietly
# stop meaning what they say. A check block warns rather than fails, which is
# the right severity: the names are variables and can legitimately be overridden.
check "bucket_names_carry_this_account_id" {
  assert {
    condition = alltrue([
      endswith(var.state_bucket_name, data.aws_caller_identity.current.account_id),
      endswith(var.weights_bucket_name, data.aws_caller_identity.current.account_id),
    ])
    error_message = "state_bucket_name and weights_bucket_name should end with the account ID of the caller."
  }
}
