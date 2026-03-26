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

## Configuration Reference

All configuration is in [`chart/values.yaml`](chart/values.yaml). Below are the key sections -- see the file itself for inline comments and all available options.

### Required Values

| Value | Description |
|-------|-------------|
| `image.repository` | Your custom Discourse image (e.g. `ghcr.io/anatoly314/discourse-k8s`) |
| `discourse.hostname` | Public hostname for the forum |
| `discourse.database.host` | PostgreSQL host |

### Secrets

Every secret field supports two patterns:

**Inline (simple, not recommended for production):**

```yaml
discourse:
  database:
    password: "my-password"
```

**External Secret (for Vault, ESO, or any pre-existing Secret):**

```yaml
discourse:
  database:
    existingSecret: "my-vault-synced-secret"
    secretKey: db-password       # key within the Secret
```

The `existingSecret` pattern works for all four secrets: `database`, `smtp`, `secretKeyBase`, and `admin`.

### SMTP

```yaml
discourse:
  smtp:
    address: smtp.example.com
    port: 587
    domain: example.com
    username: "user"
    password: "pass"
    authentication: plain          # plain, login, or cram_md5
    enableStartTls: true
```

### Plugins

Plugins bundled in the Docker image can be toggled on or off. The keys map to `PLUGIN_ENABLE_<UPPER_NAME>` environment variables consumed by the Nfrastack plugin-tool:

```yaml
discourse:
  plugins:
    openid-connect: true
    chat: true
    solved: true
    ai: false
```

The default Docker image enables these plugins by default (see Dockerfile ENV block). You only need the `plugins` map in your values if you want to override the image defaults.

### Persistence

```yaml
persistence:
  uploads:
    enabled: true              # user uploads, avatars, attachments
    size: 10Gi
    storageClass: ""           # uses cluster default
    existingClaim: ""          # use a pre-existing PVC
  backups:
    enabled: false             # Discourse backup archives
    size: 10Gi
```

### Ingress

```yaml
ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - host: forum.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: forum-tls
      hosts:
        - forum.example.com
```

### Performance Tuning

```yaml
discourse:
  unicornWorkers: 4       # web server worker processes
  sidekiqThreads: 5       # background job concurrency

resources:
  requests:
    memory: 1Gi
    cpu: 500m
  limits:
    memory: 2Gi

redis:
  resources:
    requests:
      memory: 64Mi
      cpu: 50m
    limits:
      memory: 128Mi
```

### Extra Environment Variables

For any configuration not covered by named values:

```yaml
discourse:
  extraEnv:
    - name: TIMEZONE
      value: "UTC"
    - name: DISCOURSE_S3_BUCKET
      valueFrom:
        secretKeyRef:
          name: my-s3-secret
          key: bucket
```

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
