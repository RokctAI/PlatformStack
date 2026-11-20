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

# Ignition + Frappe v16 + composed product app (default PRODUCT=rokctapp).
#
# One image for the Ignition processes of a stack: `serve` (port 8000),
# `worker`, `scheduler`, plus the one-shot commands (new-site, migrate,
# backup, restore, ...). No bench, no nginx, no socketio, no DB, no Redis:
# those are separate containers in the stack file.
#
# Build (BuildKit; see platform/ignition/README.md and
# platform/scripts/build_ignition_image.sh):
#
#   docker buildx build -f platform/ignition.Dockerfile \
#     --build-context core=<path to RokctAI/core checkout> \
#     --build-context pay=<RokctAI/pay checkout> \
#     --build-context productivity=<RokctAI/productivity checkout> \
#     --build-context zones=<RokctAI/zones checkout> \
#     --secret id=git_token,env=MONOREPO_PAT \
#     --target ignition_rokctapp -t ignition-rokctapp .
#
# The git token is a BuildKit secret: it is mounted only for the RUN steps
# that clone or pip-install private repos, never written to a layer, an ENV,
# a git config or a remote URL.

ARG PYTHON_IMAGE=python:3.14-slim

# --- Stage 1: build the Ignition root (compose + frappe + venv) ---------------
FROM ${PYTHON_IMAGE} AS ignition_root_builder
ENV DEBIAN_FRONTEND=noninteractive PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN apt-get update -qq \
    && apt-get install -yqq --no-install-recommends \
        git ca-certificates build-essential pkg-config \
        libmariadb-dev libpq-dev libffi-dev libjpeg-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Template and refs. Pin PROTOCOL_REF / RCORE_REF to SHAs for a release; the
# resolved SHAs land in /opt/ignition/ignition_build.json either way.
ARG PRODUCT=rokctapp
ARG PROTOCOL_REF=main
ARG RCORE_REF=main
ARG FRAPPE_REPO=https://github.com/frappe/frappe
ARG FRAPPE_REF=version-16-hotfix
# rokctapp needs Postgres: on MariaDB rcore's `users` module collides with
# Frappe v16's `Users` (case-insensitive Module Def key).
ARG DB_TYPE=postgres

COPY platform/scripts/compose_product.py /usr/local/lib/ignition-build/compose_product.py
COPY platform/scripts/build_ignition_root.sh /usr/local/lib/ignition-build/build_ignition_root.sh
COPY platform/scripts/patch_frappe_v16.py /usr/local/lib/ignition-build/patch_frappe_v16.py

# Compose (ROKCT_COMPOSE_STRICT=1), clone and patch Frappe, create
# /opt/ignition/env and pip install frappe + the composed app + its requirements.
RUN --mount=type=secret,id=git_token,required=false \
    COMPOSE_PY=/usr/local/lib/ignition-build/compose_product.py \
    PATCH_FRAPPE_PY=/usr/local/lib/ignition-build/patch_frappe_v16.py \
    bash /usr/local/lib/ignition-build/build_ignition_root.sh \
        --root /opt/ignition \
        --product "${PRODUCT}" \
        --protocol-ref "${PROTOCOL_REF}" \
        --rcore-ref "${RCORE_REF}" \
        --frappe-ref "${FRAPPE_REF}" \
        --db-type "${DB_TYPE}" \
        --python python3 \
        --token-file /run/secrets/git_token

# Ignition (Pulsar) from the RokctAI/core checkout passed as build context
# `core` (--build-context core=...; DL3022 cannot see named contexts).
# hadolint ignore=DL3022
COPY --from=core pulsar/pulsar /opt/pulsar/pulsar
# The Pulsar modules that moved out of core live in the SDK repos (build contexts pay, productivity, zones);
# the old pulsar.* paths in /opt/pulsar/pulsar are shims that load them from $PULSAR_SDK_ROOT/<repo>/<sdk>/pulsar/ported.
# hadolint ignore=DL3022
COPY --from=pay erp/pulsar/ported /opt/sdk/pay/erp/pulsar/ported
# hadolint ignore=DL3022
COPY --from=pay hrms/pulsar/ported /opt/sdk/pay/hrms/pulsar/ported
# hadolint ignore=DL3022
COPY --from=productivity crm/pulsar/ported /opt/sdk/productivity/crm/pulsar/ported
# hadolint ignore=DL3022
COPY --from=productivity projects/pulsar/ported /opt/sdk/productivity/projects/pulsar/ported
# hadolint ignore=DL3022
COPY --from=productivity support/pulsar/ported /opt/sdk/productivity/support/pulsar/ported
# hadolint ignore=DL3022
COPY --from=zones map/pulsar/ported /opt/sdk/zones/map/pulsar/ported
RUN /opt/ignition/env/bin/pip install \
        -r /opt/pulsar/pulsar/requirements.txt \
        -r /opt/pulsar/pulsar/requirements-extras.txt \
    && PYTHONPATH=/opt/pulsar PULSAR_SDK_ROOT=/opt/sdk /opt/ignition/env/bin/python -c \
        "import pulsar.ignition, pulsar.accounts.chart, pulsar.hr.leave, pulsar.crm.lead, pulsar.projects.task, pulsar.support.issue, pulsar.geo.country_info" \
    && /opt/ignition/env/bin/python -m compileall -q /opt/pulsar/pulsar /opt/ignition/apps/rcore/rcore \
    && (/opt/ignition/env/bin/python -m compileall -q -x '/boilerplate/' /opt/ignition/apps/frappe/frappe || true)
# ^ The runtime user cannot write .pyc files into the root-owned code, so they
#   are compiled here. Frappe is best effort: it ships Jinja templates with a
#   .py suffix that are not meant to compile.

# --- Stage 2: runtime ----------------------------------------------------------
FROM ${PYTHON_IMAGE} AS ignition_rokctapp
ARG DB_TYPE=postgres
ENV DEBIAN_FRONTEND=noninteractive
# Runtime libraries for mysqlclient/psycopg/Pillow, DB clients for Ignition's
# backup/restore (mysqldump/mysql, pg_dump/psql), git for Frappe's version info.
RUN apt-get update -qq \
    && apt-get install -yqq --no-install-recommends \
        ca-certificates git libmariadb3 libpq5 libjpeg62-turbo \
        mariadb-client postgresql-client \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10001 ignition

# Code (apps, env, pulsar) is root-owned and read-only for the runtime user;
# only the data dirs below belong to it.
COPY --from=ignition_root_builder /opt/ignition /opt/ignition
COPY --from=ignition_root_builder /opt/pulsar /opt/pulsar
COPY --from=ignition_root_builder /opt/sdk /opt/sdk
# hadolint ignore=DL3022
COPY --from=core docker/ignition/bench /usr/local/bin/bench
COPY platform/ignition/entrypoint.sh /usr/local/bin/ignition-entrypoint

# The baked app list is kept outside sites/ (a volume) so the entrypoint can
# put it back into sites/apps.txt on every start, frappe first.
RUN cp /opt/ignition/sites/apps.txt /opt/ignition/apps.baked.txt \
    && chmod 0755 /usr/local/bin/ignition-entrypoint /usr/local/bin/bench \
    && mkdir -p /opt/ignition/run /opt/ignition/logs /opt/ignition/backups \
    && chown -R ignition:ignition /opt/ignition/sites /opt/ignition/run \
        /opt/ignition/logs /opt/ignition/backups /opt/ignition/.rokct

USER 10001:10001
WORKDIR /opt/ignition
ENV PATH="/opt/ignition/env/bin:${PATH}" \
    PYTHONPATH=/opt/pulsar \
    PULSAR_SDK_ROOT=/opt/sdk \
    PYTHONUNBUFFERED=1 \
    IGNITION_ROOT=/opt/ignition \
    IGNITION_HOST=0.0.0.0 \
    IGNITION_DB_TYPE=${DB_TYPE}

# sites/ holds site data and the stack-written common_site_config.json;
# backups/ holds Ignition backup sets. Code is not in a volume, so a new
# image always brings its own apps.
VOLUME ["/opt/ignition/sites", "/opt/ignition/backups", "/opt/ignition/logs"]
EXPOSE 8000
ENTRYPOINT ["ignition-entrypoint"]
CMD ["serve"]
