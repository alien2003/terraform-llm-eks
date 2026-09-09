# 0030. One NAT gateway and an S3 gateway endpoint, not a set of interface endpoints

Date: 2026-09-08

## Status

Accepted.

## Context

The nodes live in private subnets and have to reach things outside the VPC: ECR for images, S3 for
model weights, the EKS control plane, STS, SSM. There are three shapes that give them that reach, and
they bill in completely different ways.

A NAT gateway bills for each NAT Gateway-hour it is provisioned, plus a data-processing charge for
each gigabyte through it, plus standard data transfer, and its Elastic IP carries the public IPv4
address hourly charge. Every partial hour is billed as a full one.

An interface VPC endpoint bills per endpoint-hour in every Availability Zone it has a network
interface in, plus a data-processing charge per gigabyte. Six interface endpoints across three zones
is eighteen endpoint-hours an hour.

A gateway endpoint, which exists only for S3 and DynamoDB, has no hourly charge and no
data-processing charge at all.

The window protocol means this cluster exists for hours at a time, not months. Nothing here is a
steady-state cost model; it is a cost per window.

## Decision

`single_nat_gateway = true`. One NAT gateway for the whole VPC, in one public subnet, with the
private route tables in all zones pointing at it.

An S3 gateway endpoint, always, attached to every private route table.

Interface endpoints are off. `interface_endpoint_services` is an empty list by default and creates
them by short service name when it is not.

No VPC endpoint for the EKS API either. The Kubernetes API endpoint is public and narrowed by
`endpoint_public_access_cidrs`, because the alternative is a bastion instance or an interface
endpoint, and both bill by the hour for the whole window.

## Consequences

One NAT Gateway-hour and one public IPv4 address hour, instead of three of each. That is the single
largest standing cost in the network and it is now a third of what the per-zone shape would be.

The S3 gateway endpoint takes the largest flow off the NAT gateway's data-processing meter: the model
weights out of the weights bucket, and the container layers behind ECR, which are served from S3.
That flow is the one measured in gigabytes.

The costs are real, and they are two. Traffic from a node in a zone the NAT gateway is not in crosses
an Availability Zone boundary and is billed for it. And the single gateway is a single zone of egress
failure: if that zone goes, nothing in the VPC reaches the internet. Neither matters for a workload
that exists for the length of a window and is torn down, and both would matter for a production
cluster, which this is not.

Turning `single_nat_gateway` off is a one-line change if a later window shows cross-zone transfer
dominating, and the numbers to make that call go in `materials/costs/`.

## Sources

- Amazon VPC pricing, NAT Gateway section. "you are charged for each NAT Gateway-hour that your
  gateway is provisioned and available. Data processing charges apply for each gigabyte processed
  through the NAT gateway regardless of the traffic's source or destination. Each partial NAT
  Gateway-hour consumed is billed as a full hour."
  <https://aws.amazon.com/vpc/pricing/>
- Pricing for NAT gateways: "If most traffic through your NAT gateway is to AWS services that support
  interface endpoints or gateway endpoints, consider creating an interface endpoint or gateway
  endpoint for these services."
  <https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-pricing.html>
- Gateway endpoints for Amazon S3: "There is no additional charge for using gateway endpoints."
  <https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html>
- EKS Best Practices, Cost Optimization - Networking: "There are no hourly or data transfer costs
  associated with Gateway VPC Endpoints... VPC Endpoints have an hourly charge and have an additional
  charge associated with data processing via the underlying ENI."
  <https://docs.aws.amazon.com/eks/latest/best-practices/cost-opt-networking.html>
