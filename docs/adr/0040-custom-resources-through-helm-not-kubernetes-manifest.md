# 0040. Custom resources go through Helm, never through kubernetes_manifest

Date: 2026-09-09

## Status

Accepted.

## Context

The platform layer is mostly custom resources: two Karpenter NodePools and two EC2NodeClasses, a
KEDA ScaledObject, an External Secrets ClusterSecretStore and ExternalSecret, and a handful of
ServiceMonitors. The obvious Terraform resource for those is `kubernetes_manifest`.

It is the wrong one here. The Kubernetes provider's `kubernetes_manifest` resource fetches the
OpenAPI schema for the object's kind from a live API server during the plan phase, so that it can
type-check the manifest. That means `terraform plan` fails whenever the cluster is unreachable, and
in this project the cluster is unreachable most of the time: there is no cluster between windows at
all, and CI runs with no credentials by design.

It also fails on a first apply even with a cluster, because the CRD that defines the kind is
installed by a Helm release inside the same plan, and the schema does not exist yet when the plan is
made.

## Decision

No `kubernetes_manifest` resource exists anywhere in `infra/cluster/platform`. Custom resources are
delivered as three small local Helm charts, installed with `helm_release`:

- `charts/llm-eks-nodepools` for the Karpenter NodePools and EC2NodeClasses
- `charts/llm-eks-secrets` for the External Secrets store and the Grafana credential
- `charts/llm-eks-inference` for the vLLM Deployment, its Service, its ServiceMonitor and its
  ScaledObject

Where a plain typed resource does the job it is used instead: `kubernetes_namespace_v1` for the four
namespaces and `kubernetes_config_map_v1` for the two Grafana dashboards. Those have provider-side
schemas and need no API server during plan.

## Consequences

Every custom resource in this layer renders offline. `helm lint` checks the templates, and
`helm template` piped to `kubeconform -strict` checks each rendered object against the real CRD
schema, with no cluster and no credentials. That is a stronger check than `kubernetes_manifest`
would have given, because it runs in CI on every commit rather than only when someone has a cluster.

The cost is that Terraform's plan output for these objects is "one Helm release will change" rather
than a field-level diff. For a layer whose inputs are all in version control that is an acceptable
trade; the diff that matters is the one in the values file, and that one is visible.

## Sources

- Terraform Kubernetes provider, `kubernetes_manifest`: "This resource requires API access during
  planning time. This means the cluster has to be accessible at plan time and thus cannot be created
  in the same apply operation."
  <https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest>
- kubeconform, `-schema-location` templating for CRD schemas:
  <https://github.com/yannh/kubeconform>
