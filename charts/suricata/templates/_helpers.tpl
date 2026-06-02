{{/*
Helpers minimalistas. Solo lo que usamos REALMENTE en los templates —
nada de los 50+ helpers que `helm create` genera por defecto.

fullname: usado para nombrar todos los recursos del release.
labels:   set canónico de labels recomendado por k8s + Helm.
selectorLabels: subset usado en .spec.selector.matchLabels (debe ser estable
                entre upgrades, por eso no incluye version/chart).
*/}}

{{- define "suricata.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "suricata.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "suricata.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "suricata.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
