# infra/cluster/platform

The in-cluster layer: everything that runs inside EKS rather than next to it. Karpenter and its node
pools, Prometheus and Grafana, the GPU exporters, KEDA, External Secrets, and the vLLM deployment the
whole project exists to measure.

It is a child module of `infra/cluster`, not a stack of its own. It has no backend and no provider
block; the root stack configures `aws`, `helm` and `kubernetes` and passes the cluster's name,
endpoint and Karpenter identifiers in.

## The constraint that shaped everything

`kubernetes_manifest` needs a reachable API server during `terraform plan`. This project has no
cluster most of the time and CI has no credentials at all, so that resource cannot appear anywhere in
this repository. It does not.

Custom resources are delivered as three small local Helm charts instead. Everything those charts
render is checked with no cluster, and the check is a real one rather than a flag that passes
everything: the built-in kinds resolve against the upstream Kubernetes schemas, and all six custom
resource kinds against the structural schemas generated from their CRDs. `kubeconform` reports
`Skipped: 0`. What is deliberately not checked that way is the CustomResourceDefinition objects the
two upstream charts ship, and the upstream charts' own custom resources; both are described under
"Linting with no cluster" below. ADR 0040 has the reasoning for the charts.

## Wiring it into the cluster stack

The parent stack does not call this module yet. When it does, it has to configure the two providers
this module declares but does not configure, and pass the cluster identifiers it already publishes as
SSM parameters:

```hcl
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

module "platform" {
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

  gpu_instance_types    = var.gpu_instance_types
  general_instance_types = var.system_instance_types

  system_node_label_key   = var.system_node_label_key
  system_node_label_value = var.system_node_label_value

  weights_bucket_name      = data.aws_ssm_parameter.weights_bucket.value
  grafana_admin_secret_arn = data.aws_ssm_parameter.grafana_admin_secret_arn.value
}
```

Exactly one of `karpenter_node_instance_profile_name` and `karpenter_node_iam_role_name` may be set;
a variable validation enforces it, because an EC2NodeClass rejects both together and cannot launch a
node with neither.

The module carries its own `.terraform.lock.hcl`. Terraform ignores lock files in child modules, so
it exists only so that `terraform -chdir=infra/cluster/platform init -backend=false && validate` pins
the same three providers the parent does. That standalone validate is what CI runs for this
directory.

## What gets installed, in order

| release | chart | version | namespace |
| --- | --- | --- | --- |
| `external-secrets` | `external-secrets/external-secrets` | 2.10.0 | `external-secrets` |
| `llm-eks-secrets` | local `charts/llm-eks-secrets` | 0.1.0 | `external-secrets` |
| `kube-prometheus-stack` | `prometheus-community/kube-prometheus-stack` | 90.0.0 | `monitoring` |
| `karpenter` | `oci://public.ecr.aws/karpenter/karpenter` | 1.14.1 | `kube-system` |
| `llm-eks` | local `charts/llm-eks-nodepools` | 0.1.0 | `kube-system` |
| `nvidia-device-plugin` | `nvdp/nvidia-device-plugin` | 0.20.0 | `kube-system` |
| `dcgm-exporter` | `gpu-helm-charts/dcgm-exporter` | 4.8.3 | `monitoring` |
| `keda` | `kedacore/keda` | 2.20.2 | `keda` |
| `llm-eks-inference` | local `charts/llm-eks-inference` | 0.1.0 | `inference` |

The order is not incidental and is expressed with `depends_on` rather than left to the graph:

- External Secrets has to be running, and its Pod Identity association in place, before the
  `ClusterSecretStore` and `ExternalSecret` are applied.
- The `llm-eks-secrets` release comes before kube-prometheus-stack, which mounts the Grafana
  Secret by name. This is ordering, not a guarantee: Helm's `--wait` polls readiness only for the
  kinds it knows (Pod, PVC, Service, Deployment, StatefulSet, DaemonSet, ReplicaSet,
  ReplicationController, Job) and returns immediately for a custom resource, and that chart creates
  nothing but a `ClusterSecretStore` and an `ExternalSecret`. So the release can return before the
  controller has written the Secret, and the Grafana pod can start into `CreateContainerConfigError`
  until the kubelet retries. `secrets.tf` records what a real gate would look like.
- kube-prometheus-stack brings the `monitoring.coreos.com` CRDs, so every chart that creates a
  `ServiceMonitor` comes after it.
- Karpenter brings the `karpenter.sh` and `karpenter.k8s.aws` CRDs, so the node pools come after it.
- The inference release comes last: it needs the GPU pool to exist for a pod to be placeable, the
  KEDA CRDs for its `ScaledObject`, and the operator CRDs for its `ServiceMonitor`.

Two releases are installed with `wait = false` on purpose. The device plugin and the DCGM exporter
are DaemonSets whose node affinity selects GPU nodes, and between windows there are none, so they
have zero pods and never become ready. Waiting on them would block every apply until an accelerator
exists. The inference release is also `wait = false`, because with `minReplicaCount: 0` the expected
end state of an apply is a deployment with no pod at all.

## How the pieces fit

Karpenter's IAM role, interruption queue, node role and Pod Identity association belong to the parent
stack. This module installs the controller chart and the custom resources, which is the part that
cannot be expressed as an AWS resource.

The GPU NodePool is Spot only, restricted to the whitelisted `g6` types, tainted, capacity-capped and
consolidation-limited. ADR 0043 covers why the Spot rule is stated here as well as in the permission
boundary, and why the NVIDIA device plugin is not optional.

### The tags on a Karpenter node are this chart's job, not the eks module's

`tags = local.default_tags` on the eks module reaches the managed node group's launch template. It
does not reach anything Karpenter launches, and what Karpenter launches is the g6 instances. Their
only tag path is `spec.tags` on the EC2NodeClass, which is set in both node classes:

- `charts/llm-eks-nodepools/templates/ec2nodeclass-gpu.yaml`, the `tags:` block at the end of `spec`.
- `charts/llm-eks-nodepools/templates/ec2nodeclass-general.yaml`, the same block.

Both render the same map. It arrives from `local.tags` in `locals.tf`, is passed as `tags_json` by
`karpenter.tf`, lands in `values/nodepools.yaml` as `tags: ${tags_json}`, and carries `Project`,
`Stack`, `ManagedBy` and, inside a window, `Window`. `helm template` on the chart's own defaults shows
`Project: terraform-llm-eks`, `Stack: cluster` and `ManagedBy: terraform` on both classes.

Karpenter's documentation is what makes that block sufficient: "Karpenter adds tags to all resources
it creates, including EC2 Instances, EBS volumes, and Launch Templates", with overrides refused only
in the `karpenter.sh`, `karpenter.k8s.aws` and `kubernetes.io/cluster` domains, none of which this
chart touches. <https://karpenter.sh/docs/concepts/nodeclasses/>

Because `mise run audit` and the always-on sweeper both select on `Project=terraform-llm-eks`, a node
class that lost that key would put a GPU instance outside both safety nets. So a missing key is not a
smaller tag map, it is a failed render: `templates/_helpers.tpl` defines
`llm-eks-nodepools.tags`, which calls `fail` if `Project`, `Stack` or `ManagedBy` is absent or empty.
`helm lint` and `helm template` both execute it, so the mistake is caught locally with no credentials.

One gap is worth stating rather than assuming. When an EC2NodeClass uses `spec.role` instead of
`spec.instanceProfile`, Karpenter creates and manages an instance profile itself, and its
documentation does not say whether `spec.tags` is applied to that instance profile. The parent stack
passes `karpenter_node_instance_profile_name`, so this module renders `spec.instanceProfile` and
Karpenter creates no such profile. If that ever flips to the role form, the instance profile has to be
checked against the audit by hand.

The two IAM roles this module does create, for External Secrets and for the inference pod, use EKS
Pod Identity and carry the operator permission boundary. ADR 0041.

The Grafana administrator password lives in AWS Secrets Manager, is referenced by ARN only, and
reaches the cluster through External Secrets. It is not in git, not in a values file, not in
Terraform state. ADR 0042.

Prometheus and Grafana keep no persistent volume, because there is no EBS CSI driver in this cluster
and a window is measured in hours. ADR 0044.

vLLM runs as a plain Deployment rather than a KServe `InferenceService`. ADR 0045.

KEDA takes the deployment to zero on the vLLM queue metric. Scaling back up from zero has a known gap,
written up honestly in ADR 0046: at zero replicas the metric that would wake the workload does not
exist, so `mise run bench` brings the deployment up before it sends traffic.

## Model weights

The init container runs `aws s3 sync` from `s3://<weights bucket>/models/<model id>/` onto the node's
root volume, with credentials from Pod Identity. The mirror step has to have put them there first;
this module reads the bucket and never writes to it.

The default model is `Qwen/Qwen2.5-7B-Instruct`, Apache-2.0 and ungated, so the weights can be
mirrored without a token. `model_max_len` and `gpu_memory_utilization` are variables because weights
plus KV cache have to fit in the accelerator, and how much room is left on the smallest whitelisted
GPU type is an open question in `STATE.md` that only a window can answer. Nothing in this repository
claims a figure for it.

## Dashboards

`dashboards/gpu.json` and `dashboards/inference.json` become labelled ConfigMaps that the Grafana
sidecar picks up from any namespace. `mise run screenshot` renders them through the Grafana image
renderer, which is why the renderer is part of the stack rather than an optional extra.

Every metric name in them was read from a primary source, not from memory:

- The GPU dashboard uses only names from the default counter set the `dcgm-exporter` chart 4.8.3
  ships: `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_PROF_GR_ENGINE_ACTIVE`, `DCGM_FI_DEV_FB_USED`,
  `DCGM_FI_DEV_FB_FREE`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`, `DCGM_FI_DEV_POWER_USAGE`,
  `DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_DEV_SM_CLOCK`, `DCGM_FI_DEV_XID_ERRORS`,
  `DCGM_FI_DEV_MEM_COPY_UTIL`, `DCGM_FI_PROF_PCIE_RX_BYTES` and `DCGM_FI_PROF_PCIE_TX_BYTES`.
  `DCGM_FI_DEV_XID_ERRORS` is declared a `gauge` in that counter set, holding the code of the last
  XID error rather than a running count, so the panel reads it with `max()` and not with `increase()`.
  The cumulative `DCGM_EXP_XID_ERRORS_TOTAL` counter exists in the same file but is commented out of
  the default set, so this deployment does not emit it.
  The dashboard selects on `instance`, which is the label Prometheus itself attaches, and on `gpu`.
  Both, and the absence of `Hostname`, are item 3 of "Things to confirm in the first window" below:
  the chart's own README ships no metric sample output, so the label set has to be read off a live
  exporter rather than cited.
- The inference dashboard uses vLLM's own v1 metric names from
  <https://docs.vllm.ai/en/stable/design/metrics>: `vllm:num_requests_running`,
  `vllm:num_requests_waiting`, `vllm:kv_cache_usage_perc`, `vllm:generation_tokens_total`,
  `vllm:prompt_tokens_total`, `vllm:time_to_first_token_seconds`, `vllm:e2e_request_latency_seconds`,
  `vllm:request_queue_time_seconds` and `vllm:request_success_total`. Note `kv_cache_usage_perc`, not
  the `gpu_cache_usage_perc` that the v0 engine used and that most older dashboards still carry.

Both dashboards contain panel titles and descriptions and no measured numbers, because Phase 1 has
produced no measurements.

## Values files

Chart values live in `values/`, one file per chart, never inline in Terraform. The files carry
`${...}` placeholders that `templatefile()` fills in; a placeholder is still valid YAML, which is what
lets `helm lint` and `helm template` read the same file the module uses.

`values/lint/kube-prometheus-stack.yaml` exists for one reason: two fields in the Prometheus CRD are
pattern-validated, `spec.retention` and `spec.storage.emptyDir.sizeLimit`, and a placeholder matches
neither pattern. That file supplies concrete values for exactly those two so an offline render is
schema-clean and any other failure is a real one. It is never used in an install.

## Linting with no cluster

`mise run lint` runs all of this, per stack, with this directory as the working directory. The commands
are here so they can be run one at a time when something fails. Every one of them works with no
credentials and no cluster.

```sh
terraform -chdir=infra/cluster/platform init -backend=false
terraform -chdir=infra/cluster/platform validate
tflint --chdir=infra/cluster/platform
gitleaks detect --no-git --redact -s infra/cluster/platform
helm lint infra/cluster/platform/charts/*

# trivy from inside the directory, not from the repository root. It reads the
# .trivyignore in the working directory, so the path form silently ignores this
# module's accepted findings and reports them again.
cd infra/cluster/platform && trivy config --exit-code 1 --skip-dirs .terraform .
```

### The CRD schema locations

For the Kubernetes objects, the schema locations are not written into a command line. They live one
per line in `kubeconform-schemas.txt`, next to this README, and `scripts/lint.sh` reads that file and
turns each line into a `-schema-location` flag.

The format is exactly one `-schema-location` value per line. Blank lines and lines whose first
character is `#` are ignored, which is what lets the file carry the reason for each entry next to the
entry. Two locations are enough:

- `default`, kubeconform's own built-in location, for `Deployment`, `Service`, `ServiceAccount` and
  `PodDisruptionBudget`.
- the templated CRDs-catalogue URL, which resolves a custom resource by group, lower-cased kind and
  API version. The six kinds these charts render, and the file each resolves to, are listed in the
  schema file itself.

`kubeconform` tries each location in the order given and the first hit wins, so a miss on one line
falls through to the next rather than failing the run.

A caller that is not `lint.sh` passes them like this. Nothing here needs credentials or a cluster; it
does need to reach `raw.githubusercontent.com`.

```sh
cd infra/cluster/platform

locations=()
while IFS= read -r line; do
  case "$line" in '' | '#'*) continue ;; esac
  locations+=(-schema-location "$line")
done < kubeconform-schemas.txt

for c in nodepools secrets inference; do
  helm template "llm-eks-$c" "charts/llm-eks-$c" \
    | kubeconform -strict -summary "${locations[@]}"
done
```

`lint.sh` adds `-kubernetes-version`, read out of `infra/cluster/variables.tf` so that the version is
written down once. The example above leaves it off rather than repeating the number here.

What this buys over the `-ignore-missing-schemas` it replaces: `kubeconform` now reports `Skipped: 0`
instead of quietly passing every custom resource without fetching a schema at all. The schemas are
structural, generated from the CRDs, so `-strict` rejects an unknown field inside `spec`. That was
worth proving rather than assuming, so it was: adding one invented field to the rendered `NodePool`
makes the run exit non-zero with `additional properties ... not allowed`.

The catalogue's copy of a CRD can lag the chart version this module pins. A failure on a field the
pinned CRD does have is a stale catalogue entry, not a broken chart, and the fix belongs in a comment
in the schema file, not in a return to `-ignore-missing-schemas`.

### The upstream charts

`lint.sh` renders the three local charts and not the upstream ones. Rendering an upstream chart by
hand needs one more flag, because `kubeconform` has no schema for `apiextensions.k8s.io/v1`
CustomResourceDefinition objects and those charts ship dozens of them:

```sh
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 90.0.0 \
  -n monitoring \
  -f values/kube-prometheus-stack.yaml \
  -f values/lint/kube-prometheus-stack.yaml \
  | kubeconform -strict -summary -skip CustomResourceDefinition "${locations[@]}"
```

`-skip CustomResourceDefinition` names the one kind it gives up on, which is not the same thing as
`-ignore-missing-schemas` giving up on all of them silently.

The two dashboards are JSON, so a parse is the check:

```sh
for f in infra/cluster/platform/dashboards/*.json; do python3 -m json.tool "$f" > /dev/null; done
```

## trivy: one finding fixed, one accepted

`trivy config` is clean in this module. Getting there took one code change and one written-down
acceptance, and the difference between the two is the point.

`KSV-0014`, read-only root filesystem, was a real finding and is fixed rather than suppressed. Both
containers of the inference Deployment now set `securityContext.readOnlyRootFilesystem`. What made it
possible was reading vLLM's own documentation for the paths it writes to instead of assuming they were
scattered through the image. There are four, and all four are already emptyDir volumes on this pod:

| path | volume | what writes there |
| --- | --- | --- |
| `$XDG_CACHE_HOME` | `home` | `VLLM_CACHE_ROOT`: the `torch.compile` cache, the FlashInfer autotune cache, the assets cache, the XLA cache. `HF_HOME` defaults under it too. |
| `$XDG_CONFIG_HOME` | `home` | `VLLM_CONFIG_ROOT` |
| the system temp dir | `tmp` | `VLLM_RPC_BASE_PATH`, and PyTorch's own TorchInductor cache at `/tmp/torchinductor_<user>` |
| `/dev/shm` | `dshm` | the model executor moving tensors between processes |

Sources, all primary: <https://docs.vllm.ai/en/stable/configuration/env_vars> for the variables and
their defaults, <https://docs.vllm.ai/en/stable/usage/security> for what sits under the cache root,
<https://docs.vllm.ai/en/stable/design/debug_vllm_compile> for the TorchInductor path, and
<https://huggingface.co/docs/huggingface_hub/en/package_reference/environment_variables> for `HF_HOME`
defaulting to `$XDG_CACHE_HOME/huggingface`. `TORCHINDUCTOR_CACHE_DIR` and `TRITON_CACHE_DIR` are not
set here on purpose: vLLM points both at subdirectories of its own compile cache when it initializes
the compiler, so they follow `VLLM_CACHE_ROOT`
(<https://docs.vllm.ai/en/stable/api/vllm/compilation/compiler_interface>).

`HOME`, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME` and `VLLM_CACHE_ROOT` are all set explicitly on the
container rather than left to resolve. That is what turns "the caches happen to land on a volume" into
"no documented cache root can resolve to a path inside the image".

It is still a chart value and not a literal, because no pod has run yet. If some library in the image
writes somewhere those four paths do not cover, reverting is one value, and finding the real path is
item 5 of the first-window list below.

`KSV-0125`, untrusted registry, is accepted, twice, and the acceptance lives in
`.trivyignore` in this directory with the reason written next to the id. In short: every image this
cluster pulls is meant to come through the ECR pull-through cache, the Docker Hub rule behind it needs
a credential a human puts in by hand inside a window, and until that is standing the chart names the
upstream Docker Hub repositories. ADR 0024 is the decision. Both images are pinned by tag and the vLLM
one by digest as well, so what runs cannot change under a retag. When the cache is applied with the
Docker Hub rule enabled, the finding goes away on its own and the `.trivyignore` entry should be
deleted rather than kept.

The ignore file is scoped to this directory deliberately. `mise run lint` runs one `trivy config` per
stack with the stack as the working directory, and trivy reads the `.trivyignore` from the working
directory, so an acceptance written here cannot silently cover a finding in another stack. Running
`trivy config infra/cluster/platform` from the repository root does not pick it up.

Trivy's inline `#trivy:ignore:` comment is not an option here: it does not suppress Kubernetes
findings in 0.74.0, tried against a minimal manifest with four spellings of the rule id, with no
effect.

## Pod Security Admission enforces nothing yet

Worth being blunt about, because the labels look like protection and are not. `namespaces.tf` sets
`pod-security.kubernetes.io/warn` on all four namespaces and no other Pod Security Admission label.
`warn` makes the API server return a warning to whoever submitted the pod and then admits the pod
anyway. There is no `enforce` label and no `audit` label, so nothing in this cluster is rejected on
Pod Security grounds. `locals.tf` says the same thing next to the map.

The levels are `privileged` for `monitoring`, because the DCGM exporter DaemonSet adds `SYS_ADMIN`,
runs as UID 0 and mounts a hostPath, and `baseline` for `external-secrets`, `keda` and `inference`.

`enforce` is deliberately absent rather than forgotten. A label set one level too tight rejects pods
at admission during a paid window, and there is no way to test the real workload against it locally:
the pods that matter are the GPU ones, and they need an accelerator. So the labels stay at `warn`,
window 1 collects the warnings, and turning `enforce` on is a decision made with that output in hand.
It is item 6 of the list below.

## Variables worth knowing about

`ami_alias` pins the EKS-optimized AMI release the node classes resolve, as `family@version`. An alias
resolves the right variant per instance type, which is how the GPU pool gets the accelerated AL2023
AMI without a second selector. It is pinned to a release tag rather than `latest`, because `latest`
drifts every node in the cluster the day a new AMI is published. Confirm the tag exists for this
cluster's Kubernetes version before the first apply:

```sh
aws ssm get-parameters-by-path \
  --path "/aws/service/eks/optimized-ami/1.35/amazon-linux-2023/" --recursive \
  --query 'Parameters[].Name' --output text
```

`gpu_nodepool_cpu_limit` is the second brake after the permission boundary. The boundary stops the
wrong instance type; this stops too many of the right one.

`grafana_admin_secret_arn` and `weights_bucket_name` have no defaults. Both name resources created by
other stacks, and a default would be a guess.

## Things to confirm in the first window

Written down here rather than assumed, because none of them can be checked without a cluster:

1. vLLM starts under a non-root UID with `HOME` on an emptyDir. If it does not, the fallback is
   `runAsNonRoot: false` in the pod security context, and the reason belongs in an ADR.
2. `ami_alias` resolves an accelerated AMI for `g6.xlarge` on the cluster's Kubernetes version.
3. The DCGM exporter's series carry the `instance` and `gpu` labels the GPU dashboard selects on.
4. `model_max_len` and `gpu_memory_utilization` leave enough KV cache to be worth benchmarking on the
   smallest whitelisted GPU type. This is open question 4 in `STATE.md`.
5. vLLM starts and serves with `readOnlyRootFilesystem: true`. The four writable paths above come from
   vLLM's documentation, not from a running pod, and a library in the image can always write somewhere
   the documentation does not mention. The symptom would be a permission error during startup naming a
   path. If it happens, note the path, add the volume, and only fall back to
   `readOnlyRootFilesystem: false` if the path cannot be redirected; either way it gets an ADR.
6. The Pod Security Admission `warn` output on the four namespaces. Collect it with
   `kubectl get events` and from the apply output, then decide per namespace whether `enforce` can be
   set at the same level the `warn` label already carries.
7. `spec.tags` on the EC2NodeClass actually reaches a launched GPU instance and its EBS volume.
   Karpenter's documentation says it does; this is the one tag path the money-safety nets depend on, so
   it gets checked against a real instance with `describe-instances` rather than trusted. `mise run
   audit` finding the node is the same check from the other end.
