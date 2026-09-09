# 0034. Availability Zones are chosen by GPU offering, then pinned by hand

Date: 2026-09-08

## Status

Accepted.

## Context

Subnets are per Availability Zone, and the GPU NodePool can only ever launch into a subnet that sits
in a zone where EC2 actually offers `g6.xlarge` and `g6.2xlarge`. Taking the first three zones the
account can see, which is what most examples do, produces a VPC where one or two of the private
subnets are dead weight as far as the workload is concerned.

The obvious fix is to ask. `DescribeInstanceTypeOfferings` with `location_type=availability-zone`
returns exactly which zones offer a type, it is a read-only call, and Terraform can make it at plan
time through the `aws_ec2_instance_type_offerings` data source.

The obvious fix has a trap in it. If the zone list is derived from an API call on every plan, then a
change in EC2's offering table changes the order or the membership of `local.azs`, and the subnet CIDR
that was in zone A is now in zone B. Subnets are recreated. The cluster's network interfaces, the
node group and the cluster itself go with them. A plan that was supposed to be a no-op destroys the
cluster because Amazon added a zone.

There is also one zone that must never be used regardless: AWS documents three Availability Zone IDs
that EKS cluster subnets cannot reside in, and `use1-az3` is in `us-east-1`, the provisional region.
Zone IDs are stable per account; zone names are not, so the exclusion has to be by ID.

## Decision

Two data sources and one variable.

`aws_availability_zones` with `state = "available"`, `exclude_zone_ids = ["use1-az3"]` and an
`opt-in-status = opt-in-not-required` filter to drop Local Zones. One
`aws_ec2_instance_type_offerings` read per GPU type. `local.gpu_capable_azs` is the intersection of
all of them, sorted.

`var.availability_zones` overrides the lot. When it is empty, the stack takes the first `az_count`
entries of `gpu_capable_azs`. When it is set, that is what gets built.

Three guards, and two different mechanisms on purpose.

The two hard stops are `precondition` blocks in the `lifecycle` of a `terraform_data` resource whose
`input` is `local.azs`. The first fails when fewer than two usable zones came back, because EKS needs
subnets in at least two. The second fails when an entry in a pinned `availability_zones` is not in the
set of zones this account can use at all: a typo, a zone from another region, a Local Zone, or a zone
that `excluded_zone_ids` rules out.

The third guard, offering drift under a pinned list, is a `check` block, and it warns rather than
failing.

A `check` block could not do the first two jobs. A failed `assert` is a warning: Terraform prints it
and carries on planning, and carries on applying. A `precondition` is an error and the plan stops.
`local.azs` is derived only from variables and from data sources whose own configuration is fully
known, so it is resolved during the plan and both conditions are decided there rather than deferred to
apply.

`terraform_data` is what carries the preconditions because it creates nothing, calls no API and costs
nothing, and because keeping the zone list as its `input` also records in state which zones were
actually built in.

`gpu_capable_azs` is an output, so the value to pin is printed by the discovery run.

## Consequences

The first plan, in window 0, discovers the zones and prints them. The list gets written into
`terraform.tfvars` or the variable default, and from that point on the zone set is a decision in the
repository rather than the output of an API call. The subnets stop being able to move.

The offering-drift guard is deliberately a `check` block, and therefore only a warning. A pinned list
is a decision; if EC2 stops offering `g6.2xlarge` in one of the three zones, the right response is to
read the warning and decide, not to have Terraform renumber the network. The two preconditions are the
opposite case: neither of them describes a situation where carrying on could work.

The cost is one more thing that must not be forgotten between window 0 and window 1. It is in the
window plan and in this stack's README.

## Sources

- `aws_ec2_instance_type_offerings`: `location_type` valid values `availability-zone`,
  `availability-zone-id`, `region`; `locations` is exported alongside `instance_types`.
  <https://registry.terraform.io/providers/hashicorp/aws/6.63.0/docs/data-sources/ec2_instance_type_offerings>
- `aws_availability_zones`: `exclude_zone_ids`, and the documented filter for excluding Local Zones,
  `opt-in-status = opt-in-not-required`.
  <https://registry.terraform.io/providers/hashicorp/aws/6.63.0/docs/data-sources/availability_zones>
- EKS networking requirements, subnet requirements for clusters: "The subnets must be in at least two
  different Availability Zones", and the table of disallowed Availability Zone IDs which lists
  `use1-az3` for `us-east-1`.
  <https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html>
- `check` blocks: an assertion that fails produces a warning, not an error, and does not stop the plan
  or the apply. <https://developer.hashicorp.com/terraform/language/block/check>
- `precondition` blocks: a condition that evaluates to false is an error, and Terraform evaluates it
  during the plan when the values it depends on are known.
  <https://developer.hashicorp.com/terraform/language/expressions/custom-conditions>
- `terraform_data`: a resource with no infrastructure of its own, whose documented uses include
  carrying `lifecycle` blocks. <https://developer.hashicorp.com/terraform/language/resources/terraform-data>
