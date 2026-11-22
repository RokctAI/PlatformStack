# syntax=docker/dockerfile:1.7
# Copyright (c) 2026 ROKCT INTELLIGENCE (PTY) LTD
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, version 3.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

# Pulsar-engine image: the Pulsar framework (RokctAI/core pulsar/) and the SDK packages (<repo>/<pkg>/pulsar) on
# Python, nothing else. No bench, no Frappe, no node, no nginx: a site is a Postgres database made by
# `python -m pulsar.ignition new-site --engine pulsar`, served by `serve --engine pulsar`.
#
# The build context is a staged folder (platform/scripts/build_pulsar_images.sh makes it):
#   framework/          RokctAI/core pulsar/ (the pulsar package, services/), no tests
#   sdk/<repo>/<pkg>/pulsar   every SDK package of every repo, no tests
#
#   platform/scripts/build_pulsar_images.sh            # builds pulsar-hub and pulsar-tenant
#
# Targets (also pulsar-supacharge, pulsar-tenant-composed, pulsar-drone below): pulsar-hub (PULSAR_ROLE=hub: makes its control site on first start) and pulsar-tenant (PULSAR_ROLE=tenant:
# a tenant docker; the server agent adds sites to it with create_site engine "pulsar").

# Sticks engine (Rakazo), one per tenant docker (Ray 2026-11-21). CI passes the built `engine` target of
# RokctAI/sticks-server (pinned) as the named context `sticks-engine`; without it this empty stage stands in and the
# tenant images start Pulsar only.
FROM busybox:1.37 AS sticks-engine
RUN mkdir -p /opt/sticks

FROM node:24-bookworm-slim AS node-runtime

FROM python:3.13-slim AS pulsar-base
# The upgrade test refuses any hub/tenant image without this label (a bench image never has it).
LABEL rokct.engine=pulsar
# Every recorded error names the version and core commit it ran (pulsar.error_capture); CI passes both.
ARG PULSAR_VERSION=""
ARG PULSAR_COMMIT=""
ENV PULSAR_VERSION=${PULSAR_VERSION} PULSAR_COMMIT=${PULSAR_COMMIT}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PULSAR_HOME=/opt/pulsar IGNITION_ROOT=/srv/pulsar PULSAR_SDK_ROOT=/opt/pulsar/sdk \
    PYTHONPATH=/opt/pulsar/framework
RUN groupadd --system pulsar && useradd --system --gid pulsar --home-dir /srv/pulsar --shell /usr/sbin/nologin pulsar
COPY framework/pulsar/requirements.txt framework/pulsar/requirements-extras.txt /tmp/req/
# wheels/ is empty unless the build script was given PULSAR_WHEELS (an offline or air-gapped build)
COPY wheels/ /tmp/wheels/
RUN if ls /tmp/wheels/*.whl >/dev/null 2>&1; then src="--no-index --find-links /tmp/wheels"; else src=""; fi; \
    pip install --no-cache-dir $src -r /tmp/req/requirements.txt -r /tmp/req/requirements-extras.txt && rm -rf /tmp/req /tmp/wheels
COPY --chown=root:root framework/ /opt/pulsar/framework/
COPY --chown=root:root sdk/ /opt/pulsar/sdk/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/pulsar-entrypoint
RUN mkdir -p /srv/pulsar && chown pulsar:pulsar /srv/pulsar \
    && python -c "import pulsar.ignition.cli, pulsar.http_api"
# hadolint ignore=DL3066
USER pulsar
WORKDIR /srv/pulsar
VOLUME ["/srv/pulsar"]
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=5 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/method/ping', timeout=4).status == 200 else 1)"]
ENTRYPOINT ["pulsar-entrypoint"]
CMD ["serve"]

FROM pulsar-base AS pulsar-hub
ENV PULSAR_ROLE=hub

# Tenant dockers carry Pulsar plus the Sticks engine; tenants sharing a docker share its engine. Postgres stays outside.
FROM pulsar-base AS pulsar-tenant-base
USER root
COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=sticks-engine --chown=root:root /opt/sticks /opt/sticks
USER pulsar
ENV STICKS_ENGINE=/opt/sticks/build/up/apps/sticks-engine/dist/sticks-engine.mjs API_PORT=3100
EXPOSE 3100

FROM pulsar-tenant-base AS pulsar-tenant
ENV PULSAR_ROLE=tenant

# Supacharge tenant docker: same engine, product recorded for the hub. (lms has no Pulsar port yet.)
FROM pulsar-tenant-base AS pulsar-supacharge
ENV PULSAR_ROLE=tenant PULSAR_PRODUCT=supacharge

# Per-product tenant (build.yml docker-composed, workflow_dispatch composed-product=<name>).
FROM pulsar-tenant-base AS pulsar-tenant-composed
ARG PULSAR_PRODUCT=rokctapp
ENV PULSAR_ROLE=tenant PULSAR_PRODUCT=${PULSAR_PRODUCT}

# Drone brain (platform/docker-compose.iot.yml, image drone-brain): a single-site tenant on a low-RAM edge device.
FROM pulsar-base AS pulsar-drone
ENV PULSAR_ROLE=tenant PULSAR_PRODUCT=drone
