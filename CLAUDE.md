# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Custom Docker image + Helm chart for deploying Discourse on Kubernetes. Created because no well-maintained, free Helm chart exists for Discourse (Bitnami killed by Broadcom, everything else abandoned).

**Target environments:** AnkiMCP SaaS (prod, ArgoCD + CNPG + Keycloak + Brevo SMTP) and Homelab (test, k3s + ArgoCD).

## Architecture Decisions

### Why a custom Docker image?
Discourse plugins must be present before `assets:precompile` runs — they contribute JS and CSS to the compiled bundle. You can't install plugins at runtime. We extend the Nfrastack base image to bake in specific plugins.

### Why Nfrastack as base image?
The official `discourse/discourse` Docker Hub image is "experimental, not production-ready". Discourse's `discourse_docker` bundles PostgreSQL+Redis+Nginx into one fat container — unusable in K8s. Nfrastack (`ghcr.io/nfrastack/container-discourse`) is the only K8s-friendly image: slim, expects external PostgreSQL and Redis, has s6-overlay, runs Unicorn+Sidekiq internally, exposes port 3000.

### Container architecture
Single pod with 2 containers:
1. **discourse** (custom image based on Nfrastack) — Unicorn + Sidekiq via s6-overlay
2. **redis** (`redis:7-alpine`) — sidecar, ephemeral, no PVC. Used for Sidekiq queue, caching, MessageBus. NOT a data store.

### Why Redis as sidecar?
Target environment doesn't have Redis. A full Redis Deployment just for a forum is overkill. Sidecar shares localhost — no Service needed, Redis is ephemeral cache/queue only.

## Plugins

Bundled Discourse plugins to enable (ship with core, disabled by default):
- `discourse-openid-connect` — Keycloak SSO (OIDC)
- `discourse-voting` — Topic voting
- `discourse-chat` — Real-time chat
- `discourse-solved` — Mark accepted solutions
- `discourse-ai` — AI features (summarize, classify)
- `discourse-assign` — Assign topics to staff
- `discourse-automation` — Automated actions
- `discourse-polls` — Polls in posts

Some may only need admin UI toggle, not image-level installation. Third-party plugins definitely need image-level installation.

## Development Commands

### Docker image
```bash
# Build the custom image
docker build -t discourse-custom:dev docker/

# Build with specific base version
docker build --build-arg DISCOURSE_VERSION=v2026.2.1 -t discourse-custom:dev docker/
```

### Helm chart
```bash
# Lint the chart
helm lint chart/

# Template render (dry-run) with test values
helm template discourse chart/ -f chart/values.yaml

# Install locally (requires a K8s cluster)
helm install discourse chart/ -f my-values.yaml --namespace discourse --create-namespace

# Upgrade
helm upgrade discourse chart/ -f my-values.yaml --namespace discourse
```

## What NOT to Do

- Don't use the official `discourse/discourse` Docker Hub image — experimental, not production-ready
- Don't bundle PostgreSQL or Redis into the Discourse container — use external services
- Don't use Bitnami images — dead (Broadcom killed free updates Aug 2025)
- Don't install plugins at runtime — bake them into the Docker image before `assets:precompile`
- Don't use `ENABLE_PRECOMPILE_ASSETS=TRUE` in production — precompile during image build

## Reference Documentation

Detailed specs are in `.docs/`:
- [`.docs/specifications.md`](.docs/specifications.md) — env vars, health checks, storage paths, startup sequence
- [`.docs/integration.md`](.docs/integration.md) — ArgoCD, secrets management, Jenkins pipeline

## Key References

- [Nfrastack container-discourse](https://github.com/nfrastack/container-discourse) — base image source
- [Discourse discourse_defaults.conf](https://github.com/discourse/discourse/blob/main/config/discourse_defaults.conf) — canonical env var list
- [Bitnami Discourse chart source](https://github.com/bitnami/charts/tree/main/bitnami/discourse) — reference for Helm patterns (Apache 2.0)
