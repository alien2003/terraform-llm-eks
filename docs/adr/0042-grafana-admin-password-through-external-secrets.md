# 0042. The Grafana administrator password arrives through External Secrets

Date: 2026-09-09

## Status

Accepted.

## Context

The kube-prometheus-stack chart wants an administrator password for Grafana. The chart's own default
is to generate one and store it in a Secret it owns, which is fine until the password has to survive
a reinstall, and worse, until somebody wants it in a values file.

Rule 2c is explicit: secrets that must exist live in AWS Secrets Manager or SSM Parameter
Store, are created inside a window, and are referenced by ARN. That rules out a literal in the
repository. It also rules out reading the secret with `data.aws_secretsmanager_secret_version` and
passing it to the chart, because the plaintext would then sit in Terraform state, which is an S3
object with a longer life than the password.

The remaining options are a controller inside the cluster that fetches the secret itself. Two exist:
the AWS Secrets and Configuration Provider on top of the Secrets Store CSI driver, and External
Secrets. ASCP delivers a secret as a mounted file and only produces a Kubernetes Secret as a side
effect of a pod mounting the volume, which means the Grafana pod would have to mount a volume it does
not otherwise want in order for the Secret the chart reads to exist. External Secrets produces the
Secret directly, independent of any consumer.

## Decision

External Secrets 2.10.0, with a `ClusterSecretStore` for AWS Secrets Manager and one `ExternalSecret`
that writes the Kubernetes Secret named in `grafana.admin.existingSecret`.

The controller authenticates with EKS Pod Identity (ADR 0041) and its role can read exactly one
secret ARN, the one passed in `var.grafana_admin_secret_arn`. The store has no `auth` block at all, so
there is no key, no `secretRef` and no role ARN written down in the cluster.

The remote secret is a JSON object with `username` and `password` keys; the ExternalSecret maps them
onto the `admin-user` and `admin-password` keys the Grafana chart reads.

## Consequences

The password exists in Secrets Manager and in one Kubernetes Secret, and nowhere else. It is not in
git, not in a values file, not in Terraform state, and not in a Helm release's stored values.

Rotating it is a rotation in Secrets Manager plus a Grafana pod restart; nothing in this repository
changes.

The cost is one more controller, three more deployments and a set of CRDs on a two-node system group.
That is the price of not having the password anywhere it can leak, and the same store is what any
later secret (a registry credential for the pull-through cache, for instance) will use.

## Sources

- External Secrets, AWS Secrets Manager provider. The store takes `service: SecretsManager` and a
  `region`, and with no `auth` block the controller uses the AWS SDK's default credential chain,
  which is what the Pod Identity agent populates:
  <https://external-secrets.io/latest/provider/aws-secrets-manager/>
- Grafana Helm chart values, `admin.existingSecret`, `admin.userKey` and `admin.passwordKey`, as
  shipped in kube-prometheus-stack 90.0.0's bundled grafana subchart 13.2.2.
- AWS Secrets Manager User Guide, the Secrets Store CSI driver provider and its `secretObjects`
  behaviour, for the option not taken:
  <https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html>
