# 0045. vLLM runs as a plain Deployment, not as a KServe InferenceService

Date: 2026-09-09

## Status

Accepted.

## Context

The workload is one model, one accelerator, one endpoint, benchmarked inside a few short cloud
windows on a cluster whose only permanent compute is two small on-demand nodes.

KServe is the obvious alternative to a Deployment. It gives a model-serving CRD, a standard inference
protocol, canary traffic splitting between revisions, and storage initializers that can pull weights
from S3 without a hand-written init container. In Serverless mode it also gives scale to zero.

It also brings a control plane. KServe's Serverless mode requires Knative Serving and a networking
layer under it, and cert-manager for the webhooks; RawDeployment mode drops Knative but then also
drops the scale-to-zero that was the reason to consider Serverless. Either way the cluster gains a
controller, a webhook and a set of CRDs that have to be pinned, linted, kept in step with the
Kubernetes version, and paid for in memory on the system node group. The scale-to-zero this project
needs is already provided by KEDA, which is in the stack anyway for queue-driven scaling.

## Decision

vLLM runs as a plain `apps/v1` Deployment in `charts/llm-eks-inference`, with:

- an init container that stages the model out of the weights bucket with `aws s3 sync`, using
  credentials from EKS Pod Identity;
- the vLLM OpenAI-compatible server as the only container, pinned by tag and digest, with
  `nvidia.com/gpu: 1`;
- a startup probe long enough to cover a full model load, so that the liveness probe cannot restart
  the pod while it is still loading;
- `strategy: Recreate`, because with one accelerator per node and a NodePool cpu ceiling, a surge
  replica would sit Pending waiting for a second accelerator that is not going to arrive;
- a ServiceMonitor on the same port as the API, and a KEDA ScaledObject next to it.

## Consequences

The whole workload is six templates and a helpers file in one chart, and all of it renders offline and
validates against the real schemas. There is no second control plane to keep alive, no CRD set to pin
against the Kubernetes version, and the memory on the system node group goes to Prometheus instead.

What is given up is real: no canary between two model revisions, no standard inference protocol in
front of the OpenAI API, and a hand-written weights sync instead of a storage initializer. For a
single-model benchmark none of those has a job to do. If a later phase serves more than one model or
wants revision traffic splitting, KServe in RawDeployment mode is the upgrade path, and the KEDA
ScaledObject moves onto its Deployment unchanged.

## Sources

- KServe deployment modes: Serverless mode depends on Knative Serving and a networking layer;
  RawDeployment mode removes that dependency and with it Knative's scale to zero.
  <https://kserve.github.io/website/latest/admin/serverless/serverless/>
- vLLM OpenAI-compatible server, `/health` and `/metrics` endpoints and the `vllm serve` command
  form: <https://docs.vllm.ai/en/stable/serving/online_serving/>
- vLLM Docker image usage, arguments passed straight to the image's entrypoint, and the shared-memory
  requirement: <https://docs.vllm.ai/en/stable/deployment/docker/>
