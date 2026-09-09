# 0036. EKS secrets keep the default envelope encryption instead of a customer-managed KMS key

Date: 2026-09-09

## Status

Accepted.

## Context

`trivy config` raises AVD-AWS-0039, "EKS should have the encryption of secrets enabled", at HIGH. What
it checks for is literal: an `encryption_config` block on the `aws_eks_cluster` resource with `secrets`
in its `resources` list. It is raised against the eks module's own `main.tf`, not against a file in
`infra/cluster`, so an inline `#trivy:ignore` comment cannot reach it and the acceptance has to live in
`infra/cluster/.trivyignore`.

Before deciding anything I read what the module actually does when left alone, because the default here
is not "off". In `terraform-aws-modules/eks/aws` 21.25.0, `create_kms_key` defaults to `true` and
`encryption_config` defaults to `{}`, and the object type's own default fills in
`resources = ["secrets"]`. The module then computes
`enable_encryption_config = var.encryption_config != null`, emits the block, and takes the key ARN from
a nested call to `terraform-aws-modules/kms/aws` 4.0.0 with `enable_kms_key_rotation` defaulting to
true. It also creates an extra IAM policy and attaches it to the cluster role so the control plane can
call `kms:Encrypt`, `kms:Decrypt`, `kms:ListGrants` and `kms:DescribeKey` on that key. Turning it off
therefore takes two arguments, not one: the module gates the block on `encryption_config` being
non-null, so `create_kms_key = false` on its own would leave the block in place with an empty key ARN.

The more interesting part is what the check is asking for in 2026, because the answer has changed since
the check was written. From Kubernetes 1.28 onwards, EKS envelope-encrypts all Kubernetes API data by
default, using KMS v2 and a key encryption key that AWS owns. The API server wraps a cached data
encryption key seed with the KEK once at startup and again on KEK rotation, and derives a single-use
data encryption key per object from that seed before the object is written to etcd. AWS's own procedure
for adding a customer-managed key to an existing cluster now carries a deprecation notice saying it
applies only to 1.27 and lower. This cluster runs 1.35 (ADR 0032).

`trivy` reads HCL, so it cannot see any of that. A cluster with no `encryption_config` block and a
cluster with the default AWS-owned KEK look identical to the check, and they are not the same thing.

So the real question is not whether Kubernetes secrets are encrypted. It is who owns the key that
encrypts them.

## Decision

`create_kms_key = false` and `encryption_config = null`. The cluster keeps the AWS-owned KEK, and
AVD-AWS-0039 is suppressed in `infra/cluster/.trivyignore` with a reason that points here.

What a customer-managed key would add, honestly:

- A key whose policy, grants and enabled state this account controls, so the ability to unwrap the DEK
  seed can be revoked independently of the cluster and of the cluster IAM role.
- CloudTrail entries for `kms:Encrypt` and `kms:Decrypt` against a named key, attributable to a
  principal. With an AWS-owned key there is no key in this account to log against.
- Rotation of the KEK on a schedule this account sets rather than on AWS's.

What it costs. The pricing dimensions, with no figures, because Rule 5 applies and there is no
measurement file to trace a figure to yet; window 0's Cost Explorer export will carry the real line if
this is ever turned on:

- **Key storage.** AWS KMS bills each customer-managed key that you create, per month, prorated
  hourly, for as long as the key exists, whether or not anything uses it. AWS-owned keys are not
  billed at all.
- **Rotation.** For a key that rotates automatically or on demand, the first and second rotation each
  add to that monthly charge; the increase is capped after the second. The module turns rotation on by
  default.
- **Requests.** KMS API requests above the AWS KMS free tier are billed per request. Under KMS v2 the
  volume is small by construction: the API server wraps a cached seed at startup and on KEK rotation,
  not once per secret.

One thing I had wrong and want written down, because it was the stated reason for this decision before
I checked it. The comment in `eks.tf` used to say that a key scheduled for deletion keeps billing
through its 7 to 30 day waiting period, so `terraform destroy` would leave a paying resource behind.
That is not what AWS charges for. The KMS pricing page says there is no charge for a customer managed
key that is scheduled for deletion, and that cancelling the deletion during the waiting period makes
the key incur charges as though it had never been scheduled. Teardown does not leave a bill. The
comment has been corrected and this record exists partly so the wrong version does not come back.

The real teardown cost is smaller and different: one more resource in the destroy order, a key sitting
in the account for its waiting period, and an alias a later apply in the same region cannot reuse until
that period ends.

Why the default is accepted for now:

- Pointing a cluster at a customer-managed key is a one-way door. AWS documents that secrets
  encryption cannot be disabled once enabled and that the key cannot be changed afterwards. This
  project creates and destroys the cluster once per cloud window, so that would mean a new key per
  window, each with its own waiting period, and no way to walk a mistake back inside the window that
  made it.
- The blast radius points the wrong way. If the key is disabled or deleted, the control plane can no
  longer unwrap, and what is in etcd is unrecoverable. AWS's guidance for that risk is least-privilege
  key administration plus a CloudWatch alarm on key state, which is more guardrail surface than this
  project's threat model earns.
- What is actually secret here is not stored in Kubernetes. The Grafana admin password and the
  pull-through cache registry credential live in Secrets Manager and are referenced by ARN (ADR 0024,
  ADR 0042); model weights live in S3. There is no long-lived credential whose only copy is a
  Kubernetes Secret, which is the case a customer-managed KEK is really there to protect.
- Rule 2a. The operator role exists so that no single mistake can create a standing charge. A key that
  bills every month whether or not a window is open is exactly the shape of resource this project has
  decided not to leave lying around, and it would be created by the stack the operator applies.

## Consequences

AVD-AWS-0039 stays suppressed for the life of the project, so `trivy config` never reports on cluster
secrets encryption again. That is the cost of every suppression and the reason the ignore file carries a
sentence per id rather than a bare list.

Anyone reading `.trivyignore` for compliance purposes needs the distinction that the check cannot make:
this cluster has envelope encryption, with a key AWS owns. That is one link away now instead of nowhere.

The two arguments are load-bearing and non-obvious, because the module's default is the opposite of
what this stack wants. A module version bump will not silently create a key, since the arguments are
explicit, but a stack copied from this one without both lines will get one.

Worth revisiting if any of three things change: the cluster stops being torn down at the end of every
window, so a monthly key charge stops being a charge for nothing; something starts keeping a real
credential in a Kubernetes Secret rather than in Secrets Manager; or an audit needs per-key CloudTrail
attribution for control plane decryption. Flipping it means `create_kms_key = true` and removing
`encryption_config = null`, on a newly created cluster, because it cannot be added to this one and
taken off again.

## Sources

- AVD-AWS-0039, "EKS should have the encryption of secrets enabled", severity HIGH: "EKS cluster
  resources should have the encryption_config block set with protection of the secrets resource."
  <https://avd.aquasec.com/misconfig/aws-0039>
- `terraform-aws-modules/eks/aws` 21.25.0 inputs, for the `create_kms_key`, `encryption_config`,
  `enable_kms_key_rotation` and `attach_encryption_policy` defaults, and for the nested
  `terraform-aws-modules/kms/aws` 4.0.0 call.
  <https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/21.25.0?tab=inputs>
- EKS default envelope encryption: "Amazon EKS implements default envelope encryption of all Kubernetes
  API data for EKS clusters running Kubernetes version 1.28 or higher", with KMS v2, "By default, this
  KEK is owned by AWS, but you can optionally bring your own from AWS KMS", and the answer to "How can
  I protect my EKS cluster from the impact of a disabled/deleted CMK?"
  <https://docs.aws.amazon.com/eks/latest/userguide/envelope-encryption.html>
- Encrypting Kubernetes secrets with KMS on existing clusters, carrying both the deprecation notice for
  1.28 and higher and the warning "You can't disable secrets encryption after enabling it. This action
  is irreversible." <https://docs.aws.amazon.com/eks/latest/userguide/enable-kms.html>
- AWS KMS pricing, for the key storage dimension, the rotation surcharge capped at the second rotation,
  the per-request charge above the free tier, "Creation and storage of AWS managed or AWS owned KMS
  keys" being free, and "There is no charge for customer managed KMS keys that you manage and are
  scheduled for deletion." <https://aws.amazon.com/kms/pricing/>
- EKS best practices, data encryption and secrets management, on what envelope encryption of Kubernetes
  secrets buys and where it stops.
  <https://docs.aws.amazon.com/eks/latest/best-practices/data-encryption-and-secrets-management.html>
