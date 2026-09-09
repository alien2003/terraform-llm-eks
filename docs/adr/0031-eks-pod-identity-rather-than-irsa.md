# 0031. EKS Pod Identity rather than IRSA

Date: 2026-09-08

## Status

Accepted.

## Context

Something in the cluster has to hold AWS permissions. The Karpenter controller needs to launch and
terminate instances and to read its interruption queue. Later, the model puller needs to read the
weights bucket. There are two supported mechanisms.

IAM Roles for Service Accounts (IRSA) works through an IAM OIDC identity provider created per
cluster. The role's trust policy names that provider and the service account inside it.

EKS Pod Identity works through an association resource on the cluster and a role that trusts the
`pods.eks.amazonaws.com` service principal. Credentials are delivered on the node by the
`eks-pod-identity-agent` addon.

Both were candidates. The eks module's karpenter submodule at 21.25.0 defaults to
`create_pod_identity_association = true`, which is a signal but not an argument.

## Decision

Every association this project creates uses EKS Pod Identity. The Karpenter controller gets a Pod
Identity association in `kube-system` for the `karpenter` service account, and the
`eks-pod-identity-agent` addon is installed with `before_compute = true` so the agent is on the node
before anything needs credentials.

`enable_irsa` stays true, so the cluster's IAM OIDC provider is created. It is not used by anything
this stack sets up.

## Consequences

The role trust policy is written once against a service principal and does not have to be rewritten
when the cluster is destroyed and recreated with a new OIDC issuer, which in a project that tears the
cluster down at the end of every window is the difference that actually shows up.

Pod Identity sets session tags, which means a later policy can be written against
`aws:PrincipalTag/kubernetes-namespace` instead of a hardcoded role per workload.

The costs: the Pod Identity agent is a DaemonSet, so it takes a pod slot and a little memory on every
node including the GPU ones; and an association only resolves once the agent is running, which is why
the addon ordering above is not optional.

Keeping the OIDC provider is a hedge, not a hesitation. An IAM OIDC provider carries no charge, the
account limit is 100 and this project has one cluster, and some upstream Helm charts still only
document the IRSA annotation. Leaving it there costs nothing and removes a whole class of
"the chart cannot be configured this way" dead end from a later window.

## Sources

- EKS Best Practices, Identity and Access Management: "Both EKS Pod Identities and IRSA are preferred
  ways to deliver temporary AWS credentials to your EKS pods. Unless you have specific usecases for
  IRSA, we recommend you use EKS Pod Identities when using EKS." The comparison table there is the
  source for the OIDC provider requirement, the session tags row and the agent DaemonSet row.
  <https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html>
- Amazon EKS Pod Identity announcement, comparison table: IRSA needs the role's trust policy updated
  with each new cluster's OIDC provider endpoint, while Pod Identity is a one-time trust with
  `pods.eks.amazonaws.com`; the IAM OIDC provider default limit is 100 per account.
  <https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/>
- terraform-aws-modules/eks/aws 21.25.0, `modules/karpenter`: `create_pod_identity_association`
  defaults to `true` and the submodule creates an `aws_eks_pod_identity_association`.
  <https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/21.25.0>
