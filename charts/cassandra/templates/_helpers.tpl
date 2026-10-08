{{- define "cassandra.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "cassandra.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "cassandra.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cassandra.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "cassandra.labels" -}}
{{ include "cassandra.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/*
Image reference. global.imageRegistry overrides the image's own registry;
a digest wins over the tag.
Usage: include "cassandra.imageRef" (dict "image" .Values.image "global" .Values.global)
*/}}
{{- define "cassandra.imageRef" -}}
{{- $registry := .global.imageRegistry | default .image.registry -}}
{{- $ref := .image.repository -}}
{{- if $registry }}{{ $ref = printf "%s/%s" $registry .image.repository }}{{ end -}}
{{- if .image.digest -}}
{{- printf "%s@%s" $ref .image.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref .image.tag -}}
{{- end -}}
{{- end }}

{{- define "cassandra.image" -}}
{{- include "cassandra.imageRef" (dict "image" .Values.image "global" .Values.global) -}}
{{- end }}

{{- define "cassandra.maintenanceImage" -}}
{{- include "cassandra.imageRef" (dict "image" .Values.maintenance.image "global" .Values.global) -}}
{{- end }}

{{- define "cassandra.imagePullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* Short DNS names resolve through the pod's search path. */}}
{{- define "cassandra.seeds" -}}
{{- $fullname := include "cassandra.fullname" . -}}
{{- $n := min (int .Values.cluster.seedCount) (int .Values.replicaCount) -}}
{{- $seeds := list -}}
{{- range $i := until (int $n) }}
{{- $seeds = append $seeds (printf "%s-%d.%s" $fullname $i $fullname) -}}
{{- end }}
{{- join "," $seeds -}}
{{- end }}

{{- define "cassandra.restrictedContainerSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
{{- end }}

{{/* ---------- Maintenance ---------- */}}

{{/* Validated maintenance.mode. */}}
{{- define "cassandra.maintenanceMode" -}}
{{- $m := .Values.maintenance.mode -}}
{{- if not (has $m (list "cronjob" "sidecar")) -}}
{{- fail (printf "maintenance.mode must be cronjob or sidecar (got %q)" $m) -}}
{{- end -}}
{{- if eq $m "sidecar" -}}
{{- range $task := list "repair" "snapshot" -}}
{{- $t := index $.Values.maintenance $task -}}
{{- if and $t.enabled (not (regexMatch "^[0-9*,/-]+( +[0-9*,/-]+){4}$" (trim $t.schedule))) -}}
{{- fail (printf "maintenance.%s.schedule %q: sidecar mode supports 5-field cron with numbers, *, lists, ranges and steps (no names or @macros)" $task $t.schedule) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $m -}}
{{- end }}

{{/* "true" when the maintenance sidecar should run. */}}
{{- define "cassandra.maintenanceSidecar" -}}
{{- if and (eq (include "cassandra.maintenanceMode" .) "sidecar") (or .Values.maintenance.repair.enabled .Values.maintenance.snapshot.enabled) -}}
true
{{- end -}}
{{- end }}

{{/* ---------- Secrets ---------- */}}

{{- define "cassandra.superuserSecretName" -}}
{{- .Values.auth.superuser.existingSecret | default (printf "%s-superuser" (include "cassandra.fullname" .)) -}}
{{- end }}

{{/* ---------- TLS (kind = "internode" | "client") ---------- */}}

{{/* Enabled TLS kinds, comma separated. */}}
{{- define "cassandra.tlsKinds" -}}
{{- $kinds := list -}}
{{- range $kind := list "internode" "client" -}}
{{- if (index $.Values.tls $kind).enabled }}{{ $kinds = append $kinds $kind }}{{ end -}}
{{- end -}}
{{- join "," $kinds -}}
{{- end }}

{{/* Usage: include "cassandra.tlsSecretName" (dict "ctx" . "kind" "client") */}}
{{- define "cassandra.tlsSecretName" -}}
{{- $t := index .ctx.Values.tls .kind -}}
{{- if $t.certManager.enabled -}}
{{- printf "%s-%s-tls" (include "cassandra.fullname" .ctx) .kind -}}
{{- else -}}
{{- required (printf "tls.%s.existingSecret is required when tls.%s.certManager.enabled=false" .kind .kind) $t.existingSecret -}}
{{- end -}}
{{- end }}

{{- define "cassandra.tlsPasswordSecretName" -}}
{{- (index .ctx.Values.tls .kind).passwordSecret | default (printf "%s-%s-keystore" (include "cassandra.fullname" .ctx) .kind) -}}
{{- end }}

{{/* Placeholder in cassandra.yaml, replaced by the init container. */}}
{{- define "cassandra.tlsPasswordPlaceholder" -}}
{{- printf "__%s_KEYSTORE_PASSWORD__" (upper .) -}}
{{- end }}

{{- define "cassandra.tlsPasswordEnv" -}}
{{- printf "%s_KEYSTORE_PASSWORD" (upper .) -}}
{{- end }}

{{/*
Existing value of a Secret key (base64), or a new random one. Keeps generated
passwords stable across helm upgrade.
Usage: include "cassandra.secretValue" (dict "ctx" . "name" "x" "key" "password")
*/}}
{{- define "cassandra.secretValue" -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace .name -}}
{{- if and $existing $existing.data (hasKey $existing.data .key) -}}
{{- index $existing.data .key -}}
{{- else -}}
{{- randAlphaNum 32 | b64enc -}}
{{- end -}}
{{- end }}

{{- define "cassandra.internodeEncryption" -}}
{{- $e := .Values.tls.internode.encryption -}}
{{- if not (has $e (list "all" "dc" "rack" "none")) -}}
{{- fail (printf "tls.internode.encryption must be all, dc, rack or none (got %q)" $e) -}}
{{- end -}}
{{- if and (eq $e "none") (not .Values.tls.internode.optional) -}}
{{- fail "tls.internode.encryption=none needs tls.internode.optional=true (step 1 of enabling TLS on a running cluster)" -}}
{{- end -}}
{{- $e -}}
{{- end }}

{{/* ---------- cassandra.yaml ---------- */}}

{{/*
Recursive merge of src into dst (dst is modified). Unlike sprig's
mergeOverwrite this also applies false / 0 / "" values from src.
*/}}
{{- define "cassandra.mergeInto" -}}
{{- $dst := .dst -}}
{{- range $k, $v := .src -}}
{{- if and (kindIs "map" $v) (kindIs "map" (index $dst $k)) -}}
{{- include "cassandra.mergeInto" (dict "dst" (index $dst $k) "src" $v) -}}
{{- else -}}
{{- $_ := set $dst $k $v -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
stock 4.1 cassandra.yaml <- .Values.config <- chart-managed keys.
__POD_IP__ and the __<KIND>_KEYSTORE_PASSWORD__ placeholders are filled in
by the init container.
*/}}
{{- define "cassandra.cassandraYaml" -}}
{{- $cfg := fromYaml (.Files.Get "files/cassandra-4.1.yaml") -}}
{{- include "cassandra.mergeInto" (dict "dst" $cfg "src" (deepCopy .Values.config)) -}}
{{- $seedProvider := dict
      "class_name" "org.apache.cassandra.locator.SimpleSeedProvider"
      "parameters" (list (dict "seeds" (include "cassandra.seeds" .))) -}}
{{- $managed := dict
      "cluster_name" .Values.cluster.name
      "seed_provider" (list $seedProvider)
      "listen_address" "__POD_IP__"
      "rpc_address" "0.0.0.0"
      "broadcast_rpc_address" "__POD_IP__"
      "endpoint_snitch" "GossipingPropertyFileSnitch" -}}
{{- if .Values.auth.enabled -}}
{{- $_ := set $managed "authenticator" "PasswordAuthenticator" -}}
{{- $_ := set $managed "authorizer" "CassandraAuthorizer" -}}
{{- end -}}
{{- if .Values.tls.internode.enabled -}}
{{- $t := .Values.tls.internode -}}
{{- $_ := set $managed "server_encryption_options" (dict
      "internode_encryption" (include "cassandra.internodeEncryption" .)
      "optional" $t.optional
      "legacy_ssl_storage_port_enabled" false
      "keystore" (printf "/etc/cassandra/tls/internode/%s" $t.keystoreFile)
      "keystore_password" (include "cassandra.tlsPasswordPlaceholder" "internode")
      "truststore" (printf "/etc/cassandra/tls/internode/%s" $t.truststoreFile)
      "truststore_password" (include "cassandra.tlsPasswordPlaceholder" "internode")
      "store_type" $t.storeType
      "require_client_auth" $t.requireClientAuth
      "require_endpoint_verification" $t.requireEndpointVerification) -}}
{{- end -}}
{{- if .Values.tls.client.enabled -}}
{{- $c := .Values.tls.client -}}
{{- $_ := set $managed "client_encryption_options" (dict
      "enabled" true
      "optional" $c.optional
      "keystore" (printf "/etc/cassandra/tls/client/%s" $c.keystoreFile)
      "keystore_password" (include "cassandra.tlsPasswordPlaceholder" "client")
      "truststore" (printf "/etc/cassandra/tls/client/%s" $c.truststoreFile)
      "truststore_password" (include "cassandra.tlsPasswordPlaceholder" "client")
      "store_type" $c.storeType
      "require_client_auth" $c.requireClientAuth) -}}
{{- end -}}
{{- include "cassandra.mergeInto" (dict "dst" $cfg "src" $managed) -}}
{{- toYaml $cfg -}}
{{- end }}
