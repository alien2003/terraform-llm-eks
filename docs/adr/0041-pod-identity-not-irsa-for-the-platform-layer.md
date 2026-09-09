# 0041. The platform layer's AWS access is EKS Pod Identity, not IRSA

Date: 2026-09-09

## Status

Accepted.

## Context

Two pods in this layer talk to AWS. The External Secrets controller reads one secret from Secrets
Manager, and the vLLM pod's init container reads one prefix from the weights bucket. Each needs an
IAM role.

There are two ways to give a pod a role on EKS. IAM Roles for Service Accounts binds the role's trust
policy to the cluster's OIDC provider, matching on an audience and a subject string of the form
`system:serviceaccount:<namespace>:<name>`; the service account then carries an annotation naming the
role ARN. EKS Pod Identity instead creates an association object in the EKS API keyed on cluster,
namespace and service account name, and the role trusts the `pods.eks.amazonaws.com` service
principal.

## Decision

Both roles use EKS Pod Identity. Their trust policy is the same single-statement document, produced
once in `iam.tf` and shared: one `Allow` carrying two actions, `sts:AssumeRole` and `sts:TagSession`,
for the `pods.eks.amazonaws.com` service principal. That is the shape AWS documents for Pod Identity,
and both actions belong in it: EKS Auth calls `AssumeRole` to get the credentials it passes to the pod,
and `TagSession` to include the session tags in its request to STS. Those tags name the cluster,
namespace and service account, so they are also what a narrower trust policy would put a condition on if
this layer ever needs one. The association is an `aws_eks_pod_identity_association` resource. No service
account in this layer carries an `eks.amazonaws.com/role-arn` annotation.

The cluster stack installs the `eks-pod-identity-agent` addon before compute, so the agent is running
before any of these pods can be scheduled.

## Consequences

The trust policy stops being a place to make mistakes. With IRSA, a typo in the subject string
produces a role that exists, looks right, and denies every call at runtime with a message about the
web identity token; the failure is at the far end of a long chain. With Pod Identity the association
either exists for that namespace and service account or it does not, and `aws eks
list-pod-identity-associations` answers the question directly.

The role can be reused across clusters without being rewritten, because nothing in it names an OIDC
provider.

The cost is a dependency on the agent DaemonSet. If it is not running, the pod gets no credentials at
all rather than falling back to the node role, which is the failure mode I prefer: a node role that
quietly satisfies an S3 read is exactly the sort of accident this project is trying not to have.

The cluster stack still creates an OIDC provider (`enable_irsa`), because it costs nothing and leaves
a route open for a chart that only supports IRSA. Nothing here uses it.

## Sources

- Amazon EKS User Guide, the trust policy required by EKS Pod Identity: one statement, the
  `pods.eks.amazonaws.com` service principal, and both `sts:AssumeRole` ("to assume the IAM role before
  passing the temporary credentials to your pods") and `sts:TagSession` ("to include session tags in the
  requests to AWS STS"):
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-id-role.html>
- Amazon EKS User Guide, comparing Pod Identity and IRSA:
  <https://docs.aws.amazon.com/eks/latest/userguide/service-accounts.html>
