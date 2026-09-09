# The in-cluster layer, as a child module.
#
# Everything that runs inside the cluster rather than next to it lives in
# `platform/`: Karpenter's chart and node pools, Prometheus and Grafana, the GPU
# exporters, KEDA, External Secrets and the vLLM deployment. It is a child module
# and not a stack of its own, so there is one state file, one backend and one place
# where the `kubernetes` and `helm` providers are configured. ADR 0037.
#
# The argument list below is the one platform/README.md writes out, because the
# module's variables were written against it. Two of them are worth pointing at:
#
#   window_id  is what puts the Window tag on the instances Karpenter launches. The
#              module builds its own tag map and adds Window only when this is
#              non-empty, and its EC2NodeClass `spec.tags` is what carries the map
#              onto a GPU node and its volume. Provider `default_tags` cannot reach
#              those, because Karpenter creates them, not Terraform. So an empty
#              window_id here means GPU capacity that the sweeper and the audit can
#              still see by Project but that no window can be billed against.
#
#   karpenter_node_instance_profile_name  and not karpenter_node_iam_role_name. A
#              module validation allows exactly one, and ADR 0033 says why it is
#              this one: a profile Karpenter generates for itself carries Karpenter's
#              tags rather than this project's.
#
# `karpenter_discovery_tag_key` is deliberately not passed. The module's default is
# the same `karpenter.sh/discovery` literal that locals.tf uses for the subnet and
# security group tags and that ssm.tf publishes, and Karpenter documents the key as
# fixed rather than configurable.
module "platform" {
  count = var.platform_enabled ? 1 : 0

  source = "./platform"

  region              = var.region
  cluster_name        = module.eks.cluster_name
  cluster_endpoint    = module.eks.cluster_endpoint
  boundary_policy_arn = local.boundary_policy_arn
  window_id           = var.window_id

  karpenter_namespace                  = var.karpenter_namespace
  karpenter_service_account            = var.karpenter_service_account
  karpenter_queue_name                 = module.karpenter.queue_name
  karpenter_node_instance_profile_name = module.karpenter.instance_profile_name

  gpu_instance_types     = var.gpu_instance_types
  general_instance_types = var.system_instance_types

  system_node_label_key   = var.system_node_label_key
  system_node_label_value = var.system_node_label_value

  # nonsensitive() rather than the bare value, and it is not cosmetic. The aws
  # provider marks `value` on the aws_ssm_parameter data source as sensitive for
  # every parameter type, and that mark travels: through this argument, through the
  # module's `model_uri` local, out of its output and into the root output of the
  # same name, where Terraform refuses an unmarked root output that carries
  # sensitive data. `terraform validate` does not see any of that; `terraform plan`
  # does, which would put the failure inside a window. The value itself is a bucket
  # name, published by infra/bootstrap as a plain String parameter whose own file
  # says every value there is a non-secret string.
  weights_bucket_name      = nonsensitive(one(data.aws_ssm_parameter.weights_bucket[*].value))
  grafana_admin_secret_arn = var.grafana_admin_secret_arn

  # The graph would order most of this correctly on its own through the arguments
  # above, but not all of it: the module's IAM roles and Pod Identity associations
  # reference the cluster by name only, and a Pod Identity association against a
  # cluster whose node group is not up yet is an association nothing can use. Both
  # dependencies are stated rather than inferred.
  depends_on = [module.eks, module.karpenter]
}
