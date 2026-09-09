# Cross-stack values for the platform layer.
#
# The platform layer reads these with an SSM data source rather than a remote
# state data source. That keeps the two stacks from sharing a state file, and it
# gives me values I can read with the CLI in the middle of a window without
# running Terraform. Same pattern the bootstrap stack uses; see ADR 0022.
#
# Every value here is a plain, non-secret identifier.
resource "aws_ssm_parameter" "cluster" {
  for_each = local.ssm_string_parameters

  name  = "/llm-eks/cluster/${each.key}"
  type  = "String"
  value = each.value
  tier  = "Standard"

  description = "Published by the cluster stack for the platform layer to read."
}

resource "aws_ssm_parameter" "cluster_lists" {
  for_each = local.ssm_stringlist_parameters

  name  = "/llm-eks/cluster/${each.key}"
  type  = "StringList"
  value = join(",", each.value)
  tier  = "Standard"

  description = "Published by the cluster stack for the platform layer to read."
}
