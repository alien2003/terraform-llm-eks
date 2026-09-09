data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Availability Zones this account can actually use, with Local Zones filtered out
# by opt-in status and the EKS-disallowed zone IDs removed by ID rather than by
# name, because the name-to-ID mapping is per account.
data "aws_availability_zones" "available" {
  state            = "available"
  exclude_zone_ids = var.excluded_zone_ids

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Which zones offer the GPU types. One read per type, intersected in locals.tf,
# because a zone that offers g6.xlarge does not necessarily offer g6.2xlarge and a
# subnet in a zone with no capacity is a subnet the GPU NodePool can never use.
#
# This is a read-only DescribeInstanceTypeOfferings call. It says what EC2 offers
# in a zone, not whether there is Spot capacity there right now; that question is
# answered with Spot price history in window 0.
data "aws_ec2_instance_type_offerings" "gpu" {
  for_each = toset(var.gpu_instance_types)

  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [each.value]
  }
}

# Two hard stops on the zone list, both of them things the apply cannot survive.
#
# EKS needs subnets in at least two Availability Zones. If the intersection above
# comes back with fewer, the region is wrong for this project and the apply has to
# stop at plan time rather than half way through a cluster: with one subnet the
# VPC builds and then CreateCluster fails with UnsupportedAvailabilityZoneException,
# inside a window that is already being billed. And a hand-pinned zone that this
# account cannot use at all fails the same way, earlier, at CreateSubnet.
#
# These are `lifecycle` preconditions and not `check` blocks on purpose. A check
# block assertion cannot stop anything: a failed assertion is a warning and the
# plan and the apply both carry on. A precondition on a resource is an error and
# the plan stops. `local.azs` is derived from variables and from data sources with
# no unknown inputs, so the data sources are read during the plan and both
# conditions are decided there rather than deferred to apply.
# https://developer.hashicorp.com/terraform/language/block/check
# https://developer.hashicorp.com/terraform/language/expressions/custom-conditions
#
# terraform_data is the built-in resource that exists for exactly this: it creates
# nothing, costs nothing and touches no API. Keeping the zone list as its input
# also puts the zones that were actually built in into state.
resource "terraform_data" "availability_zone_guard" {
  input = local.azs

  lifecycle {
    precondition {
      condition     = length(local.azs) >= 2
      error_message = "Fewer than two usable Availability Zones offer every type in gpu_instance_types. EKS needs subnets in at least two zones. Check the region, gpu_instance_types and excluded_zone_ids."
    }

    # A second precondition, and deliberately not folded into the offering-drift
    # `check` block below. Drift in EC2's offering table is a judgement call and
    # gets a warning. A pinned zone that is not in the account's usable set is not
    # a judgement call: it is a typo, a zone from another region, a Local Zone, or
    # a zone that excluded_zone_ids rules out, and every one of those fails at
    # CreateSubnet or inside CreateCluster, part way through building a VPC, in a
    # window that is already being billed. The set on the right has already had
    # excluded_zone_ids and the opt-in zones filtered out, and it is known during
    # the plan, so this is caught before anything is created.
    precondition {
      condition     = length(setsubtract(toset(local.azs), toset(data.aws_availability_zones.available.names))) == 0
      error_message = "One or more entries in availability_zones is not a zone this account can use. It must be available, must not require opt-in, and must not be in excluded_zone_ids. Compare the pinned list against the gpu_capable_availability_zones output."
    }
  }
}

# When the zone list is pinned by hand, this catches the case where the pin has
# drifted away from what EC2 actually offers. A warning is the whole intent here,
# which is what a `check` block gives: a pinned list is deliberate, and
# renumbering subnets to chase an offering table would replace the cluster.
check "pinned_zones_still_offer_gpu_capacity" {
  assert {
    condition     = length(setsubtract(toset(local.azs), toset(local.gpu_capable_azs))) == 0
    error_message = "Some pinned availability_zones no longer offer every type in gpu_instance_types."
  }
}

# ------------------------------------------------------------ platform inputs

# The weights bucket name, read from the parameter infra/bootstrap publishes. That
# stack keeps local state and cannot be read with a remote state data source, so an
# SSM parameter is the interface; ADR 0022.
#
# `count` is on it for the same reason `module.platform` has one: phase one of the
# apply builds the cluster and needs nothing from this parameter, and a data source
# read that fails because bootstrap has not been applied yet should not be able to
# stop the phase that does not use it. In phase two the parameter must exist, and if
# it does not the plan says which name it looked for.
data "aws_ssm_parameter" "weights_bucket" {
  count = var.platform_enabled ? 1 : 0

  name = "/llm-eks/bootstrap/weights-bucket"
}
