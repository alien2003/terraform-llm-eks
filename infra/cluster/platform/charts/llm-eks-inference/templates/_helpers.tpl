{{- define "llm-eks-inference.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "llm-eks-inference.labels" -}}
app.kubernetes.io/name: {{ include "llm-eks-inference.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/component: inference
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: terraform-llm-eks
{{- end -}}

{{- define "llm-eks-inference.selectorLabels" -}}
app.kubernetes.io/name: {{ include "llm-eks-inference.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Image reference, pinned by digest when one is given. */}}
{{- define "llm-eks-inference.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}

{{/* Absolute path the weights are staged to and vLLM reads from. */}}
{{- define "llm-eks-inference.modelPath" -}}
{{ .Values.model.mountPath }}/{{ .Values.model.id }}
{{- end -}}
