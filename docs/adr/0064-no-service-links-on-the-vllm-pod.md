# 0064. No service links on the vLLM pod

Date: 2026-11-27

## Status

Accepted. Tested only by rendering; the next window with a GPU node confirms it.

## Context

In window 1, attempt 5, vLLM 0.28.0 loaded the model, captured its graphs and initialised the engine in
25.55 s, then exited:

```text
ValueError: VLLM_PORT 'tcp://172.20.213.69:8000' appears to be a URI. This may be caused by a Kubernetes
service discovery issue
```

The inference Service is named `vllm`. Kubernetes gives every pod environment variables for each Service
in its namespace, prefixed with the Service name in capitals, so the pod had `VLLM_PORT`,
`VLLM_SERVICE_HOST` and six more. `VLLM_PORT` is also one of vLLM's own settings, and `get_vllm_port`
raises on a URI. The variables were in the earlier attempts too; the engine reads them only after the
graph capture, which attempt 3 never got past.

vLLM's documentation says not to name the Service `vllm` for this reason.

## Decision

The inference Deployment sets `enableServiceLinks: false` on its pod. The Service keeps its name.

Renaming the Service would also work and is what the vLLM page suggests. It would touch the KEDA trigger,
the ServiceMonitor, the dashboards and the window plans, and it would fix only this one prefix. With the
links off no Service name can collide with a vLLM variable, and nothing in the pod reads a service
variable: the weights come from S3 and vLLM listens rather than calls.

## Consequences

The pod sees only the variables the chart sets. Cluster DNS still resolves every Service.

The "Unknown vLLM environment variable detected" warnings at startup go away with the same change.

## Sources

- vLLM environment variables, the Kubernetes note.
  https://docs.vllm.ai/en/stable/configuration/env_vars/
- `vllm.envs.get_vllm_port`.
  https://docs.vllm.ai/en/stable/api/vllm/envs/
- Kubernetes Services, the variables the kubelet sets per Service.
  https://kubernetes.io/docs/concepts/services-networking/service/#environment-variables
- Kubernetes, "Connecting Applications with Services": "you can disable this mode by setting the
  `enableServiceLinks` flag to `false` on the pod spec".
  https://kubernetes.io/docs/tutorials/services/connect-applications-service/
- Evidence in the working notes: `materials/measurements/w1e-vllm-log-prev.txt`.
