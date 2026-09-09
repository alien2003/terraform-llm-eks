# 0032. Kubernetes 1.35 on the control plane

Date: 2026-09-08

## Status

Accepted.

## Context

EKS charges a higher hourly rate for a cluster whose Kubernetes version has fallen out of standard
support and into extended support. So the version is a cost decision as much as a compatibility one,
and it cannot be written from memory: the release calendar moves.

Reading the EKS release calendar on the day this was decided, 2026-09-08:

| Version | EKS release | End of standard support |
| --- | --- | --- |
| 1.36 | June 2, 2026 | August 2, 2027 |
| 1.35 | January 27, 2026 | March 27, 2027 |
| 1.34 | October 2, 2025 | December 2, 2026 |
| 1.33 | May 29, 2025 | July 29, 2026 |

1.33 and everything below it is already in extended support. 1.34, 1.35 and 1.36 are the three in
standard support.

## Decision

`kubernetes_version = "1.35"`.

## Consequences

1.34 was rejected because its standard support ends on 2026-12-02, under three months away. A project
that runs for a few more windows would find itself paying the extended support rate without anyone
having decided to.

1.36 was rejected because it went out in June 2026. It is the newest and the least worn. Addon
versions, the EKS optimized AMI line and the Karpenter release that supports it are all younger there,
and every hour spent finding out that something does not work yet on the newest minor is an hour
inside a paid window.

1.35 has been out since January 2026 and its standard support runs to 2027-03-27, which is longer than
this project will exist. It is the version with the most field time that is not about to start
charging extra.

This is a variable with a validation on its shape, not a constant. Re-read the release calendar before
the first window: if the dates have moved, the reasoning above still applies and the answer might not.

## Sources

- Understand the Kubernetes version lifecycle on EKS, "Amazon EKS Kubernetes release calendar". The
  table above is transcribed from it.
  <https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html>
- Amazon EKS extended support for Kubernetes versions pricing: "Standard support begins when a version
  becomes available in Amazon EKS, and continues for 14 months... Extended support in Amazon EKS
  begins immediately at the end of standard support and continues for 12 months."
  <https://aws.amazon.com/blogs/containers/amazon-eks-extended-support-for-kubernetes-versions-pricing/>
