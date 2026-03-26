# Technical Specifications

Detailed reference for Discourse deployment configuration. See CLAUDE.md for architecture decisions and constraints.

## Base Image

- **Image:** `ghcr.io/nfrastack/container-discourse` (also `docker.io/nfrastack/discourse`)
- **Discourse version:** pinned releases (e.g., `v2026.2.1`)
- **OS:** Debian bookworm or Alpine (configurable)
- **Web server:** Unicorn on port 3000
- **Process supervisor:** s6-overlay (manages Unicorn + Sidekiq)
- **Plugin tool:** `/usr/local/bin/plugin-tool` for plugin management

## Environment Variables

### Database (external CNPG PostgreSQL)
```
DISCOURSE_DB_HOST          # e.g., pg-shared-rw.postgres.svc.cluster.local
DISCOURSE_DB_PORT          # default: 5432
DISCOURSE_DB_NAME          # e.g., discourse
DISCOURSE_DB_USERNAME      # e.g., discourse
DISCOURSE_DB_PASSWORD      # from Vault secret
DISCOURSE_DB_POOL          # default: 8
```

PostgreSQL requires extensions: `hstore`, `pg_trgm`. Optionally `pgvector`.

### Redis (sidecar at localhost)
```
DISCOURSE_REDIS_HOST       # "localhost" (sidecar)
DISCOURSE_REDIS_PORT       # default: 6379
DISCOURSE_REDIS_DB         # default: 0
```

### Site Identity
```
DISCOURSE_HOSTNAME         # e.g., forum.ankimcp.ai
DISCOURSE_DEVELOPER_EMAILS # comma-separated, grants initial admin access
DISCOURSE_SECRET_KEY_BASE  # 128-char hex: openssl rand -hex 64
```

### SMTP (Brevo)
```
DISCOURSE_SMTP_ADDRESS
DISCOURSE_SMTP_PORT
DISCOURSE_SMTP_DOMAIN
DISCOURSE_SMTP_USER_NAME
DISCOURSE_SMTP_PASSWORD    # from Vault secret
DISCOURSE_SMTP_AUTHENTICATION    # default: plain
DISCOURSE_SMTP_ENABLE_START_TLS  # default: true
```

### Keycloak OIDC (configured via admin UI after first boot, but can be seeded)
```
# These are Discourse site settings, not env vars. Set via API or admin UI:
# openid_connect_enabled: true
# openid_connect_discovery_document: https://keycloak.example.com/realms/ankimcp/.well-known/openid-configuration
# openid_connect_client_id: discourse
# openid_connect_client_secret: <from Vault>
```

### Serving
```
DISCOURSE_SERVE_STATIC_ASSETS  # "true" -- no nginx in front
RAILS_LOG_TO_STDOUT            # "1" -- for kubectl logs
```

### Nfrastack-specific (alternative naming, maps to DISCOURSE_* internally)
```
DB_HOST, DB_NAME, DB_USER, DB_PASS, DB_PORT
REDIS_HOST, REDIS_PORT
SITE_HOSTNAME
SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS
SERVE_STATIC_ASSETS        # "TRUE"
UNICORN_WORKERS            # default: 8
SIDEKIQ_THREADS            # default: 25
ENABLE_DB_MIGRATE          # "TRUE" -- run migrations on startup
ENABLE_PRECOMPILE_ASSETS   # "TRUE" -- precompile on startup (slow, better to bake in)
```

## Health Checks

```yaml
livenessProbe:
  httpGet:
    path: /srv/status    # returns "ok" (plain text, HTTP 200)
    port: 3000
  initialDelaySeconds: 120   # first boot can be slow (migrations + asset precompile)
  periodSeconds: 30
readinessProbe:
  httpGet:
    path: /srv/status
    port: 3000
  initialDelaySeconds: 60
  periodSeconds: 10
```

`/srv/status` is a shallow check -- does NOT verify PostgreSQL or Redis connectivity.

## Persistent Storage

| Path | Purpose | Required | Notes |
|------|---------|----------|-------|
| `/data/uploads/` (Nfrastack) | User uploads, avatars, attachments | Yes | Symlinked to Rails public/uploads |
| `/data/backups/` | Database backup archives | Recommended | |
| `/data/plugins/` | Custom plugins (if not baked in) | Optional | |

### S3/MinIO upload offloading (optional)
```
DISCOURSE_S3_BUCKET
DISCOURSE_S3_REGION
DISCOURSE_S3_ACCESS_KEY_ID
DISCOURSE_S3_SECRET_ACCESS_KEY
DISCOURSE_S3_ENDPOINT          # for MinIO
```

## Startup Sequence

1. Wait for PostgreSQL to be reachable
2. Wait for Redis to be reachable
3. `bundle exec rake db:migrate` (run once per deploy -- Nfrastack does this if `ENABLE_DB_MIGRATE=TRUE`)
4. `bundle exec rake assets:precompile` (5-15 min on first run -- bake into image to avoid)
5. Create admin user (first boot only, via `DISCOURSE_DEVELOPER_EMAILS`)
6. Start Unicorn (port 3000)
7. Start Sidekiq (parallel with Unicorn after migrations)
