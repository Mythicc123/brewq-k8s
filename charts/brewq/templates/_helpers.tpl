{{- define "brewq.selectorLabels" -}}
app.kubernetes.io/name: brewq
app.kubernetes.io/instance: brewq
{{- end }}

{{- define "brewq.labels" -}}
{{ include "brewq.selectorLabels" . }}
app.kubernetes.io/part-of: brewq
{{- end }}

{{- define "brewq.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop:
    - ALL
{{- end }}
