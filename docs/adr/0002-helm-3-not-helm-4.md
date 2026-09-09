# 0002. Helm 3.21.4 on the toolchain, not Helm 4

Date: 2026-09-08

## Status

Accepted.

## Context

Helm 4.0.0 was released on 2025-11-12 and the current stable release at the time of writing is 4.2.4.
Picking it would be the obvious default. It is not what `mise.toml` pins.

Helm 3 has not been superseded in the way "version 4 is out" suggests. The two lines are maintained in
parallel: 4.2.4 was published on 2026-08-13 and 3.21.4 on 2026-08-14, one day apart. Choosing 3 is choosing
a maintained release, not an abandoned one.

The reason that decided it for me is that this project does not install charts with the Helm CLI. It
installs them with the Terraform helm provider, pinned to `hashicorp/helm` 3.3.0, and that provider vendors
the Helm 3 SDK: its `go.mod` requires `helm.sh/helm/v3 v3.20.2`. Whatever Terraform renders during an
apply, it renders with Helm 3 code.

The CLI's job in this repository is to render the same charts offline so that CI can check them without a
cluster: `helm lint`, then `helm template` piped to `kubeconform` against the real CRD schemas. That check
is only worth running if what it renders is what Terraform will apply. A Helm 4 CLI rendering charts that a
Helm 3 provider will install is a check that can pass while the apply fails, which is the least useful kind
of check to have in a pipeline that has to be green before a paid window opens.

Helm's own release notes describe 4.0.0 as "a major version with backward incompatible changes including to
the flags and output of the Helm CLI and to the SDK", while noting that `apiVersion: v2` charts continue to
be supported. So the charts would probably render. "Probably" is what I am not willing to buy: the failure would
appear as a rendering difference inside a window rather than as a red build beforehand.

## Decision

`mise.toml` pins `helm = "3.21.4"`, the newest Helm 3 release. CI installs the same one. Charts are rendered
and validated with it, and applied through `hashicorp/helm` 3.3.0.

## Consequences

The Helm 4 features named in its release notes are unavailable here: server-side apply, the redesigned
plugin system, kstatus-based resource watching. None of them is needed by this project, which installs a
handful of charts into a cluster that lives for a few hours.

The CLI at 3.21.4 is one minor release ahead of the 3.20.2 SDK the provider vendors. That gap is small,
both are Helm 3, and it is the closest agreement available without pinning the CLI backwards to match a
vendored dependency that will move on the provider's schedule rather than mine. It is worth re-checking
whenever the helm provider pin changes: the provider's `go.mod` is where the answer is.

Revisit this when the helm provider ships a release built on the Helm 4 SDK. At that point the CLI and the
provider should move together, in one commit, with the charts re-rendered and the `kubeconform` output
compared before and after.

## Sources

- Helm 4.0.0 release notes, for the release date and the compatibility statement quoted above:
  <https://github.com/helm/helm/releases/tag/v4.0.0>
- Helm releases, for the parallel 3.21.4 and 4.2.4 publication dates:
  <https://github.com/helm/helm/releases>
- `terraform-provider-helm` v3.3.0 `go.mod`, which requires `helm.sh/helm/v3 v3.20.2`:
  <https://github.com/hashicorp/terraform-provider-helm/blob/v3.3.0/go.mod>
