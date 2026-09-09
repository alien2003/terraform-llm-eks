# IAM for the two service accounts in this layer that talk to AWS.
#
# Both use EKS Pod Identity rather than IRSA: the association is a cluster-side
# object keyed on namespace and service account name, so the role's trust policy
# is the same two lines every time and there is no OIDC audience or subject to
# get wrong. The Pod Identity agent is installed by the cluster stack as an
# addon, before compute. See ADR 0041.
#
# Every role carries the operator permission boundary. The boundary denies
# iam:CreateRole unless the new role's PermissionsBoundary is exactly that
# policy, so leaving it off does not produce a weaker role, it produces an
# AccessDenied.

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    sid     = "EksPodIdentityAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ------------------------------------------------------------ External Secrets

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "ReadGrafanaAdminSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = [var.grafana_admin_secret_arn]
  }
}

resource "aws_iam_role" "external_secrets" {
  name                 = "${var.cluster_name}-external-secrets"
  description          = "Read the Grafana administrator secret. Assumed by the external-secrets controller through EKS Pod Identity."
  assume_role_policy   = data.aws_iam_policy_document.pod_identity_trust.json
  permissions_boundary = var.boundary_policy_arn
  tags                 = local.tags
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-grafana-admin-secret"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = var.cluster_name
  namespace       = var.external_secrets_namespace
  service_account = local.external_secrets_service_account
  role_arn        = aws_iam_role.external_secrets.arn
  tags            = local.tags

  depends_on = [kubernetes_namespace_v1.external_secrets]
}

# ------------------------------------------------------------------- inference

data "aws_iam_policy_document" "inference" {
  statement {
    sid       = "ListModelPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.weights_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.model_prefix}/*", local.model_prefix]
    }
  }

  statement {
    sid       = "ReadModelObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.weights_bucket_name}/${local.model_prefix}/*"]
  }
}

resource "aws_iam_role" "inference" {
  name                 = "${var.cluster_name}-inference"
  description          = "Read model weights from the weights bucket. Assumed by the vLLM pod through EKS Pod Identity."
  assume_role_policy   = data.aws_iam_policy_document.pod_identity_trust.json
  permissions_boundary = var.boundary_policy_arn
  tags                 = local.tags
}

resource "aws_iam_role_policy" "inference" {
  name   = "read-model-weights"
  role   = aws_iam_role.inference.id
  policy = data.aws_iam_policy_document.inference.json
}

resource "aws_eks_pod_identity_association" "inference" {
  cluster_name    = var.cluster_name
  namespace       = var.inference_namespace
  service_account = local.inference_service_account
  role_arn        = aws_iam_role.inference.arn
  tags            = local.tags

  depends_on = [kubernetes_namespace_v1.inference]
}
