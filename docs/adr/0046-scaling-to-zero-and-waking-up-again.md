# 0046. Scaling to zero, and what it takes to wake up again

Date: 2026-09-09

## Status

Accepted, with a known gap recorded below.

## Context

Scaling the inference deployment to zero is the point of the exercise. With no pod requesting
`nvidia.com/gpu`, the GPU NodePool consolidates its last node away and the Spot bill stops. Every
minute the deployment sits idle at one replica is a minute of accelerator that produced nothing.

KEDA does the scaling, on the vLLM scheduler queue. The metric is `vllm:num_requests_waiting`, a
gauge of requests accepted but not yet in a model execution batch, exported by vLLM itself.

There is a circularity in this, and it is worth being blunt about it. `vllm:num_requests_waiting` is
produced by the vLLM pod. At zero replicas there is no vLLM pod, so there is no series, so the
Prometheus scaler's query returns nothing. With `ignoreNullValues` at its default of true, KEDA reads
that as zero, which is below the activation threshold, so the deployment stays at zero. The metric
that would wake the workload up only exists once the workload is already up.

This is not a KEDA defect and it is not specific to vLLM. Any scaler whose signal is emitted by the
scaled workload has it. The documented ways out are all a variant of "measure the demand somewhere
that is still running at zero replicas": the KEDA HTTP add-on, which puts an interceptor in front of
the Service and holds the first request while the deployment starts; a load balancer metric read
through the CloudWatch scaler; or a queue that requests land in before they reach the model.

## Decision

The ScaledObject ships as specified: `minReplicaCount: 0`, a Prometheus trigger on
`sum(vllm:num_requests_waiting{model_name="<model>"})`, `metricType: AverageValue` so the threshold is
per replica, an `activationThreshold`, a `cooldownPeriod`, and a scale-down stabilization window on
the generated HorizontalPodAutoscaler because a GPU pod costs minutes to start and should not be
removed on a momentary dip.

The wake-up gap is left open in Phase 1 rather than papered over. Inside a window the deployment is
brought up deliberately, before the run that is going to load it, which is what a benchmark wants
anyway: `mise run bench` scales the deployment and waits for the pod to become ready before it sends
traffic.

The KEDA HTTP add-on (chart `kedacore/keda-add-ons-http`, 0.15.0) is the documented upgrade path. It
is not installed, for two reasons: its interceptor sits in the request path and would show up in
every latency measurement this project exists to take, and nothing about it has been tested here yet.
Installing an untested component to close a gap that no benchmark actually hits would be trading a
known limitation for an unknown one.

## Consequences

Idle cost goes to zero without any manual step, which is the half that matters for the bill. The
scale down is automatic; the scale up, for now, is not.

Anything that sends traffic to the endpoint has to bring it up first. That is written into the
benchmark and demo tasks rather than assumed.

Re-opening this is a window's work: install the add-on, put an `HTTPScaledObject` in front of the
Service, and measure what the interceptor adds to time to first token before deciding whether to keep
it. Whatever is measured belongs in `materials/measurements/` and in an amendment to this ADR.

## Sources

- KEDA Prometheus scaler, version 2.20. Required `serverAddress`, `query` and `threshold`; optional
  `activationThreshold` and `ignoreNullValues`, the latter defaulting to true. `metricName` is no
  longer a parameter. <https://keda.sh/docs/2.20/scalers/prometheus/>
- KEDA ScaledObject specification, `minReplicaCount`, `cooldownPeriod`, `pollingInterval` and
  `advanced.horizontalPodAutoscalerConfig.behavior`, read from the CRD shipped in the KEDA chart
  2.20.2. <https://keda.sh/docs/2.20/reference/scaledobject-spec/>
- vLLM v1 metrics, including `vllm:num_requests_waiting`:
  <https://docs.vllm.ai/en/stable/design/metrics>
- KEDA HTTP add-on, the request-driven path to activating a workload from zero:
  <https://github.com/kedacore/http-add-on>
