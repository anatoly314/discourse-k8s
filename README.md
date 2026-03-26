# discourse-k8s

Custom Docker image and Helm chart for deploying [Discourse](https://www.discourse.org) on Kubernetes.

Created because no well-maintained, free Helm chart exists for Discourse. Bitnami's chart was killed when Broadcom ended free updates (August 2025), and every other option is abandoned. This project provides a working, opinionated setup using the [Nfrastack](https://github.com/nfrastack/container-discourse) base image.

## Architecture

```
+---------------------------------------------------+
|  Pod                                              |
|                                                   |
|  +-------------------+    +-------------------+   |
|  |    discourse       |    |      redis        |   |
|  |                   |    |    (sidecar)       |   |
|  |  Unicorn :3000    |    |    :6379           |   |
|  |  Sidekiq          |    |    ephemeral       |   |
|  |  (s6-overlay)     |<-->|    no PVC          |   |
|  +-------------------+    +-------------------+   |
|          |                                        |
+----------|----------------------------------------+
           |
    +------v-------+
    |  PostgreSQL   |     (external, e.g. CNPG)
    |  hstore       |
    |  pg_trgm      |
    +--------------+
```

The pod runs two containers:

- **discourse** -- Custom image extending Nfrastack. Runs Unicorn (web server) and Sidekiq (background jobs) via s6-overlay process supervisor. Exposes port 3000.
- **redis** -- `redis:7-alpine` sidecar. Ephemeral (emptyDir, no PVC). Handles Sidekiq job queue, caching, and MessageBus real-time delivery. Not a data store -- PostgreSQL is the source of truth.

Redis runs as a sidecar rather than a separate Deployment because it is purely ephemeral cache/queue. A full Redis Deployment for a forum is overkill when localhost access from the same pod is all that's needed.

### Why a custom Docker image?

Discourse plugins contribute JavaScript and CSS to the compiled asset bundle. They must be present when `rake assets:precompile` runs -- you cannot install them at runtime. The custom image bakes in plugins and precompiles assets so pods start in seconds instead of 5-15 minutes.

## Prerequisites

- Kubernetes cluster (tested on k3s, should work on any conformant cluster)
- External PostgreSQL database with `hstore` and `pg_trgm` extensions enabled
- Helm 3
- Docker (only if building the custom image yourself)

## Quick Start

### 1. Get the Docker image

**Option A: Use the pre-built image from GHCR**

```
ghcr.io/anatoly314/discourse-k8s:v0.1.0
```

**Option B: Build your own**

```bash
docker build -t my-registry/discourse:v2026.2.1 docker/
```

### 2. Prepare PostgreSQL

Create a database with the required extensions:

```sql
CREATE DATABASE discourse;
\c discourse
CREATE EXTENSION IF NOT EXISTS hstore;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

### 3. Generate a secret key

```bash
openssl rand -hex 64
```

### 4. Create a values file

```yaml
# my-values.yaml
image:
  repository: ghcr.io/anatoly314/discourse-k8s
  tag: v0.1.0

discourse:
  hostname: forum.example.com
  developerEmails: "admin@example.com"

  admin:
    email: "admin@example.com"
    password: "changeme1234"   # min 10 chars

  database:
    host: postgres.svc.cluster.local
    name: discourse
    username: discourse
    password: "your-db-password"

  secretKeyBase:
    value: "your-128-char-hex-string"

  smtp:
    address: smtp.example.com
    port: 587
    domain: example.com
    username: "smtp-user"
    password: "smtp-password"
```

### 5. Install

**From GHCR OCI registry:**

```bash
helm install discourse oci://ghcr.io/anatoly314/helm-charts/discourse \
  --version 0.1.0 \
  -f my-values.yaml \
  --namespace discourse \
  --create-namespace
```

**From a local checkout:**

```bash
helm install discourse chart/ \
  -f my-values.yaml \
  --namespace discourse \
  --create-namespace
```

### 6. Wait for first boot

First startup takes 5-10 minutes while database migrations run. Monitor progress:

```bash
kubectl logs -f deploy/discourse -c discourse -n discourse
```

The startup probe allows up to ~10 minutes before marking the pod as failed. Once ready:

```bash
kubectl port-forward svc/discourse 3000:80 -n discourse
# Open http://localhost:3000
```

## Parameters

### Image parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `image.repository` | Discourse container image repository | `""` |
| `image.tag` | Discourse container image tag (defaults to Chart.appVersion if empty) | `""` |
| `image.pullPolicy` | Discourse container image pull policy | `IfNotPresent` |
| `imagePullSecrets` | Docker registry secret names as an array | `[]` |
| `nameOverride` | String to partially override the release name | `""` |
| `fullnameOverride` | String to fully override the release name | `""` |

### Redis sidecar parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `redis.image.repository` | Redis sidecar image repository | `redis` |
| `redis.image.tag` | Redis sidecar image tag | `7-alpine` |
| `redis.image.pullPolicy` | Redis sidecar image pull policy | `IfNotPresent` |
| `redis.resources.requests.memory` | Redis sidecar memory request | `64Mi` |
| `redis.resources.requests.cpu` | Redis sidecar CPU request | `50m` |
| `redis.resources.limits.memory` | Redis sidecar memory limit | `128Mi` |

### Discourse parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `discourse.hostname` | Public hostname for the forum (required) | `""` |
| `discourse.developerEmails` | Comma-separated emails that get initial admin access (required for first boot) | `""` |
| `discourse.admin.username` | Admin account username (first boot only) | `"admin"` |
| `discourse.admin.email` | Admin account email (first boot only) | `""` |
| `discourse.admin.name` | Admin account display name (first boot only) | `"Admin User"` |
| `discourse.admin.password` | Admin account password, min 10 chars (ignored if existingSecret is set) | `""` |
| `discourse.admin.existingSecret` | Name of an existing Secret containing the admin password | `""` |
| `discourse.admin.secretKey` | Key within the existing Secret for the admin password | `admin-password` |
| `discourse.database.host` | PostgreSQL host (required) | `""` |
| `discourse.database.port` | PostgreSQL port | `5432` |
| `discourse.database.name` | PostgreSQL database name | `discourse` |
| `discourse.database.username` | PostgreSQL username | `discourse` |
| `discourse.database.pool` | PostgreSQL connection pool size | `8` |
| `discourse.database.password` | PostgreSQL password (ignored if existingSecret is set) | `""` |
| `discourse.database.existingSecret` | Name of an existing Secret containing the database password | `""` |
| `discourse.database.secretKey` | Key within the existing Secret for the database password | `db-password` |
| `discourse.redis.host` | Redis host (defaults to localhost sidecar) | `localhost` |
| `discourse.redis.port` | Redis port | `6379` |
| `discourse.redis.db` | Redis database number | `0` |
| `discourse.smtp.address` | SMTP server address | `""` |
| `discourse.smtp.port` | SMTP server port | `587` |
| `discourse.smtp.domain` | SMTP HELO domain | `""` |
| `discourse.smtp.username` | SMTP username | `""` |
| `discourse.smtp.authentication` | SMTP authentication method (plain, login, or cram_md5) | `plain` |
| `discourse.smtp.enableStartTls` | Enable STARTTLS for SMTP | `true` |
| `discourse.smtp.password` | SMTP password (ignored if existingSecret is set) | `""` |
| `discourse.smtp.existingSecret` | Name of an existing Secret containing the SMTP password | `""` |
| `discourse.smtp.secretKey` | Key within the existing Secret for the SMTP password | `smtp-password` |
| `discourse.secretKeyBase.value` | Rails secret key base, 128-char hex string (ignored if existingSecret is set) | `""` |
| `discourse.secretKeyBase.existingSecret` | Name of an existing Secret containing the secret key base | `""` |
| `discourse.secretKeyBase.secretKey` | Key within the existing Secret for the secret key base | `secret-key-base` |
| `discourse.serveStaticAssets` | Serve static assets directly from Unicorn (no nginx in front) | `true` |
| `discourse.forceHttps` | Force HTTPS (maps to DELIVER_SECURE_ASSETS in Nfrastack) | `true` |
| `discourse.unicornWorkers` | Number of Unicorn web server worker processes | `4` |
| `discourse.sidekiqThreads` | Number of Sidekiq background job threads | `5` |
| `discourse.enableDbMigrate` | Run database migrations on startup | `true` |
| `discourse.enablePrecompileAssets` | Precompile assets on startup (leave false -- bake into Docker image instead) | `false` |
| `discourse.plugins` | Map of plugin short names to booleans to enable/disable bundled plugins | `{}` |
| `discourse.extraEnv` | Array of extra environment variables for the Discourse container | `[]` |

> **OIDC (OpenID Connect)** is configured via Discourse site settings, not environment variables. Use `discourse.extraEnv` to set them at deploy time:
>
> ```yaml
> discourse:
>   extraEnv:
>     - name: DISCOURSE_OPENID_CONNECT_ENABLED
>       value: "true"
>     - name: DISCOURSE_OPENID_CONNECT_DISCOVERY_DOCUMENT
>       value: "https://keycloak.example.com/realms/myrealm/.well-known/openid-configuration"
>     - name: DISCOURSE_OPENID_CONNECT_CLIENT_ID
>       value: "discourse"
>     - name: DISCOURSE_OPENID_CONNECT_CLIENT_SECRET
>       valueFrom:
>         secretKeyRef:
>           name: discourse-oidc
>           key: client-secret
> ```

### Init container parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `initContainers.waitForPostgres.enabled` | Enable init container that waits for PostgreSQL to be reachable | `true` |
| `initContainers.waitForPostgres.image.repository` | Init container image repository | `busybox` |
| `initContainers.waitForPostgres.image.tag` | Init container image tag | `"1.37"` |
| `initContainers.waitForPostgres.image.pullPolicy` | Init container image pull policy | `IfNotPresent` |

### Persistence parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `persistence.uploads.enabled` | Enable persistent storage for user uploads, avatars, and attachments | `true` |
| `persistence.uploads.size` | Size of the uploads PVC | `10Gi` |
| `persistence.uploads.storageClass` | Storage class for the uploads PVC (empty string uses cluster default) | `""` |
| `persistence.uploads.accessModes` | Access modes for the uploads PVC | `["ReadWriteOnce"]` |
| `persistence.uploads.existingClaim` | Name of an existing PVC to use for uploads | `""` |
| `persistence.backups.enabled` | Enable persistent storage for Discourse backup archives | `false` |
| `persistence.backups.size` | Size of the backups PVC | `10Gi` |
| `persistence.backups.storageClass` | Storage class for the backups PVC (empty string uses cluster default) | `""` |
| `persistence.backups.accessModes` | Access modes for the backups PVC | `["ReadWriteOnce"]` |
| `persistence.backups.existingClaim` | Name of an existing PVC to use for backups | `""` |

### Network parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `service.type` | Kubernetes Service type | `ClusterIP` |
| `service.port` | Service port | `80` |
| `service.targetPort` | Container port the Service routes to | `3000` |
| `service.annotations` | Additional annotations for the Service | `{}` |
| `ingress.enabled` | Enable Ingress resource | `false` |
| `ingress.className` | Ingress class name | `""` |
| `ingress.annotations` | Additional annotations for the Ingress | `{}` |
| `ingress.hosts` | Array of Ingress host configurations | `[]` |
| `ingress.tls` | Array of Ingress TLS configurations | `[]` |

### Resource parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `resources.requests.memory` | Discourse container memory request | `1Gi` |
| `resources.requests.cpu` | Discourse container CPU request | `500m` |
| `resources.limits.memory` | Discourse container memory limit | `2Gi` |

### Service account parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `serviceAccount.create` | Create a ServiceAccount for the pod | `false` |
| `serviceAccount.annotations` | Additional annotations for the ServiceAccount | `{}` |
| `serviceAccount.name` | Name of the ServiceAccount (auto-generated if empty and create is true) | `""` |

### Pod parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `nodeSelector` | Node labels for pod assignment | `{}` |
| `tolerations` | Tolerations for pod scheduling | `[]` |
| `affinity` | Affinity rules for pod scheduling | `{}` |
| `podAnnotations` | Additional annotations for the pod | `{}` |
| `podLabels` | Additional labels for the pod | `{}` |
| `podSecurityContext` | Security context for the pod | `{}` |
| `securityContext` | Security context for the Discourse container | `{}` |
| `restartPolicy` | Pod restart policy | `Always` |
| `terminationGracePeriodSeconds` | Seconds the pod needs to terminate gracefully | `60` |

Specify each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example:

```bash
helm install discourse oci://ghcr.io/anatoly314/helm-charts/discourse \
  --set discourse.hostname=forum.example.com \
  --set discourse.database.host=postgres.svc.cluster.local
```

Alternatively, provide a YAML file with the values using `-f`:

```bash
helm install discourse oci://ghcr.io/anatoly314/helm-charts/discourse -f my-values.yaml
```

> **Note:** Every secret field (database, smtp, secretKeyBase, admin) supports two patterns -- an inline `password`/`value` for simple setups, or `existingSecret` + `secretKey` to reference a pre-existing Kubernetes Secret (for Vault, ESO, or similar operators). See the table entries above for each field.

## Building the Custom Image

The [`docker/Dockerfile`](docker/Dockerfile) extends the Nfrastack base image in two steps:

1. **Copies all bundled plugins** from `/container/data/discourse/plugins/` into `/app/plugins/` (hard-copy, not symlink -- see the Dockerfile comments for why)
2. **Precompiles assets** (`bundle exec rake assets:precompile`) so the ~5-15 minute compilation happens at build time, not on every pod startup

### Build arguments

| Arg | Default | Description |
|-----|---------|-------------|
| `BASE_IMAGE` | `ghcr.io/nfrastack/container-discourse:latest` | Nfrastack base image |
| `DISCOURSE_VERSION` | `v2026.2.1` | Version label for OCI metadata |

### Build examples

```bash
# Default build
docker build -t my-discourse:v2026.2.1 docker/

# Pin a specific base image version
docker build \
  --build-arg BASE_IMAGE=ghcr.io/nfrastack/container-discourse:v2026.2.1 \
  -t my-discourse:v2026.2.1 docker/
```

### Customizing plugins

The image enables bundled plugins via `PLUGIN_ENABLE_*` environment variables. To add a third-party plugin (one not shipped with Discourse core), you would need to modify the Dockerfile to clone it into `/app/plugins/` before the asset precompilation step.

The [`docker/plugins.txt`](docker/plugins.txt) file documents all plugin Git URLs for reference but is not consumed by the build.

## Docker Image Environment Variables

### Customizable environment variables

| Name | Description | Default Value |
| ---- | ----------- | ------------- |
| `ENABLE_PRECOMPILE_ASSETS` | Precompile assets on startup (FALSE because assets are already compiled in this image) | `FALSE` |
| `ENABLE_DB_MIGRATE` | Run Rails database migrations on every startup (safe -- migrations are idempotent) | `TRUE` |
| `SERVE_STATIC_ASSETS` | Serve static assets directly from Unicorn (no nginx in front) | `TRUE` |
| `PLUGIN_PRIORITY` | Prefer image-bundled plugins over host-mounted plugins in /data/plugins/ | `image` |
| `PLUGIN_ENABLE_OPENID_CONNECT` | Enable the OpenID Connect SSO plugin | `TRUE` |
| `PLUGIN_ENABLE_TOPIC_VOTING` | Enable the Topic Voting plugin | `TRUE` |
| `PLUGIN_ENABLE_CHAT` | Enable the Chat plugin (channels, DMs, threads) | `TRUE` |
| `PLUGIN_ENABLE_SOLVED` | Enable the Solved plugin (mark replies as accepted solutions) | `TRUE` |
| `PLUGIN_ENABLE_AI` | Enable the AI plugin (summarize, classify) | `TRUE` |
| `PLUGIN_ENABLE_ASSIGN` | Enable the Assign plugin (assign topics to staff) | `TRUE` |
| `PLUGIN_ENABLE_AUTOMATION` | Enable the Automation plugin (triggers and actions) | `TRUE` |
| `PLUGIN_ENABLE_POLL` | Enable the Poll plugin | `TRUE` |
| `PLUGIN_ENABLE_CHECKLIST` | Enable the Checklist plugin (checkbox lists in posts) | `TRUE` |
| `PLUGIN_ENABLE_DETAILS` | Enable the Details plugin (collapsible blocks) | `TRUE` |
| `PLUGIN_ENABLE_NARRATIVE_BOT` | Enable the Narrative Bot plugin (new user tutorial) | `TRUE` |
| `PLUGIN_ENABLE_PRESENCE` | Enable the Presence plugin (typing indicators) | `TRUE` |
| `PLUGIN_ENABLE_REACTIONS` | Enable the Reactions plugin (post reactions) | `TRUE` |
| `PLUGIN_ENABLE_STYLEGUIDE` | Enable the Styleguide plugin (admin theming reference) | `TRUE` |

### Build arguments

| Name | Description | Default Value |
| ---- | ----------- | ------------- |
| `BASE_IMAGE` | Nfrastack base image used as the build foundation | `ghcr.io/nfrastack/container-discourse:latest` |
| `DISCOURSE_VERSION` | Discourse version label applied to OCI image metadata | `v2026.2.1` |

## CI/CD

Both the Docker image and Helm chart are built and published by GitHub Actions, triggered by tags.

### Docker image

- **Trigger:** Push a tag matching `docker/v*` (e.g. `docker/v2026.2.1`)
- **Registry:** `ghcr.io/anatoly314/discourse-k8s`
- **Tags produced:** Version tag + `latest`
- **Workflow:** [`.github/workflows/docker.yml`](.github/workflows/docker.yml)

```bash
git tag docker/v2026.2.1
git push origin docker/v2026.2.1
```

### Helm chart

- **Trigger:** Push a tag matching `chart/v*` (e.g. `chart/v0.1.0`)
- **Registry:** `oci://ghcr.io/anatoly314/helm-charts`
- **Workflow:** [`.github/workflows/helm.yml`](.github/workflows/helm.yml)

```bash
git tag chart/v0.1.0
git push origin chart/v0.1.0
```

### Consuming the chart from GHCR

```bash
# Pull and inspect
helm pull oci://ghcr.io/anatoly314/helm-charts/discourse --version 0.1.0

# Install directly
helm install discourse oci://ghcr.io/anatoly314/helm-charts/discourse \
  --version 0.1.0 -f my-values.yaml -n discourse --create-namespace
```

### ArgoCD (multi-source pattern)

```yaml
spec:
  sources:
    - repoURL: https://github.com/anatoly314/<infra-repo>.git
      targetRevision: HEAD
      ref: values
    - repoURL: ghcr.io/anatoly314/helm-charts
      chart: discourse
      targetRevision: 0.1.0
      helm:
        valueFiles:
          - $values/apps/discourse/values.yaml
```

## Included Plugins

| Plugin | Description | Default |
|--------|-------------|---------|
| `openid-connect` | OIDC SSO (Keycloak, Auth0, etc.) | Enabled |
| `topic-voting` | Category-level feature voting | Enabled |
| `chat` | Real-time chat channels, DMs, threads | Enabled |
| `solved` | Mark replies as accepted solutions | Enabled |
| `ai` | AI-powered features (summarize, classify) | Enabled |
| `assign` | Assign topics/posts to staff | Enabled |
| `automation` | Automate actions via triggers | Enabled |
| `poll` | Polls in posts | Enabled |
| `checklist` | Checkbox lists in posts | Enabled |
| `details` | Collapsible detail/summary blocks | Enabled |
| `narrative-bot` | New user tutorial bot | Enabled |
| `presence` | "User is typing" indicators | Enabled |
| `reactions` | Post reactions beyond simple likes | Enabled |
| `styleguide` | Admin style guide for theming | Enabled |

All of these are bundled with Discourse core. Toggle them via `discourse.plugins` in your values file or via `PLUGIN_ENABLE_*` environment variables.

## Troubleshooting

**Pod stuck in CrashLoopBackOff on first boot**

First boot runs database migrations which can take 5-10 minutes. The startup probe is configured to wait up to ~10 minutes (`failureThreshold: 60 * periodSeconds: 10s`). Check logs to confirm migrations are running:

```bash
kubectl logs -f deploy/discourse -c discourse -n discourse
```

**PostgreSQL connection refused**

The init container waits for PostgreSQL to be reachable before starting Discourse. Verify your `discourse.database.host` and `discourse.database.port` values. Ensure the `hstore` and `pg_trgm` extensions are installed.

**Assets not loading / blank page**

If you see unstyled HTML, assets were not precompiled. The pre-built image from GHCR has assets baked in. If you built your own image, verify the `rake assets:precompile` step completed successfully during the build. Do NOT set `discourse.enablePrecompileAssets: true` in production -- it adds 5-15 minutes to every pod startup.

**Redis connection errors in logs**

Redis runs as a sidecar in the same pod on `localhost:6379`. If you see connection errors, check that the Redis container is running:

```bash
kubectl get pods -n discourse -o wide
kubectl logs deploy/discourse -c redis -n discourse
```

**Admin account not created**

Set both `discourse.developerEmails` and `discourse.admin.email` (with a matching email) for first-boot admin creation. The admin is only created on the very first startup with an empty database.

**Security context errors / s6-overlay crash**

The Discourse container starts as root for s6-overlay init, then drops to uid 9009. Do not set `runAsNonRoot: true` or drop ALL capabilities in `securityContext` -- it will break the init process.

## References

- [Nfrastack container-discourse](https://github.com/nfrastack/container-discourse) -- Base image source
- [Discourse environment variables](https://github.com/discourse/discourse/blob/main/config/discourse_defaults.conf) -- Canonical configuration reference
- [Discourse](https://www.discourse.org) -- Discourse project home

## License

MIT
