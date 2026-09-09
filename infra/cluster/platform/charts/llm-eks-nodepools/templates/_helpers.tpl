{{/* Common labels on every object this chart creates. */}}
{{- define "llm-eks-nodepools.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: terraform-llm-eks
{{- end -}}

{{/*
Identity of a Karpenter node: exactly one of spec.role or spec.instanceProfile.
Setting both is rejected by the CRD, setting neither means Karpenter can never
launch a node.
*/}}
{{- define "llm-eks-nodepools.nodeIdentity" -}}
{{- if .Values.nodeInstanceProfile -}}
instanceProfile: {{ .Values.nodeInstanceProfile | quote }}
{{- else if .Values.nodeRole -}}
role: {{ .Values.nodeRole | quote }}
{{- else -}}
{{- fail "set exactly one of nodeInstanceProfile or nodeRole" -}}
{{- end -}}
{{- end -}}

{{/*
Tags on every AWS resource Karpenter creates from this node class.

Karpenter's own documentation: "Karpenter adds tags to all resources it creates,
including EC2 Instances, EBS volumes, and Launch Templates", and it refuses
overrides in the karpenter.sh, karpenter.k8s.aws and kubernetes.io/cluster
domains, none of which this chart touches.
https://karpenter.sh/docs/concepts/nodeclasses/

This is the only tag path the GPU instances have. `tags = local.default_tags` on
the eks module reaches the managed node group's launch template and nothing
Karpenter launches, so if this block loses a key the g6 nodes stop matching the
selectors that `mise run audit` and the always-on sweeper use, and an accelerator
can outlive its window unnoticed. That is why a missing key is a template failure
rather than a smaller tag map: `helm lint` and `helm template` both run it, so the
mistake is caught with no cluster and no credentials.
*/}}
{{- define "llm-eks-nodepools.tags" -}}
{{- range $key := list "Project" "Stack" "ManagedBy" -}}
{{- if not (index $.Values.tags $key) -}}
{{- fail (printf "tags.%s is missing or empty. mise run audit and the sweeper both select on Project=terraform-llm-eks; an instance Karpenter launches without these tags is invisible to both." $key) -}}
{{- end -}}
{{- end -}}
{{- toYaml .Values.tags -}}
{{- end -}}
