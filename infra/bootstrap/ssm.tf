# Cross-stack values.
#
# The cluster stack needs the state bucket name for its backend, the weights
# bucket name for the model puller, and the cache prefixes for its image
# references. It cannot read them out of this stack's state, because this stack
# keeps that state locally. Publishing them as SSM parameters under
# /llm-eks/bootstrap/ gives the consumer a plain data source and gives me
# something I can read with the CLI during a window. See ADR 0022.
#
# Every value here is a plain, non-secret string.
resource "aws_ssm_parameter" "bootstrap" {
  for_each = local.ssm_parameters

  name  = "/llm-eks/bootstrap/${each.key}"
  type  = "String"
  value = each.value
  tier  = "Standard"

  description = "Published by the bootstrap stack for the cluster stack to read."
}
