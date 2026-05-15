# Copyright 2024 RokctAI
# Stage 1: Base - System Dependencies
FROM python:3.14-slim AS base

ARG GITHUB_TOKEN
ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# System Dependencies - Step 1: Setup tools and external repo definitions
RUN apt-get update -qq && apt-get install -yqq curl ca-certificates gnupg sudo wget >/dev/null 2>&1 \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor --batch --yes -o /etc/apt/keyrings/postgresql.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo $VERSION_CODENAME)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --batch --yes -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list

# System Dependencies - Step 2: Install packages (after repos are added)
RUN apt-get update -qq && apt-get install -yqq \
    git postgresql-client-16 postgresql-16-pgvector \
    gettext-base build-essential \
    cron vim nodejs redis-server netcat-openbsd \
    libffi-dev libjpeg-dev zlib1g-dev \
    >/dev/null 2>&1 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g yarn pnpm
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
RUN git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "git@github.com:" && \
    git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
USER frappe
ARG DB_HOST=127.0.0.1

# Inject Context & Run Golden Build
COPY --chown=frappe:frappe monorepo_overrides /home/frappe/monorepo_overrides
COPY --chown=frappe:frappe current_repo /home/frappe/current_repo
RUN wget -qO /tmp/build_ecosystem.sh https://raw.githubusercontent.com/RokctAI/shared-workflows/main/scripts/build_ecosystem.sh && \
    chmod +x /tmp/build_ecosystem.sh && \
    export BOOTSTRAP=true && export DB_TYPE=postgres && export DB_PW=admin && \
    export GITHUB_TOKEN=${GITHUB_TOKEN} && \
    export GITHUB_WORKSPACE=/home/frappe/current_repo && \
    export DB_HOST=${DB_HOST} && \
    export APP_NAME=$(cat /home/frappe/current_repo/pyproject.toml 2>/dev/null | grep -m1 'name = "' | cut -d'"' -f2 || echo "rpanel") && \
    /tmp/build_ecosystem.sh || (cat /tmp/build_ecosystem.log && exit 1)

# Preserve the baked site so the entrypoint can seed an empty volume on first boot
# (Named volume mounts shadow the image layers, so we keep a backup outside /sites)
RUN cp -a /home/frappe/frappe-bench/sites /home/frappe/frappe-bench-image-sites

# Stage 3: Control Hub (Full Image)
FROM builder AS full
USER root
RUN apt-get update && apt-get install -y nginx exim4-daemon-heavy opendkim opendkim-tools && rm -rf /var/lib/apt/lists/*
VOLUME ["/etc/exim4", "/var/spool/exim4", "/var/log/exim4", "/etc/opendkim", "/etc/nginx", "/var/log/nginx", "/etc/cron.d"]
RUN chmod -R 777 /var/log/nginx /var/lib/nginx
COPY --chown=frappe:frappe docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
USER frappe
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bench", "start"]

# Stage 4: Tenant (Trimmed Image)
FROM base AS tenant
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
WORKDIR /home/frappe/frappe-bench
RUN rm -rf apps/control apps/rpanel
USER root
COPY --chown=frappe:frappe docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
USER frappe
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bench", "start"]

# Stage 5: IoT (Minimal Image)
FROM tenant AS iot
RUN rm -rf apps/erpnext apps/payments apps/paas tools/rok # IoT doesn't need ERP, Payments, PAAS, or ROK
