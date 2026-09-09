# 0044. Prometheus and Grafana keep no persistent volume

Date: 2026-09-09

## Status

Accepted.

## Context

The kube-prometheus-stack chart's usual production shape gives Prometheus a `volumeClaimTemplate` and
Grafana a PersistentVolumeClaim. Both need a StorageClass to bind against.

This cluster has none. The cluster stack installs four addons: `coredns`, `kube-proxy`, `vpc-cni` and
`eks-pod-identity-agent`. There is no EBS CSI driver, so there is no provisioner, so a claim would
stay Pending and the Prometheus StatefulSet with it. Adding the driver would mean another addon,
another IAM role, another set of volumes the sweeper has to know about, and an EBS bill that
continues after the cluster is destroyed if a volume is orphaned.

The lifetime of the data argues the same way. A cloud window is measured in hours. What has to
survive a window is not the TSDB; it is the processed benchmark table under
`materials/measurements/`, which is copied out before teardown.

## Decision

Prometheus writes to an `emptyDir` with a size limit, configured through
`prometheus.prometheusSpec.storageSpec.emptyDir.sizeLimit`. Grafana runs with `persistence.enabled:
false`. Retention is a variable, `prometheus_retention`, and its default of 24h is longer than any
window this project can open: `mise run up` refuses a window longer than eight hours. Retention is
therefore never what drops a sample. What bounds the data is the life of the pod, and behind that the
size limit on the `emptyDir`. Nothing ages out while a benchmark is running, which is what I want; the
series end at teardown, not on a timer.

Grafana's dashboards are provisioned from labelled ConfigMaps and its datasource from the chart, so
there is nothing in Grafana's own database worth keeping.

## Consequences

No CSI driver, no StorageClass, no PersistentVolumeClaims, no orphaned EBS volumes for
`mise run audit` to find.

Restarting the Prometheus pod loses the series. Inside a window that is a real cost, and it is the
reason the raw scrape output is exported to `materials/measurements/` at the end of a run rather than
left in the cluster.

If a later phase needs series that outlive a pod, the answer is remote write to something outside the
cluster, not an EBS volume attached to a Spot-adjacent workload.

## Sources

- kube-prometheus-stack values, `prometheus.prometheusSpec.storageSpec`, with the documented
  `emptyDir` alternative to `volumeClaimTemplate`, read from the chart at version 90.0.0.
- Grafana Helm chart values, `persistence.enabled`, default `false`, from the grafana subchart 13.2.2
  bundled in that release.
- Amazon EKS User Guide, the EBS CSI driver is a separate addon and is not installed by default:
  <https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html>
