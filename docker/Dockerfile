# syntax=docker/dockerfile:1
# =============================================================================
# Custom Discourse image for Kubernetes deployment
# =============================================================================
#
# Extends the Nfrastack base image to:
#   1. Copy bundled plugins into /app/plugins at build time
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
#   /container/data/discourse/plugins/ but doesn't precompile assets. We hard-copy
#   them into /app/plugins and precompile so the image is ready to serve.
#
# Why hard-copy instead of symlink:
#   Symlinking /app/plugins -> /container/data/discourse/plugins/ causes Ruby to
#   double-load every plugin file due to a symlink/realpath mismatch. Several
#   Discourse plugins (automation, chat, reactions, etc.) use Rails::Engine
#   subclasses. When the engine file is loaded via require_relative from a
#   symlink path, __dir__ inside the engine resolves to the real (target) path,
#   not the symlink path. The engine then registers autoload_paths using the
#   real path, while $LOADED_FEATURES already has entries under the symlink
#   path. Ruby treats these as different files and loads everything twice,
#   causing "already initialized constant" warnings and fatal errors (duplicate
#   enum definitions, duplicate callbacks, etc.).
#
#   Hard-copying eliminates this: a single physical path means no mismatch.
#
# Plugin loading at runtime:
#   Discourse scans /app/plugins/*/plugin.rb (one directory, alphabetical order).
#   At runtime, Nfrastack's bootstrap replaces /app/plugins and plugin-tool sync
#   creates per-plugin symlinks from /app/plugins/<name> pointing to the source
#   in /container/data/discourse/plugins/<name>, based on PLUGIN_ENABLE_* env
#   vars. Per-plugin symlinks work fine because the symlink boundary is at the
#   plugin directory level -- Dir[] and __dir__ stay consistent within each
#   plugin's file tree.
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
# Hard-copy bundled plugins from the Nfrastack staging area into /app/plugins.
# We MUST NOT symlink here -- see the header comment for the full explanation
# of the symlink/realpath double-loading bug.
#
# cp -a preserves symlinks, permissions, and timestamps within each plugin
# directory. The alphabetical load order is preserved (automation loads before
# discourse-assign, which depends on automation's methods).
#
# At runtime, plugin-tool sync replaces these copies with per-plugin symlinks
# based on PLUGIN_ENABLE_* env vars, so these build-time copies are throwaway.
# -----------------------------------------------------------------------------
RUN set -eux; \
    rm -rf /app/plugins; \
    mkdir -p /app/plugins; \
    cp -a /container/data/discourse/plugins/. /app/plugins/; \
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
# Fix plugin load order at runtime
# -----------------------------------------------------------------------------
# Nfrastack's plugin-tool normalizes names by stripping the "discourse-" prefix,
# creating symlinks like /app/plugins/assign. Discourse loads plugins
# alphabetically, so "assign" loads before "automation" — but assign depends
# on automation's add_automation_scriptable method, causing a crash.
#
# Fix: override PLUGIN_TOOL_COMMAND with a wrapper that runs plugin-tool sync
# and then renames affected symlinks to preserve the correct load order.
# "discourse-assign" sorts after "automation" alphabetically.
# -----------------------------------------------------------------------------
COPY <<'SCRIPT' /usr/local/bin/plugin-tool-wrapper
#!/bin/sh
set -e
plugin-tool sync "$@"
PLUGIN_ENABLED_PATH="${PLUGIN_ENABLED_PATH:-/app/plugins}"
if [ -L "${PLUGIN_ENABLED_PATH}/assign" ]; then
    mv "${PLUGIN_ENABLED_PATH}/assign" "${PLUGIN_ENABLED_PATH}/discourse-assign"
    echo "[plugin-tool-wrapper] Renamed assign -> discourse-assign (load order fix)"
fi
SCRIPT
RUN chmod +x /usr/local/bin/plugin-tool-wrapper

# -----------------------------------------------------------------------------
# Runtime configuration defaults
# -----------------------------------------------------------------------------
# PLUGIN_TOOL_COMMAND              - Override to use our wrapper that fixes
#                                   plugin load order after plugin-tool sync.
# ENABLE_PRECOMPILE_ASSETS=FALSE  - Assets are already compiled in this image.
# ENABLE_DB_MIGRATE=TRUE          - Run migrations on every deploy.
# SERVE_STATIC_ASSETS=TRUE        - No nginx in front; Unicorn serves directly.
# PLUGIN_PRIORITY=image            - Prefer image-bundled plugin versions.
# PLUGIN_ENABLE_*                 - Tell plugin-tool sync which plugins to enable.
ENV PLUGIN_TOOL_COMMAND="plugin-tool-wrapper" \
    ENABLE_PRECOMPILE_ASSETS="FALSE" \
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
