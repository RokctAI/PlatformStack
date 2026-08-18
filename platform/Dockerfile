# Stage 1: Base - System Dependencies
FROM python:3.14-slim AS base

ARG GITHUB_TOKEN
ARG MONOREPO_PAT
ARG EMAIL_ENCRYPTION_KEY
# Do NOT promote EMAIL_ENCRYPTION_KEY to a persisted image ENV (leaks via docker
# history/inspect). It is injected at runtime by the compose files instead.
ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# System Dependencies - Step 1: Setup tools and external repo definitions
RUN apt-get update -qq && apt-get install -yqq curl ca-certificates gnupg sudo wget >/dev/null 2>&1 \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --batch --yes -o /etc/apt/keyrings/postgresql.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo $VERSION_CODENAME)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --batch --yes -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# System Dependencies - Step 2: Install packages (after repos are added)
RUN apt-get update -qq && apt-get install -yqq \
    git postgresql-client-16 postgresql-16-pgvector \
    gettext-base build-essential \
    cron vim nodejs redis-server netcat-openbsd \
    libffi-dev libjpeg-dev zlib1g-dev \
    >/dev/null 2>&1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Docker CLI and Docker Compose statically to allow container orchestration
RUN curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-24.0.7.tgz -o /tmp/docker.tgz \
    && echo "984d59a77fa6acab97ea725a966facd33725e0e09c2fee975397fe1c6379bd3d  /tmp/docker.tgz" | sha256sum -c - \
    && tar -xz -C /tmp -f /tmp/docker.tgz \
    && mv /tmp/docker/docker /usr/local/bin/ \
    && rm -rf /tmp/docker /tmp/docker.tgz \
    && curl -fsSL "https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-Linux-x86_64" -o /usr/local/bin/docker-compose \
    && echo "94355be1d1d395040bbda1490f98d5c7627c30798a7955e1f2a78fda33a4b3e1  /usr/local/bin/docker-compose" | sha256sum -c - \
    && chmod +x /usr/local/bin/docker-compose

RUN npm install -g yarn pnpm && npm cache clean --force
RUN useradd -ms /bin/bash frappe && \
    usermod -aG sudo frappe && \
    echo "frappe ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/frappe && \
    chmod 0440 /etc/sudoers.d/frappe

USER frappe
WORKDIR /home/frappe
ENV PATH="/home/frappe/.local/bin:${PATH}"
RUN pip install --user frappe-bench

# Stage 2: The Giant Builder (Clones everything)
FROM base AS builder
USER root
# Resolve effective git token: MONOREPO_PAT preferred, GITHUB_TOKEN as fallback
ARG MONOREPO_PAT
ARG GITHUB_TOKEN
RUN GIT_TOKEN="${MONOREPO_PAT:-${GITHUB_TOKEN}}"; \
    if [ -n "${GIT_TOKEN}" ] && [ "${GIT_TOKEN}" != "***" ]; then \
        git config --global url."https://x-access-token:${GIT_TOKEN}@github.com/".insteadOf "git@github.com:" && \
        git config --global url."https://x-access-token:${GIT_TOKEN}@github.com/".insteadOf "https://github.com/"; \
    fi
USER frappe
ARG DB_HOST=127.0.0.1

# Inject Context & Run Golden Build
COPY --chown=frappe:frappe overrides /home/frappe/overrides
COPY --chown=frappe:frappe current_repo /home/frappe/current_repo
COPY --chown=frappe:frappe platform/scripts/build_ecosystem.sh /usr/local/bin/build_ecosystem.sh
RUN GIT_TOKEN="${MONOREPO_PAT:-${GITHUB_TOKEN}}"; \
    chmod +x /usr/local/bin/build_ecosystem.sh && \
    export BOOTSTRAP=true && export DB_TYPE=postgres && export DB_PW=admin && \
    export GITHUB_TOKEN="${GIT_TOKEN}" && \
    export GITHUB_WORKSPACE=/home/frappe/current_repo && \
    export DB_HOST=${DB_HOST} && \
    export APP_NAME=$(cat /home/frappe/current_repo/pyproject.toml 2>/dev/null | grep -m1 'name = "' | cut -d'"' -f2 || echo "rpanel") && \
    /usr/local/bin/build_ecosystem.sh || (cat /tmp/build_ecosystem.log && exit 1)

# Clone and build rok-paperclip-adapter
RUN git clone --depth 1 --branch rokct https://github.com/RokctAI/rok-paperclip-adapter.git /home/frappe/rok-paperclip-adapter && \
    cd /home/frappe/rok-paperclip-adapter && \
    npm install && \
    npm run build

# Clone Paperclip Host and link rok-paperclip-adapter
RUN git clone --depth 1 https://github.com/paperclipai/paperclip.git /home/frappe/paperclip && \
    cd /home/frappe/paperclip && \
    npm install && \
    npm install /home/frappe/rok-paperclip-adapter

# Preserve the baked site so the entrypoint can seed an empty volume on first boot
# (Named volume mounts shadow the image layers, so we keep a backup outside /sites)
RUN cp -a /home/frappe/frappe-bench/sites /home/frappe/frappe-bench-image-sites

# Stage 3: Control Hub (Full Image)
FROM builder AS full
USER root
RUN apt-get update && apt-get install -y nginx exim4-daemon-heavy opendkim opendkim-tools openssl && apt-get clean && rm -rf /var/lib/apt/lists/*
VOLUME ["/etc/exim4", "/var/spool/exim4", "/var/log/exim4", "/etc/opendkim", "/etc/nginx", "/var/log/nginx", "/etc/cron.d"]
RUN chmod -R 777 /var/log/nginx /var/lib/nginx
WORKDIR /home/frappe/frappe-bench
COPY --chown=root:root platform/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chown=root:root platform/scripts/exim4_bootstrap.sh /usr/local/bin/exim4_bootstrap.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/exim4_bootstrap.sh
USER frappe
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bench", "start"]

# --- Stage 4A: Tenant Stripper ---
FROM builder AS tenant_stripper
ARG DB_HOST=127.0.0.1
WORKDIR /home/frappe/frappe-bench
# Uninstall control/rpanel from the baked seed site's DATABASE while their code
# still exists on disk — bench needs to import an app to run its uninstall
# hooks. Without this, the seed site's DB keeps referencing control/rpanel as
# installed apps even after the code below is deleted, which crashes module
# resolution the moment a tenant boots from that baked site (the site gets
# renamed and reused verbatim by docker-entrypoint.sh's BAKED_SITE path).
# The baked site's name isn't a single reliable constant (install.sh's
# bootstrap always creates "rpanel.local" regardless of what build_ecosystem.sh
# computed as SITE_NAME, which can itself resolve to "platform.rokct.ai") — so
# iterate over whatever site directories actually exist instead of assuming one.
RUN export DB_HOST="${DB_HOST}" && \
    export PATH="/home/frappe/frappe-bench/env/bin:$PATH" && \
    for site_dir in sites/*/; do \
        site=$(basename "$site_dir"); \
        [ -f "$site_dir/site_config.json" ] || continue; \
        bench --site "$site" uninstall-app control --yes --force 2>&1 || true; \
        bench --site "$site" uninstall-app rpanel --yes --force 2>&1 || true; \
    done
RUN cd apps && \
    ../env/bin/pip uninstall -y control rpanel || true && \
    rm -rf control rpanel
RUN env/bin/pip uninstall -y rok-agent || true && \
    rm -rf tools/rok /home/frappe/rok-paperclip-adapter /home/frappe/paperclip
RUN echo "frappe" > sites/apps.txt && \
    ls -1 apps | grep -v 'frappe' >> sites/apps.txt || true

# Stage 4: Supacharge (Tenant image, keeps lms)
# Supacharge is just a normal tenant — its own image is the plain
# tenant_stripper output, unmodified. lms lives in every tenant's rcore
# composition already; Supacharge is simply the tenant that gets to keep it.
FROM base AS tenant_supacharge
COPY --from=tenant_stripper --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
WORKDIR /home/frappe/frappe-bench
USER root
COPY --chown=root:root platform/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
USER frappe
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bench", "start"]

# --- Stage 4B: Generic Tenant Stripper ---
# lms is Supacharge's home SDK, composed into rcore for every tenant (see
# rcore/composer.json). Non-Supacharge tenants don't need it, so strip the
# composed module out of rcore's own package tree before it ships.
FROM tenant_stripper AS generic_tenant_stripper
WORKDIR /home/frappe/frappe-bench
RUN if [ -d "apps/rcore/rcore/lms" ]; then \
        rm -rf apps/rcore/rcore/lms && \
        sed -i '/^lms$/d' apps/rcore/rcore/modules.txt 2>/dev/null || true; \
    fi

# Stage 4: Tenant (Trimmed Image, lms stripped — the default/generic tenant)
FROM base AS tenant
COPY --from=generic_tenant_stripper --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
WORKDIR /home/frappe/frappe-bench
USER root
COPY --chown=root:root platform/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
USER frappe
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bench", "start"]

# --- Stage 5A: IoT Stripper ---
FROM tenant_stripper AS iot_stripper
WORKDIR /home/frappe/frappe-bench
# brain is no longer a separate app — it's merged into rcore, so keeping
# rcore already keeps brain's code (see build_ecosystem.sh's frappebrain alias).
ENV IOT_KEEP_APPS="frappe rcore"
RUN cd apps && \
    for app in *; do \
        if [ -d "$app" ] && ! echo "$IOT_KEEP_APPS" | grep -qw "$app"; then \
            echo "Uninstalling $app from IoT image..." && \
            ../env/bin/pip uninstall -y "$app" || true; \
            rm -rf "$app"; \
        fi \
    done && \
    rm -rf ../tools/rok /home/frappe/rok-paperclip-adapter /home/frappe/paperclip
RUN printf "frappe\nrcore\nbrain\n" > sites/apps.txt

# Stage 5: IoT (Minimal Image)
FROM base AS iot
COPY --from=iot_stripper --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
WORKDIR /home/frappe/frappe-bench
USER root
COPY --chown=root:root platform/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
USER frappe
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bench", "start"]

# =============================================================================
# OPT-IN COMPOSE-AT-BUILD PATH (per-product tenant images)
#
# Everything below is additive and opt-in: no existing stage above references
# these stages, and building any existing target is byte-identical to before.
#
# The golden `builder` stage fetches rcore with `bench get-app` — which today
# ships the bare shell (modules.txt = rcore, paas) because nothing in this
# pipeline ever invoked The-Rokct-Protocol composer. The `composed_builder`
# stage instead composes rcore from a per-product template
# (core/utils/frappe/composer/<PRODUCT>.json in The-Rokct-Protocol) BEFORE
# running the same golden build, so the baked seed site actually installs the
# product's full module set. Template refs that are mutable ("main") are
# resolved to commit SHAs at build time via git ls-remote and logged in
# composed_provenance.json inside the app — see compose_product.py.
# =============================================================================

# --- Stage 6A: Composed Builder (golden build with a composed rcore) ---
FROM base AS composed_builder
USER root
ARG MONOREPO_PAT
ARG GITHUB_TOKEN
RUN GIT_TOKEN="${MONOREPO_PAT:-${GITHUB_TOKEN}}"; \
    if [ -n "${GIT_TOKEN}" ] && [ "${GIT_TOKEN}" != "***" ]; then \
        git config --global url."https://x-access-token:${GIT_TOKEN}@github.com/".insteadOf "git@github.com:" && \
        git config --global url."https://x-access-token:${GIT_TOKEN}@github.com/".insteadOf "https://github.com/"; \
    fi
USER frappe
ARG DB_HOST=127.0.0.1
# Which product template to compose (core/utils/frappe/composer/<PRODUCT>.json).
# PRODUCT=rcore composes the full 26-module manifest — the closest parity to
# what rcore's own composer.json declares.
ARG PRODUCT=rcore
# Pin PROTOCOL_REF to a commit SHA for reproducible builds; "main" works but
# floats (the resolved SHA is logged either way).
ARG PROTOCOL_REF=main
ARG RCORE_REF=main

COPY --chown=frappe:frappe overrides /home/frappe/overrides
COPY --chown=frappe:frappe current_repo /home/frappe/current_repo
COPY --chown=frappe:frappe platform/scripts/build_ecosystem.sh /usr/local/bin/build_ecosystem.sh
COPY --chown=frappe:frappe platform/scripts/compose_product.py /usr/local/bin/compose_product.py

# 1. Compose the product's rcore app BEFORE the golden build. The output lands
#    at $GITHUB_WORKSPACE/rcore, so build_ecosystem.sh's existing
#    "Using LOCAL rcore from workspace" staging branch picks it up and
#    `bench get-app rcore` never runs. build_ecosystem.sh itself is unchanged.
RUN GIT_TOKEN="${MONOREPO_PAT:-${GITHUB_TOKEN}}"; \
    export MONOREPO_PAT="${GIT_TOKEN}" && \
    python3 /usr/local/bin/compose_product.py \
        --product "${PRODUCT}" \
        --protocol-ref "${PROTOCOL_REF}" \
        --shell-ref "${RCORE_REF}" \
        --output /home/frappe/current_repo/rcore

# 2. Golden build — the same invocation as the builder stage.
RUN GIT_TOKEN="${MONOREPO_PAT:-${GITHUB_TOKEN}}"; \
    chmod +x /usr/local/bin/build_ecosystem.sh && \
    export BOOTSTRAP=true && export DB_TYPE=postgres && export DB_PW=admin && \
    export GITHUB_TOKEN="${GIT_TOKEN}" && \
    export GITHUB_WORKSPACE=/home/frappe/current_repo && \
    export DB_HOST=${DB_HOST} && \
    export APP_NAME=$(cat /home/frappe/current_repo/pyproject.toml 2>/dev/null | grep -m1 'name = "' | cut -d'"' -f2 || echo "rpanel") && \
    /usr/local/bin/build_ecosystem.sh || (cat /tmp/build_ecosystem.log && exit 1)

# No paperclip/rok-paperclip-adapter clone here: this path only feeds tenant
# images, and the tenant stripper removes those trees anyway.

# Preserve the baked site so the entrypoint can seed an empty volume on first
# boot (mirrors the builder stage).
RUN cp -a /home/frappe/frappe-bench/sites /home/frappe/frappe-bench-image-sites

# --- Stage 6B: Composed Tenant Stripper ---
# Same strip as tenant_stripper (Stage 4A), applied to the composed bench:
# control/rpanel uninstalled from the baked seed DB while their code still
# exists, then removed from disk. The rm -rf of rok/paperclip trees is a
# no-op here (never cloned) but kept identical for symmetry.
FROM composed_builder AS composed_tenant_stripper
ARG DB_HOST=127.0.0.1
WORKDIR /home/frappe/frappe-bench
RUN export DB_HOST="${DB_HOST}" && \
    export PATH="/home/frappe/frappe-bench/env/bin:$PATH" && \
    for site_dir in sites/*/; do \
        site=$(basename "$site_dir"); \
        [ -f "$site_dir/site_config.json" ] || continue; \
        bench --site "$site" uninstall-app control --yes --force 2>&1 || true; \
        bench --site "$site" uninstall-app rpanel --yes --force 2>&1 || true; \
    done
RUN cd apps && \
    ../env/bin/pip uninstall -y control rpanel || true && \
    rm -rf control rpanel
RUN env/bin/pip uninstall -y rok-agent || true && \
    rm -rf tools/rok /home/frappe/rok-paperclip-adapter /home/frappe/paperclip
RUN echo "frappe" > sites/apps.txt && \
    ls -1 apps | grep -v 'frappe' >> sites/apps.txt || true

# --- Stage 6: Composed Tenant (per-product image) ---
# No lms strip and no per-module surgery here: the product's compose template
# already defines exactly which modules this image carries.
FROM base AS tenant_composed
COPY --from=composed_tenant_stripper --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
WORKDIR /home/frappe/frappe-bench
USER root
COPY --chown=root:root platform/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
USER frappe
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bench", "start"]
