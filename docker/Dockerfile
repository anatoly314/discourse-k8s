# =============================================================================
# Custom Discourse image for Kubernetes deployment
# =============================================================================
#
# Extends the Nfrastack base image to:
#   1. Enable bundled plugins at build time (via symlinks)
#   2. Precompile assets so pods start in seconds, not 5-15 minutes
#
# Build:
#   docker build -t discourse-custom:dev .
#   docker build --build-arg BASE_IMAGE=ghcr.io/nfrastack/container-discourse:latest \
#                -t discourse-custom:dev .
#
# Why this file exists:
#   Discourse plugins contribute JS/CSS to the compiled asset bundle. If plugins
#   aren't present when `rake assets:precompile` runs, they're invisible to the
#   frontend. The Nfrastack base image ships all bundled Discourse plugins under
#   /container/data/discourse/plugins/ but doesn't precompile assets. We point
#   /app/plugins at that directory and precompile so the image is ready to serve.
#
# Plugin loading:
#   Discourse scans /app/plugins/*/plugin.rb (one directory, alphabetical order).
#   The base image stores all bundled plugins at /container/data/discourse/plugins/.
#   We replace /app/plugins with a symlink to that directory so Discourse sees
#   ALL bundled plugins during precompilation. This also preserves the correct
#   alphabetical load order from Discourse core (important: automation must load
#   before discourse-assign because assign depends on automation's methods).
#
#   At runtime, Nfrastack's bootstrap replaces /app/plugins with a symlink to
#   /data/plugins/, and plugin-tool sync creates per-plugin symlinks there
#   based on PLUGIN_ENABLE_* env vars. Our build-time symlink is throwaway.
# =============================================================================

ARG BASE_IMAGE=ghcr.io/nfrastack/container-discourse:latest

FROM ${BASE_IMAGE}

# Re-declare ARGs after FROM so they're available for labels and RUN commands.
# ARG values don't survive across FROM boundaries in multi-stage builds.
ARG BASE_IMAGE
ARG DISCOURSE_VERSION=v2026.2.1

LABEL org.opencontainers.image.title="Discourse (AnkiMCP)" \
      org.opencontainers.image.description="Discourse forum with plugins pre-enabled and assets precompiled for Kubernetes" \
      org.opencontainers.image.version="${DISCOURSE_VERSION}" \
      org.opencontainers.image.source="https://github.com/anatoly314/discourse-k8s" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.licenses="MIT"

# -----------------------------------------------------------------------------
# Make all bundled plugins visible for asset precompilation
# -----------------------------------------------------------------------------
# Replace /app/plugins with a direct symlink to the bundled plugins directory.
# This avoids double-loading (only one physical path) and preserves the correct
# alphabetical load order from Discourse core:
#   automation < discourse-assign  (assign depends on automation's methods)
#
# All bundled plugins will be compiled. At runtime, plugin-tool sync selectively
# enables/disables plugins via PLUGIN_ENABLE_* env vars — the build-time
# symlink is replaced by Nfrastack's bootstrap process.
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -rf /app/plugins; \
    ln -s /container/data/discourse/plugins /app/plugins; \
    echo "=== Plugins visible for precompilation ==="; \
    ls -la /app/plugins/

# -----------------------------------------------------------------------------
# Stage 2: Precompile assets
# -----------------------------------------------------------------------------
# This is the expensive step (~5-15 min) that we pay once at build time instead
# of on every pod startup.
#
# Key env vars:
#   RAILS_ENV=production        - Required for production asset compilation
#   SKIP_DB_AND_REDIS=1         - Tells Discourse to skip DB/Redis connections.
#                                 CSS theme compilation needs DB so it's skipped;
#                                 JS/Ember compiles fine without it. Theme CSS
#                                 gets compiled lazily at runtime on first request.
#   SECRET_KEY_BASE             - Rails refuses to boot in production mode without
#                                 one. We use a throwaway value that never leaves
#                                 the build layer. The real secret is injected at
#                                 runtime via DISCOURSE_SECRET_KEY_BASE.
# -----------------------------------------------------------------------------
RUN set -eux; \
    \
    export RAILS_ENV=production; \
    export SKIP_DB_AND_REDIS=1; \
    export SECRET_KEY_BASE="precompile_placeholder_$(openssl rand -hex 32)"; \
    export DISCOURSE_SECRET_KEY_BASE="${SECRET_KEY_BASE}"; \
    \
    # Git safe.directory is needed because /app is owned by discourse (UID 9009)
    # but we're running as root during build. Discourse's asset pipeline shells
    # out to git for version info.
    git config --global --add safe.directory /app; \
    \
    cd /app && bundle exec rake assets:precompile; \
    \
    # Ensure the discourse user owns compiled assets and tmp files
    chown -R discourse:discourse /app/public/assets /app/tmp

# -----------------------------------------------------------------------------
# Runtime configuration defaults
# -----------------------------------------------------------------------------
# ENABLE_PRECOMPILE_ASSETS=FALSE  - Assets are already compiled in this image.
#                                   Skips the 5-15 min startup delay.
# ENABLE_DB_MIGRATE=TRUE          - Run migrations on every deploy. Safe because
#                                   Rails migrations are idempotent.
# SERVE_STATIC_ASSETS=TRUE        - No nginx in front; Unicorn serves everything.
#                                   Ingress controller handles TLS termination.
# PLUGIN_PRIORITY=image            - Prefer image-bundled plugins over any found
#                                   in the host-mounted /data/plugins/ volume.
#                                   Ensures reproducible builds.
# PLUGIN_ENABLE_*                 - Tell plugin-tool sync which plugins to enable
#                                   at container startup. These match the symlinks
#                                   we created above, but plugin-tool recreates
#                                   them from scratch on init.
ENV ENABLE_PRECOMPILE_ASSETS="FALSE" \
    ENABLE_DB_MIGRATE="TRUE" \
    SERVE_STATIC_ASSETS="TRUE" \
    PLUGIN_ENABLE_OPENID_CONNECT="TRUE" \
    PLUGIN_ENABLE_TOPIC_VOTING="TRUE" \
    PLUGIN_ENABLE_CHAT="TRUE" \
    PLUGIN_ENABLE_SOLVED="TRUE" \
    PLUGIN_ENABLE_AI="TRUE" \
    PLUGIN_ENABLE_ASSIGN="TRUE" \
    PLUGIN_ENABLE_AUTOMATION="TRUE" \
    PLUGIN_ENABLE_POLL="TRUE" \
    PLUGIN_ENABLE_CHECKLIST="TRUE" \
    PLUGIN_ENABLE_DETAILS="TRUE" \
    PLUGIN_ENABLE_NARRATIVE_BOT="TRUE" \
    PLUGIN_ENABLE_PRESENCE="TRUE" \
    PLUGIN_ENABLE_REACTIONS="TRUE" \
    PLUGIN_ENABLE_STYLEGUIDE="TRUE" \
    PLUGIN_PRIORITY="image"

EXPOSE 3000
