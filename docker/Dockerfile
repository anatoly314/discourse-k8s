# syntax=docker/dockerfile:1
# =============================================================================
# Discourse for Kubernetes
# =============================================================================
#
# A clean, single-purpose image for running Discourse on Kubernetes.
# Uses discourse/base:slim as the foundation (Ruby, Node, pnpm, ImageMagick,
# pg_client — everything needed to run a Rails app, without bundled PG/Redis).
#
# The same image serves three roles via different CMD/entrypoint overrides:
#   - Web server:  bundle exec pitchfork -E production -c config/pitchfork.conf.rb
#   - Sidekiq:     bundle exec sidekiq
#   - Migrations:  bundle exec rake db:migrate
#
# Build:
#   docker build -t discourse:latest .
#   docker build --build-arg DISCOURSE_VERSION=v2026.3.0-latest -t discourse:v2026.3.0 .
#
# =============================================================================

ARG BASE_IMAGE=discourse/base:slim

FROM ${BASE_IMAGE}

# Re-declare after FROM so they're available in RUN and LABEL instructions.
ARG BASE_IMAGE
ARG DISCOURSE_VERSION=v2026.3.0-latest

LABEL org.opencontainers.image.title="Discourse (AnkiMCP)" \
      org.opencontainers.image.description="Discourse forum with plugins and precompiled assets for Kubernetes" \
      org.opencontainers.image.version="${DISCOURSE_VERSION}" \
      org.opencontainers.image.source="https://github.com/anatoly314/discourse-k8s" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.licenses="GPL-2.0-only"

# =============================================================================
# Pin Discourse to the requested version
# =============================================================================
# The slim base image clones Discourse from the main branch into
# /var/www/discourse. We fetch the specific release tag and check it out.
# Using --filter=tree:0 (partial clone) means git fetch is lightweight.
# =============================================================================
WORKDIR /var/www/discourse

RUN sudo -u discourse git fetch --depth 1 origin tag "${DISCOURSE_VERSION}" && \
    sudo -u discourse git checkout "${DISCOURSE_VERSION}"

# =============================================================================
# Install Ruby gems
# =============================================================================
# Mirrors the web-only stage from discourse/discourse_docker.
# --deployment: uses exact Gemfile.lock versions, installs to vendor/bundle.
# --without test development: skip test/dev-only gems.
# =============================================================================
RUN sudo -u discourse bundle config --local deployment true && \
    sudo -u discourse bundle config --local path ./vendor/bundle && \
    sudo -u discourse bundle config --local without "test development" && \
    sudo -u discourse bundle install --jobs "$(( $(nproc) - 1 ))" && \
    find vendor/bundle -name cache -not -path '*/gems/*' -type d -exec rm -rf {} + 2>/dev/null; \
    find vendor/bundle -name tmp -type d -exec rm -rf {} + 2>/dev/null; \
    true

# =============================================================================
# Install JavaScript dependencies
# =============================================================================
# Discourse migrated from yarn to pnpm. We handle both for forward compat.
# =============================================================================
RUN sudo -u discourse /bin/bash -c \
    'if [ -f yarn.lock ]; then yarn install --frozen-lockfile && yarn cache clean; else pnpm install --frozen-lockfile; fi'

# =============================================================================
# Plugins
# =============================================================================
# All plugins we need (openid-connect, topic-voting, solved, assign, ai,
# reactions, chat, automation, poll, etc.) ship in Discourse core under
# plugins/. No third-party plugin cloning needed.
#
# If you ever need a plugin that's NOT in core, add a git clone here:
#   RUN cd plugins && \
#       sudo -u discourse git clone --depth 1 https://github.com/org/plugin.git
#
# Plugins MUST be present before assets:precompile — they contribute JS/CSS
# to the compiled Ember bundle. They are enabled/disabled via the admin UI.
# =============================================================================

# =============================================================================
# Precompile assets
# =============================================================================
# This is the expensive step (~5-15 min) that we pay once at image build time
# instead of on every pod startup.
#
# SKIP_DB_AND_REDIS=1   — Discourse skips DB/Redis connections during compile.
#                         CSS theme compilation needs DB so it's deferred to
#                         runtime; JS/Ember compiles fine without it.
# SECRET_KEY_BASE       — Rails refuses to boot in production without one.
#                         This throwaway value never leaves the build layer.
#                         The real secret is injected at runtime via
#                         DISCOURSE_SECRET_KEY_BASE.
# DISCOURSE_MAXMIND_LICENSE_KEY — set to empty to skip MaxMind DB download
#                         during precompile (default behavior tries to fetch it).
# =============================================================================
RUN sudo -u discourse env \
    RAILS_ENV=production \
    SKIP_DB_AND_REDIS=1 \
    SECRET_KEY_BASE="precompile_placeholder_$(openssl rand -hex 32)" \
    DISCOURSE_MAXMIND_LICENSE_KEY="" \
    bundle exec rake assets:precompile

# =============================================================================
# Runtime environment defaults
# =============================================================================
# UNICORN_SIDEKIQS=0        — Do NOT spawn Sidekiq from the web server process.
#                             Sidekiq runs as a separate K8s container.
# UNICORN_BIND_ALL=true     — Listen on 0.0.0.0 instead of 127.0.0.1.
#                             Required inside a container/pod.
# UNICORN_WORKERS=3         — Sane default for ~1GB RAM pod. Override via Helm.
# DISCOURSE_SERVE_STATIC_ASSETS=true
#                           — No nginx in front; pitchfork serves assets directly.
# =============================================================================
ENV RAILS_ENV=production \
    UNICORN_SIDEKIQS=0 \
    UNICORN_BIND_ALL=true \
    UNICORN_WORKERS=3 \
    DISCOURSE_SERVE_STATIC_ASSETS=true

EXPOSE 3000

# Drop from root to the discourse user. Build steps above use sudo -u discourse
# for file operations; at runtime there's no reason to stay root.
USER discourse

# Default: run the web server (pitchfork, Discourse's unicorn successor).
# Override in K8s to run Sidekiq or one-off tasks.
#
# Discourse's bin/unicorn auto-delegates to bin/pitchfork unless RUN_PITCHFORK=0.
# We call pitchfork directly to be explicit.
CMD ["bundle", "exec", "pitchfork", "-E", "production", "-c", "config/pitchfork.conf.rb"]
