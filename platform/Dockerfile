# Stage 1: Base - System Dependencies
FROM python:3.14-slim AS base

ARG GITHUB_TOKEN
ARG MONOREPO_PAT
ARG EMAIL_ENCRYPTION_KEY
ENV EMAIL_ENCRYPTION_KEY=$EMAIL_ENCRYPTION_KEY
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
RUN curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-24.0.7.tgz | tar -xz -C /tmp \
    && mv /tmp/docker/docker /usr/local/bin/ \
    && rm -rf /tmp/docker \
    && curl -fsSL "https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-Linux-x86_64" -o /usr/local/bin/docker-compose \
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
COPY --chown=frappe:frappe monorepo_overrides /home/frappe/monorepo_overrides
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
COPY --chown=frappe:frappe platform/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chown=frappe:frappe platform/scripts/exim4_bootstrap.sh /usr/local/bin/exim4_bootstrap.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/exim4_bootstrap.sh
USER frappe
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bench", "start"]

# --- Stage 4A: Tenant Stripper ---
FROM builder AS tenant_stripper
WORKDIR /home/frappe/frappe-bench
RUN cd apps && \
    ../env/bin/pip uninstall -y control rpanel || true && \
    rm -rf control rpanel
RUN env/bin/pip uninstall -y rok-agent || true && \
    rm -rf tools/rok /home/frappe/rok-paperclip-adapter /home/frappe/paperclip
RUN echo "frappe" > sites/apps.txt && \
    ls -1 apps | grep -v 'frappe' >> sites/apps.txt || true

# Stage 4: Tenant (Trimmed Image)
FROM base AS tenant
COPY --from=tenant_stripper --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
WORKDIR /home/frappe/frappe-bench
USER root
COPY --chown=frappe:frappe platform/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
USER frappe
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bench", "start"]

# --- Stage 5A: IoT Stripper ---
FROM tenant_stripper AS iot_stripper
WORKDIR /home/frappe/frappe-bench
ENV IOT_KEEP_APPS="frappe rcore brain"
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
COPY --chown=frappe:frappe platform/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
USER frappe
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bench", "start"]
