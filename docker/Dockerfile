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
ARG DISCOURSE_VERSION=v2026.9.0-latest

LABEL org.opencontainers.image.title="Discourse (AnkiMCP)" \
      org.opencontainers.image.description="Discourse forum with plugins and precompiled assets for Kubernetes" \
      org.opencontainers.image.version="${DISCOURSE_VERSION}" \
      org.opencontainers.image.source="https://github.com/anatoly-lab/discourse-k8s" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.licenses="GPL-2.0-only"

# =============================================================================
# Upgrade PostgreSQL client to match (or exceed) the server version
# =============================================================================
# discourse/base:slim ships pg_dump 15, but our CNPG cluster runs PG 18
# (server upgraded 17 -> 18 on 2026-05-11). pg_dump HARD-REFUSES to dump a
# server whose major version is newer than the client -- there is no override
# flag -- which breaks Discourse's built-in backup (Sidekiq CreateBackup ->
# "pg_dump: error: aborting because of server version mismatch"). Install the
# PG 18 client from the official PGDG repo so pg_dump >= the server major.
#
# On Debian /usr/bin/pg_dump is a symlink to pg_wrapper, which auto-selects the
# NEWEST installed client version. The base's 15 + this 18 means the wrapper
# resolves pg_dump/pg_restore/psql/pg_dumpall to 18 (verify: pg_dump --version
# -> 18.x). A PG 18 client can still dump older servers (client major >= server
# major), so this stays correct if the server is ever rolled back.
#
# Going forward: keep PG_MAJOR >= the server major. The client lagged the
# 17->18 server upgrade, which is what broke backups.
#
# This block also runs `apt-get upgrade -y` to pull base-layer security patches
# (the base image does not upgrade installed packages itself). Tradeoff: builds
# become slightly less reproducible since the upgraded package set depends on
# what's current in the apt repos at build time -- an acceptable cost for CVE
# patching.
# =============================================================================
ARG PG_MAJOR=18
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends postgresql-client-${PG_MAJOR} && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

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
# Diagnostics gem: sigdump
# =============================================================================
# Adds sigdump to the bundle for ptrace-free thread-backtrace dumps (the cluster
# runs ptrace_scope=2, so external tracers can't attach). rbtrace is already in
# Discourse core's Gemfile; sigdump is not, so we append it here.
#
# require=false: not auto-loaded, so the gem stays inert until the diagnostics
# initializer below requires it (gated by the Helm `diagnostics.sigdump.enabled`
# toggle). It lands in the DEFAULT group, so `--without test development` does
# not skip it and it resolves under `bundle exec` at runtime.
#
# We append the gem line directly (not `bundle add`) and let the NON-frozen
# install below fold it into Gemfile.lock. `bundle add --skip-install` followed
# by a frozen install leaves the Gemfile/lock inconsistent under Bundler 4
# (boot-time ProductionError: "dependencies were deleted from your gemfile").
#
# Discourse is re-checked-out fresh on every build, so this edit is reapplied
# each build (it is not persisted upstream).
RUN printf '\n# Diagnostics: ptrace-free thread dumps (Helm diagnostics.sigdump.enabled)\ngem "sigdump", require: false\n' \
    | sudo -u discourse tee -a Gemfile > /dev/null

# =============================================================================
# Diagnostics initializer: env-var-gated, in-process gem loading
# =============================================================================
# We load the diagnostics gems (rbtrace, sigdump) from a Rails initializer
# instead of via RUBYOPT. RUBYOPT preloads run at Ruby interpreter startup,
# BEFORE Bundler puts the path-installed bundle (vendor/bundle) on the load
# path, so `-r sigdump/setup` / `-r rbtrace` there fails with LoadError and
# crashes the worker at boot. An initializer runs AFTER Bundler.setup, in the
# fully-booted app where the bundle IS on the load path, so a plain `require`
# resolves. The Helm chart's diagnostics toggles set the matching env vars
# (DISCOURSE_DIAG_RBTRACE / DISCOURSE_DIAG_SIGDUMP) on the web container.
#
# Discourse autoloads config/initializers/*.rb at boot. Written as the
# discourse user (the checkout is owned by discourse).
# =============================================================================
RUN sudo -u discourse tee config/initializers/discourse_k8s_diagnostics.rb > /dev/null <<'INITIALIZER'
# frozen_string_literal: true
#
# Added by the discourse-k8s image. Loads in-process, ptrace-free diagnostics
# tools when the Helm chart's diagnostics toggles set the matching env var on
# the web container. We require here -- in a Rails initializer, AFTER Bundler
# has set up the bundle -- instead of via RUBYOPT, because RUBYOPT preloads run
# at Ruby interpreter startup, before Bundler puts the bundled gems on the load
# path; `-r sigdump/setup` / `-r rbtrace` there fails with LoadError and crashes
# the worker at boot.
#
# sigdump: SIGCONT dumps every thread's backtrace to /tmp/sigdump-<pid>.log.
# rbtrace: installs the rbtrace listener (best-effort; attaching also needs the
#          node's kernel.msgmax/msgmnb raised).
#
# Fail-safe: a diagnostics gem must NEVER crash the pod. Wrap the require so any
# load failure (LoadError or any other error) degrades to a log line with the
# exact cause and boot continues without the tool -- instead of a CrashLoop.
# This also surfaces the reason for any environment-specific load failure.
def k8s_diag_require(lib)
  require lib
rescue ScriptError, StandardError => e
  warn "[discourse-k8s diagnostics] could not load #{lib.inspect}: " \
       "#{e.class}: #{e.message} (continuing without it)"
end

k8s_diag_require("rbtrace") if ENV["DISCOURSE_DIAG_RBTRACE"] == "1"
k8s_diag_require("sigdump/setup") if ENV["DISCOURSE_DIAG_SIGDUMP"] == "1"
INITIALIZER

# =============================================================================
# Install Ruby gems
# =============================================================================
# Mirrors the web-only stage from discourse/discourse_docker.
# path ./vendor/bundle, --without test development as upstream.
#
# The install runs in NON-frozen mode so it can fold the appended sigdump gem
# into Gemfile.lock (only sigdump is added; every other gem stays at its locked
# version). We then set deployment=true so the runtime bundle is frozen and
# reproducible. The env vars override any frozen/deployment from the base
# image's .bundle/config for this one command only.
# =============================================================================
RUN sudo -u discourse bundle config --local path ./vendor/bundle && \
    sudo -u discourse bundle config --local without "test development" && \
    sudo -u discourse env BUNDLE_FROZEN=false BUNDLE_DEPLOYMENT=false \
        bundle install --jobs "$(( $(nproc) - 1 ))" && \
    sudo -u discourse bundle config --local deployment true && \
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
# Freeze git version info, then drop the .git directory (after-idle freeze fix)
# =============================================================================
# ROOT CAUSE of the ~14s after-idle staff-page freeze (captured live, twice,
# via sigdump): the homepage render serializes CurrentUserSerializer, whose
# #has_unseen_features -> DiscourseUpdates.new_features calls
# GitUtils.has_commit?, which shells out to
#   `git merge-base --is-ancestor <sha> HEAD`
# On a cold worker (post-idle) that subprocess cold-reads the ~122MB shallow
# .git and forks from a ~460MB pitchfork worker -- the worker parks in
# do_sys_poll on the subprocess pipe, zero CPU, for ~14s. It only hits staff
# (has_unseen_features is staff-gated) and only for cached "what's new" entries
# whose discourse_version is a full 40-char SHA -- has_commit? early-returns
# false (no fork) for plain version strings.
#
# Fix: this is an immutable image (rebuilt per release, never `git pull`), so
# the runtime .git is dead weight. We:
#   1. Bake config/git-utils-overrides.json. Discourse core's
#      GitUtils.filesystem_overrides reads this JSON (keys: git_version,
#      git_branch, full_version) and skips the `git rev-parse` / `git describe`
#      shell-outs for version reporting. A missing file is handled upstream
#      (Errno::ENOENT -> {}), so this is purely additive.
#      full_version is set to "<tag>-customized" on purpose. Upstream's
#      `git describe --dirty` would ALWAYS append "-dirty" here, because an
#      earlier build step edits a tracked file (appends `gem "sigdump"` to the
#      Gemfile) -- so the Discourse working tree is dirty on every build. A
#      constant "-dirty" is noise; "-customized" instead truthfully marks this
#      as the discourse-k8s build (not stock upstream) in the admin Version
#      panel. git_version stays the real HEAD SHA (the exact pinned commit).
#   2. rm -rf .git. Now has_commit?'s `git merge-base` fails fast ("not a git
#      repository", exit 128); try_git's `2>/dev/null; echo $?` wrapper swallows
#      it and returns "128" != "0" -> false. Silent, no pack read, no freeze.
#      Bonus: ~122MB smaller image.
#
# NOTE: filesystem_overrides does NOT cover has_commit? (it calls try_git
# directly), so removing .git -- not the overrides file -- is what kills the
# freeze; the overrides file only keeps the admin "Version" panel accurate.
# Runs AFTER assets:precompile so precompile still sees the real repo (the
# baked git_version equals the real HEAD, so nothing goes inconsistent).
# =============================================================================
RUN set -eu; \
    cd /var/www/discourse; \
    git_version="$(sudo -u discourse git rev-parse HEAD)"; \
    printf '{"git_version":"%s","git_branch":"%s","full_version":"%s"}\n' \
        "$git_version" "${DISCOURSE_VERSION}" "${DISCOURSE_VERSION}-customized" \
        | sudo -u discourse tee config/git-utils-overrides.json > /dev/null; \
    sudo -u discourse rm -rf .git

# =============================================================================
# Remove npm
# =============================================================================
# discourse/base:slim ships npm alongside Node, but nothing here uses it: the
# JS install runs through pnpm and the runtime is pitchfork. npm bundles its
# own copy of node-tar and friends, which Trivy scans and flags (e.g.
# CVE-2026-59873 in tar 7.5.11 via npm 10.9.8). Dropping the unused tool
# removes that whole dependency surface rather than patching it release by
# release.
# =============================================================================
RUN rm -rf /usr/lib/node_modules/npm /usr/bin/npm /usr/bin/npx

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

# =============================================================================
# Strip setuid/setgid bits (defense-in-depth, portable Bitnami practice)
# =============================================================================
# We run as the unprivileged `discourse` user and never need setuid helpers at
# runtime, so clear the setuid/setgid bits on every on-disk binary to blunt
# privilege-escalation paths if the container is ever compromised. -xdev keeps
# the scan on the image filesystem (never traverses mounted volumes). Verified
# NOT already done by discourse/base:slim.
# =============================================================================
RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} \; 2>/dev/null || true

# Drop from root to the discourse user. Build steps above use sudo -u discourse
# for file operations; at runtime there's no reason to stay root.
USER discourse

# Default: run the web server (pitchfork, Discourse's unicorn successor).
# Override in K8s to run Sidekiq or one-off tasks.
#
# Discourse's bin/unicorn auto-delegates to bin/pitchfork unless RUN_PITCHFORK=0.
# We call pitchfork directly to be explicit.
CMD ["bundle", "exec", "pitchfork", "-E", "production", "-c", "config/pitchfork.conf.rb"]
