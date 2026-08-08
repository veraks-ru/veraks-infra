{{/* Общие имена и метки. Имена ресурсов — veraks-<компонент>. */}}

{{- define "veraks.labels" -}}
app.kubernetes.io/name: veraks
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
T9: раздельные URL БД — владелец схемы (только миграции/DDL, включая
ALTER DEFAULT PRIVILEGES из scripts/create_app_role.py) и непривилегированная
роль приложения orakul_app (рантайм backend/worker; нет UPDATE/DELETE на
append-only — REVOKE из миграций 0011/0029 действует, только если роль уже
создана initContainer'ом bootstrap-app-role в backend.yaml).
*/}}
{{- define "veraks.databaseUrlOwner" -}}
postgresql+asyncpg://veraks:{{ .Values.secrets.postgresPassword }}@veraks-postgres:5432/veraks
{{- end -}}

{{- define "veraks.databaseUrlApp" -}}
postgresql+asyncpg://orakul_app:{{ .Values.secrets.appDbPassword }}@veraks-postgres:5432/veraks
{{- end -}}

{{/*
Ссылка на образ приложения. Если задан digest — используем его, иначе тег.

Плавающий :latest дважды приводил к тому, что деплой поднимал ПРЕДЫДУЩИЙ
образ: статус сборки становится success раньше, чем образ дозаливается в
реестр. Digest снимается в момент деплоя из самого реестра, поэтому
подхватить не тот образ невозможно, а изменение digest'а меняет манифест —
поды пересоздаются сами, без внешнего rollout restart.
*/}}
{{- define "veraks.image" -}}
{{- if .digest -}}
{{ .repository }}@{{ .digest }}
{{- else -}}
{{ .repository }}:{{ .tag }}
{{- end -}}
{{- end -}}
