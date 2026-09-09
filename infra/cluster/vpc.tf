# The VPC.
#
# Three private subnets, one per Availability Zone, sized /20 each. Everything with
# an hourly price runs in these: the managed node group, every node Karpenter
# launches, the control plane's cross-account network interfaces. Three public
# subnets, /24 each, hold the NAT gateway and nothing else unless an
# internet-facing load balancer is created later.
#
# The zones are the ones that offer the GPU types; see data.tf and ADR 0034.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.2"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # EKS refuses to register nodes in a VPC without both of these.
  # https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html
  enable_dns_hostnames = true
  enable_dns_support   = true

  # One NAT gateway for the whole VPC rather than one per zone. See ADR 0030.
  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = false

  # Nothing in the public subnets should get a public address by being launched
  # there. The NAT gateway carries its own Elastic IP.
  map_public_ip_on_launch = false

  enable_flow_log                                 = var.enable_vpc_flow_logs
  create_flow_log_cloudwatch_log_group            = var.enable_vpc_flow_logs
  create_flow_log_cloudwatch_iam_role             = var.enable_vpc_flow_logs
  flow_log_cloudwatch_log_group_retention_in_days = var.vpc_flow_logs_retention_in_days
  vpc_flow_log_permissions_boundary               = local.boundary_policy_arn

  # Subnet discovery. The AWS Load Balancer Controller reads the role tags; the
  # karpenter.sh/discovery tag on the private subnets is what the platform layer's
  # EC2NodeClass selects on. Sources are in locals.tf.
  public_subnet_tags  = local.public_subnet_tags
  private_subnet_tags = local.private_subnet_tags
}

# Gateway endpoint for S3. Model weights come out of the weights bucket and every
# container layer that is not in the pull-through cache comes out of S3 behind ECR,
# so this is the largest single flow through the NAT gateway. A gateway endpoint
# has no hourly and no data-processing charge, which is exactly why it is the
# always-on half of the endpoint decision. See ADR 0030.
#
# https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "${var.cluster_name}-s3"
  }
}

# Interface endpoints, off unless asked for. Each one bills per endpoint-hour per
# zone plus per GB processed, so for a window measured in hours a single NAT
# gateway is the cheaper shape. The variable exists so that a long-lived cluster,
# or a private-endpoint experiment, does not need a code change.
resource "aws_security_group" "vpc_endpoints" {
  count = length(var.interface_endpoint_services) > 0 ? 1 : 0

  name        = "${var.cluster_name}-vpc-endpoints"
  description = "Ingress to the interface VPC endpoints from inside the VPC"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.cluster_name}-vpc-endpoints"
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  count = length(var.interface_endpoint_services) > 0 ? 1 : 0

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS from inside the VPC"
  cidr_ipv4         = module.vpc.vpc_cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoint_services)

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = {
    Name = "${var.cluster_name}-${replace(each.value, ".", "-")}"
  }
}
