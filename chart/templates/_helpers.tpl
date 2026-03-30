{{/*
Expand the name of the chart.
*/}}
{{- define "discourse.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncated at 63 chars because some Kubernetes name fields are limited to this.
*/}}
{{- define "discourse.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "discourse.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "discourse.labels" -}}
helm.sh/chart: {{ include "discourse.chart" . }}
{{ include "discourse.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "discourse.selectorLabels" -}}
app.kubernetes.io/name: {{ include "discourse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "discourse.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "discourse.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Discourse container image reference.
Requires image.repository to be set by the user.
*/}}
{{- define "discourse.image" -}}
{{- $repo := required "image.repository is required -- set it to your custom Discourse image" .Values.image.repository -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- printf "%s:%s" $repo $tag }}
{{- end }}

{{/*
Redis sidecar image reference.
*/}}
{{- define "discourse.redisImage" -}}
{{- printf "%s:%s" .Values.redis.image.repository .Values.redis.image.tag }}
{{- end }}

{{/*
ConfigMap name.
*/}}
{{- define "discourse.configmapName" -}}
{{- printf "%s-config" (include "discourse.fullname" .) }}
{{- end }}

{{/*
Chart-managed Secret name (for inline passwords).
*/}}
{{- define "discourse.secretName" -}}
{{- printf "%s-secret" (include "discourse.fullname" .) }}
{{- end }}

{{/*
Determine if the chart-managed Secret should be created.
True when at least one inline password is provided and no existingSecret
is set for that credential.
*/}}
{{- define "discourse.createSecret" -}}
{{- $create := false -}}
{{- if and .Values.discourse.database.password (not .Values.discourse.database.existingSecret) -}}
  {{- $create = true -}}
{{- end -}}
{{- if and .Values.discourse.smtp.password (not .Values.discourse.smtp.existingSecret) -}}
  {{- $create = true -}}
{{- end -}}
{{- if and .Values.discourse.secretKeyBase.value (not .Values.discourse.secretKeyBase.existingSecret) -}}
  {{- $create = true -}}
{{- end -}}
{{- if and .Values.discourse.admin.password (not .Values.discourse.admin.existingSecret) -}}
  {{- $create = true -}}
{{- end -}}
{{- if $create -}}
true
{{- end -}}
{{- end }}

{{/*
Determine if any secret env vars or extraEnv entries exist.
Used to conditionally render the env: key in container specs.
*/}}
{{- define "discourse.hasEnvVars" -}}
{{- $has := false -}}
{{- if or .Values.discourse.database.existingSecret (and (include "discourse.createSecret" .) .Values.discourse.database.password) -}}
  {{- $has = true -}}
{{- end -}}
{{- if or .Values.discourse.smtp.existingSecret (and (include "discourse.createSecret" .) .Values.discourse.smtp.password) -}}
  {{- $has = true -}}
{{- end -}}
{{- if or .Values.discourse.secretKeyBase.existingSecret (and (include "discourse.createSecret" .) .Values.discourse.secretKeyBase.value) -}}
  {{- $has = true -}}
{{- end -}}
{{- if .Values.discourse.extraEnv -}}
  {{- $has = true -}}
{{- end -}}
{{- if $has -}}
true
{{- end -}}
{{- end }}

{{/*
Secret environment variables block.
Shared across unicorn, sidekiq, and migrate containers.
Only outputs actual env var entries (no comments) so the env: key
can be conditionally rendered.
*/}}
{{- define "discourse.secretEnvVars" -}}
{{- if or .Values.discourse.database.existingSecret (and (include "discourse.createSecret" .) .Values.discourse.database.password) }}
- name: DISCOURSE_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ default (include "discourse.secretName" .) .Values.discourse.database.existingSecret }}
      key: {{ .Values.discourse.database.secretKey }}
{{- end }}
{{- if or .Values.discourse.smtp.existingSecret (and (include "discourse.createSecret" .) .Values.discourse.smtp.password) }}
- name: DISCOURSE_SMTP_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ default (include "discourse.secretName" .) .Values.discourse.smtp.existingSecret }}
      key: {{ .Values.discourse.smtp.secretKey }}
{{- end }}
{{- if or .Values.discourse.secretKeyBase.existingSecret (and (include "discourse.createSecret" .) .Values.discourse.secretKeyBase.value) }}
- name: DISCOURSE_SECRET_KEY_BASE
  valueFrom:
    secretKeyRef:
      name: {{ default (include "discourse.secretName" .) .Values.discourse.secretKeyBase.existingSecret }}
      key: {{ .Values.discourse.secretKeyBase.secretKey }}
{{- end }}
{{- end }}

{{/*
Sidekiq command with configurable concurrency and all Discourse queues.
Discourse uses 4 weighted queues: critical (8), default (4), low (2), ultra_low (1).
Without explicit -q flags, standalone Sidekiq only processes "default".
*/}}
{{- define "discourse.sidekiqCommand" -}}
["bundle", "exec", "sidekiq", "-e", "production", "-c", {{ .Values.discourse.sidekiqConcurrency | quote }}, "-q", "critical,8", "-q", "default,4", "-q", "low,2", "-q", "ultra_low,1"]
{{- end }}

{{/*
PVC name for uploads.
*/}}
{{- define "discourse.uploadsPvcName" -}}
{{- if .Values.persistence.uploads.existingClaim }}
{{- .Values.persistence.uploads.existingClaim }}
{{- else }}
{{- printf "%s-uploads" (include "discourse.fullname" .) }}
{{- end }}
{{- end }}

{{/*
PVC name for backups.
*/}}
{{- define "discourse.backupsPvcName" -}}
{{- if .Values.persistence.backups.existingClaim }}
{{- .Values.persistence.backups.existingClaim }}
{{- else }}
{{- printf "%s-backups" (include "discourse.fullname" .) }}
{{- end }}
{{- end }}
