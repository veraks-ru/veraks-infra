{{/* Общие имена и метки. Имена ресурсов — veraks-<компонент>. */}}

{{- define "veraks.labels" -}}
app.kubernetes.io/name: veraks
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* URL БД внутри кластера, собранный с паролем из секрета. */}}
{{- define "veraks.databaseUrl" -}}
postgresql+asyncpg://veraks:{{ .Values.secrets.postgresPassword }}@veraks-postgres:5432/veraks
{{- end -}}
