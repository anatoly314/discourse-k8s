# discourse-k8s

Custom Docker image and Helm chart for deploying [Discourse](https://www.discourse.org) on Kubernetes.

Created because no well-maintained, free Helm chart exists for Discourse. Bitnami's chart was killed when Broadcom ended free updates (August 2025), and every other option is abandoned. This project provides a working, opinionated setup built on top of `discourse/base:slim` -- the official Discourse base image with all system dependencies (Ruby, Node, pnpm, ImageMagick, PostgreSQL client) but without bundled PostgreSQL or Redis.

## Architecture

```
+------------------------------------------------------------------+
|  Pod                                                             |
|                                                                  |
|  initContainers (sequential after redis sidecar starts):         |
|  +--------------------+    +--------------------+                |
|  | wait-for-postgres  |--->|      migrate       |                |
|  |  (busybox:nc)      |    | rake db:migrate    |                |
|  +--------------------+    +--------------------+                |
|                                                                  |
|  containers:                                                     |
|  +--------------------+  +--------------------+  +-----------+   |
|  |       web          |  |     sidekiq        |  |   redis   |   |
|  |                    |  |                    |  |  (native  |   |
|  |  pitchfork :3000   |  |  background jobs   |  |  sidecar) |   |
|  |  (web server)      |  |  (job processor)   |  |  :6379    |   |
|  +--------------------+  +--------------------+  +-----------+   |
|          |                        |                   ^           |
|          +------------------------+-------------------+           |
|          |                                                       |
+----------|-------------------------------------------------------+
           |
    +------v-------+
    |  PostgreSQL   |     (external, e.g. CNPG)
    |  pg_trgm      |
    |  unaccent      |
    +--------------+
```

The pod runs three containers from two images:

- **web** -- Pitchfork web server (Discourse's unicorn successor) on port 3000. Serves the Rails application and static assets.
- **sidekiq** -- Background job processor. Handles email, notifications, indexing, and other async work. Same Discourse image, different command.
- **redis** -- `redis:7-alpine` native sidecar (K8s 1.28+). Ephemeral (emptyDir, no PVC). Used for Sidekiq job queue, caching, and MessageBus real-time delivery. Not a data store -- PostgreSQL is the source of truth.

### Init container sequence

1. **redis** (native sidecar) -- Starts first with `restartPolicy: Always`, which makes it a sidecar init container that keeps running alongside regular containers. This is a Kubernetes 1.28+ feature.
2. **wait-for-postgres** -- Polls the PostgreSQL host with `nc` until it responds.
3. **migrate** -- Runs `bundle exec rake db:migrate`. Migrations acquire a distributed mutex via Redis to prevent concurrent runs, which is why Redis must be running before this step.

### Why Redis as a native sidecar?

Discourse's `db:migrate` acquires a distributed lock through Redis, so Redis must be available before migrations run. A regular sidecar container (in `containers:`) starts in parallel with other containers -- there is no ordering guarantee. A native sidecar init container (init container with `restartPolicy: Always`) starts before the subsequent init containers and regular containers, guaranteeing Redis is up when the migrate init container runs.

Redis as a sidecar rather than a separate Deployment keeps things simple -- it is purely ephemeral cache/queue, shares localhost with the pod, and does not need its own Service or PVC.

### Why a custom Docker image?

Discourse plugins contribute JavaScript and CSS to the compiled asset bundle. They must be present when `rake assets:precompile` runs -- you cannot install them at runtime. The custom image pins a Discourse release tag, installs gems and JS dependencies, and precompiles assets so pods start in seconds instead of 5-15 minutes.

## Prerequisites

- **Kubernetes 1.28+** -- Required for native sidecar support (`restartPolicy: Always` on init containers)
- **External PostgreSQL** with `pg_trgm` and `unaccent` extensions (auto-created by `db:migrate`, but the user must have permission)
- **Helm 3**
- **Docker** (only if building the custom image yourself)

## Quick Start

### 1. Get the Docker image

**Option A: Use the pre-built image from GHCR**

```
ghcr.io/anatoly314/discourse-k8s:v0.3.0
```

**Option B: Build your own**

```bash
docker build -t my-registry/discourse:v2026.3.0 docker/
```

### 2. Prepare PostgreSQL

Create a database with the required extensions:

```sql
CREATE DATABASE discourse;
\c discourse
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
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
  tag: v0.3.0

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
  --version 0.3.0 \
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

First startup takes a few minutes while database migrations run. Monitor progress:

```bash
# Watch the migrate init container
kubectl logs -f deploy/discourse -c migrate -n discourse

# Once migrations complete, watch the web server
kubectl logs -f deploy/discourse -c web -n discourse
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
| `image.repository` | Discourse container image repository (required) | `""` |
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
| `discourse.serveStaticAssets` | Serve static assets directly from Pitchfork (no nginx in front) | `true` |
| `discourse.forceHttps` | Force HTTPS (maps to DISCOURSE_FORCE_HTTPS) | `true` |
| `discourse.unicornWorkers` | Number of Pitchfork worker processes | `3` |
| `discourse.sidekiqConcurrency` | Sidekiq concurrency (number of threads processing background jobs) | `5` |
| `discourse.extraEnv` | Array of extra environment variables for all Discourse containers (web, sidekiq, migrate) | `[]` |

> **Note:** Every secret field (database, smtp, secretKeyBase, admin) supports two patterns -- an inline `password`/`value` for simple setups, or `existingSecret` + `secretKey` to reference a pre-existing Kubernetes Secret (for Vault, ESO, or similar operators).

### Sidekiq container parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `sidekiq.resources.requests.memory` | Sidekiq container memory request | `512Mi` |
| `sidekiq.resources.requests.cpu` | Sidekiq container CPU request | `250m` |
| `sidekiq.resources.limits.memory` | Sidekiq container memory limit | `1Gi` |

### Init container parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `initContainers.waitForPostgres.enabled` | Enable init container that waits for PostgreSQL to be reachable | `true` |
| `initContainers.waitForPostgres.image.repository` | Wait-for-postgres init container image repository | `busybox` |
| `initContainers.waitForPostgres.image.tag` | Wait-for-postgres init container image tag | `"1.37"` |
| `initContainers.waitForPostgres.image.pullPolicy` | Wait-for-postgres init container image pull policy | `IfNotPresent` |

### Persistence parameters

| Name | Description | Value |
| ---- | ----------- | ----- |
| `persistence.uploads.enabled` | Enable persistent storage for user uploads, avatars, and attachments | `true` |
| `persistence.uploads.size` | Size of the uploads PVC | `10Gi` |
| `persistence.uploads.storageClass` | Storage class for the uploads PVC (empty string uses cluster default) | `""` |
| `persistence.uploads.accessModes` | Access modes for the uploads PVC | `["ReadWriteOnce"]` |
| `persistence.uploads.existingClaim` | Name of an existing PVC to use for uploads | `""` |
| `persistence.uploads.mountPath` | Mount path for uploads inside the container | `/var/www/discourse/public/uploads` |
| `persistence.backups.enabled` | Enable persistent storage for Discourse backup archives | `false` |
| `persistence.backups.size` | Size of the backups PVC | `10Gi` |
| `persistence.backups.storageClass` | Storage class for the backups PVC (empty string uses cluster default) | `""` |
| `persistence.backups.accessModes` | Access modes for the backups PVC | `["ReadWriteOnce"]` |
| `persistence.backups.existingClaim` | Name of an existing PVC to use for backups | `""` |
| `persistence.backups.mountPath` | Mount path for backups inside the container | `/var/www/discourse/public/backups` |

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
| `resources.requests.memory` | Web (Pitchfork) container memory request | `1Gi` |
| `resources.requests.cpu` | Web (Pitchfork) container CPU request | `500m` |
| `resources.limits.memory` | Web (Pitchfork) container memory limit | `2Gi` |

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
| `securityContext` | Security context for the web and sidekiq containers | `{}` |
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

## Plugins and Site Settings

All plugins used in this chart ship with Discourse core -- no third-party plugins need to be cloned into the image. Plugins are enabled or disabled via Discourse site settings, which can be controlled in two ways: through the admin UI, or through environment variables.

### Setting site settings via environment variables

Discourse supports a feature called "shadowed settings" -- any site setting can be overridden by an environment variable following the convention `DISCOURSE_<UPPERCASE_SETTING_NAME>`. When set via env var, the setting is **locked at boot time and hidden from the admin UI**. This is intentional and useful for GitOps workflows where you want configuration to be declarative and immutable.

### Plugin enable/disable env vars

| Plugin | Env Var | Default |
|--------|---------|---------|
| Chat | `DISCOURSE_CHAT_ENABLED` | `true` |
| Solved | `DISCOURSE_SOLVED_ENABLED` | `true` |
| Assign | `DISCOURSE_ASSIGN_ENABLED` | `false` |
| OIDC | `DISCOURSE_OPENID_CONNECT_ENABLED` | `false` |
| Topic Voting | `DISCOURSE_TOPIC_VOTING_ENABLED` | `true` |
| AI | `DISCOURSE_DISCOURSE_AI_ENABLED` | `false` |
| Automation | `DISCOURSE_DISCOURSE_AUTOMATION_ENABLED` | `false` |
| Reactions | `DISCOURSE_DISCOURSE_REACTIONS_ENABLED` | `false` |
| Poll | `DISCOURSE_POLL_ENABLED` | `true` |

Use `discourse.extraEnv` in your values file to set these:

```yaml
discourse:
  extraEnv:
    - name: DISCOURSE_CHAT_ENABLED
      value: "true"
    - name: DISCOURSE_ASSIGN_ENABLED
      value: "true"
```

### Why the double DISCOURSE_ prefix?

Some plugins namespace their settings internally with a `discourse_` prefix. For example, the AI plugin registers its enabled setting as `discourse_ai_enabled`. When you apply the `DISCOURSE_` env var convention on top of that, you get `DISCOURSE_DISCOURSE_AI_ENABLED`. This affects the AI, Automation, and Reactions plugins.

### OIDC configuration via extraEnv

OpenID Connect (and other complex plugin settings) can also be configured entirely through environment variables. This is useful for Keycloak, Auth0, or any OIDC provider:

```yaml
discourse:
  extraEnv:
    - name: DISCOURSE_OPENID_CONNECT_ENABLED
      value: "true"
    - name: DISCOURSE_OPENID_CONNECT_DISCOVERY_DOCUMENT
      value: "https://keycloak.example.com/realms/myrealm/.well-known/openid-configuration"
    - name: DISCOURSE_OPENID_CONNECT_CLIENT_ID
      value: "discourse"
    - name: DISCOURSE_OPENID_CONNECT_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: discourse-oidc
          key: client-secret
```

### Admin UI alternative

If you prefer manual control, skip the env vars entirely and toggle plugins through the Discourse admin UI at `/admin/site_settings`. Settings configured in the admin UI are stored in the database and can be changed at any time without redeploying.

## Building the Custom Image

The [`docker/Dockerfile`](docker/Dockerfile) builds a production-ready Discourse image in five steps:

1. **Starts from `discourse/base:slim`** -- Official Discourse base image with Ruby, Node, pnpm, ImageMagick, and PostgreSQL client. No bundled database or Redis.
2. **Pins the Discourse release** -- Checks out the exact release tag (e.g. `v2026.3.0-latest`) from the Discourse repo already cloned in the base image.
3. **Installs Ruby gems** -- `bundle install --deployment` with exact Gemfile.lock versions.
4. **Installs JavaScript dependencies** -- `pnpm install --frozen-lockfile` (or yarn, for forward compat).
5. **Precompiles assets** -- `bundle exec rake assets:precompile` with `SKIP_DB_AND_REDIS=1` so no live database is needed during the build.

The image defaults to running **Pitchfork** (Discourse's unicorn successor) as the web server. The same image is used for the sidekiq container and the migrate init container with different commands.

### Build arguments

| Arg | Default | Description |
|-----|---------|-------------|
| `BASE_IMAGE` | `discourse/base:slim` | Base image providing Ruby, Node, and system dependencies |
| `DISCOURSE_VERSION` | `v2026.3.0-latest` | Discourse release tag to check out and build |

### Build examples

```bash
# Default build
docker build -t my-discourse:latest docker/

# Pin a specific Discourse version
docker build \
  --build-arg DISCOURSE_VERSION=v2026.3.0-latest \
  -t my-discourse:v2026.3.0 docker/
```

### Adding third-party plugins

All bundled Discourse plugins (chat, solved, assign, AI, etc.) are already present in the source tree under `plugins/`. To add a third-party plugin not included in Discourse core, clone it before the asset precompilation step by adding a `RUN` instruction to the Dockerfile:

```dockerfile
# Add before the "Precompile assets" step
RUN cd plugins && \
    sudo -u discourse git clone --depth 1 https://github.com/org/discourse-my-plugin.git
```

Plugins must be present before `assets:precompile` because they contribute JavaScript and CSS to the compiled Ember bundle.

## Docker Image Environment Variables

These environment variables are set in the Dockerfile as runtime defaults:

| Name | Description | Value |
| ---- | ----------- | ----- |
| `RAILS_ENV` | Rails environment | `production` |
| `UNICORN_SIDEKIQS` | Number of Sidekiq processes to spawn from the web server (set to 0 because Sidekiq runs as a separate container) | `0` |
| `UNICORN_BIND_ALL` | Listen on 0.0.0.0 instead of 127.0.0.1 (required inside a container) | `true` |
| `UNICORN_WORKERS` | Number of Pitchfork worker processes | `3` |
| `DISCOURSE_SERVE_STATIC_ASSETS` | Serve static assets directly from Pitchfork (no nginx in front) | `true` |

### Build arguments

| Name | Description | Default Value |
| ---- | ----------- | ------------- |
| `BASE_IMAGE` | Base image used as the build foundation | `discourse/base:slim` |
| `DISCOURSE_VERSION` | Discourse release tag to check out from the repository | `v2026.3.0-latest` |

## CI/CD

Both the Docker image and Helm chart are built and published by GitHub Actions, triggered by tags.

### Docker image

- **Trigger:** Push a tag matching `docker/v*` (e.g. `docker/v0.3.0`)
- **Registry:** `ghcr.io/anatoly314/discourse-k8s`
- **Tags produced:** Version tag + `latest`
- **Workflow:** [`.github/workflows/docker.yml`](.github/workflows/docker.yml)

```bash
git tag docker/v0.3.0
git push origin docker/v0.3.0
```

Note: The `DISCOURSE_VERSION` (the Discourse release being built) is pinned in the Dockerfile itself, not passed from CI. The `docker/v*` tag versions the image, not Discourse. To build a different Discourse release, update the `DISCOURSE_VERSION` ARG in the Dockerfile.

### Helm chart

- **Trigger:** Push a tag matching `chart/v*` (e.g. `chart/v0.2.0`)
- **Registry:** `oci://ghcr.io/anatoly314/helm-charts`
- **Workflow:** [`.github/workflows/helm.yml`](.github/workflows/helm.yml)

```bash
git tag chart/v0.2.0
git push origin chart/v0.2.0
```

### Consuming the chart from GHCR

```bash
# Pull and inspect
helm pull oci://ghcr.io/anatoly314/helm-charts/discourse --version 0.2.0

# Install directly
helm install discourse oci://ghcr.io/anatoly314/helm-charts/discourse \
  --version 0.2.0 -f my-values.yaml -n discourse --create-namespace
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
      targetRevision: 0.2.0
      helm:
        valueFiles:
          - $values/apps/discourse/values.yaml
```

## Included Plugins

| Plugin | Description |
|--------|-------------|
| `discourse-openid-connect` | OIDC SSO (Keycloak, Auth0, etc.) |
| `discourse-topic-voting` | Category-level feature voting |
| `discourse-chat` | Real-time chat channels, DMs, threads |
| `discourse-solved` | Mark replies as accepted solutions |
| `discourse-ai` | AI-powered features (summarize, classify) |
| `discourse-assign` | Assign topics/posts to staff |
| `discourse-automation` | Automate actions via triggers |
| `discourse-poll` | Polls in posts |
| `discourse-reactions` | Post reactions beyond simple likes |
| `discourse-checklist` | Checkbox lists in posts |
| `discourse-details` | Collapsible detail/summary blocks |
| `discourse-narrative-bot` | New user tutorial bot |
| `discourse-presence` | "User is typing" indicators |
| `discourse-styleguide` | Admin style guide for theming |

All of these ship with Discourse core under the `plugins/` directory. They do not need to be cloned or installed -- they are already present in the source tree. Enable or disable them via environment variables (see [Plugins and Site Settings](#plugins-and-site-settings)) or through the admin UI.

## Troubleshooting

**Pod stuck in CrashLoopBackOff on first boot**

First boot runs database migrations in the `migrate` init container, which can take a few minutes. Check the init container logs:

```bash
kubectl logs -f deploy/discourse -c migrate -n discourse
```

If migrations completed but the web container is slow to start, the startup probe allows up to ~10 minutes (`failureThreshold: 60 * periodSeconds: 10s`):

```bash
kubectl logs -f deploy/discourse -c web -n discourse
```

**PostgreSQL connection refused**

The `wait-for-postgres` init container polls PostgreSQL before migrations run. Verify your `discourse.database.host` and `discourse.database.port` values. Ensure the database exists and the user has permission to create extensions (`pg_trgm`, `unaccent`).

**Assets not loading / blank page**

If you see unstyled HTML, assets were not precompiled. The pre-built image from GHCR has assets baked in. If you built your own image, verify the `rake assets:precompile` step completed successfully during the Docker build.

**Redis connection errors in logs**

Redis runs as a native sidecar init container at `localhost:6379`. If you see connection errors, check that the Redis container is running:

```bash
kubectl get pods -n discourse -o wide
kubectl logs deploy/discourse -c redis -n discourse
```

**Admin account not created**

Set both `discourse.developerEmails` and `discourse.admin.email` (with a matching email) for first-boot admin creation. The admin is only created on the very first startup with an empty database.

**Kubernetes version too old for native sidecar**

The Redis container uses `restartPolicy: Always` on an init container, which is a native sidecar feature requiring Kubernetes 1.28 or later. On older clusters, the pod will fail to schedule. Upgrade your cluster or refactor the deployment to use a regular sidecar container (but note that this breaks the migration ordering guarantee).

**Sidekiq not processing jobs**

Check the sidekiq container logs and verify it started with the correct queues:

```bash
kubectl logs deploy/discourse -c sidekiq -n discourse
```

The chart passes all four Discourse queues (`critical`, `default`, `low`, `ultra_low`) explicitly. Without these flags, standalone Sidekiq only processes the `default` queue.

## References

- [discourse/base Docker Hub](https://hub.docker.com/r/discourse/base) -- Base image source
- [Discourse environment variables](https://github.com/discourse/discourse/blob/main/config/discourse_defaults.conf) -- Canonical configuration reference
- [Discourse](https://www.discourse.org) -- Discourse project home

## License

MIT
