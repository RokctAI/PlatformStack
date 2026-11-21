#!/bin/sh
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

# Entrypoint of the Pulsar-engine images (platform/pulsar/Dockerfile).
#   PULSAR_ROLE        hub | tenant (set by the image target)
#   PULSAR_SITE        a site to make on first start when it does not exist (the hub's control site; optional on a
#                      tenant docker, where the server agent's create_site adds sites)
#   PULSAR_SITE_EXTRA  JSON merged into that site's site_config.json when it is made (app_role, tenant_domain, ...)
#   IGNITION_DB_HOST / IGNITION_DB_PORT / IGNITION_DB_ROOT_USER / IGNITION_DB_ROOT_PASSWORD   the Postgres superuser
#   STICKS_TENANT      when set on a tenant docker, the Sticks engine (STICKS_ENGINE) starts beside serve; its
#                      STICKS_* env and /run/secrets are listed in sticks-server docs/tasks/task-17-tenant-image.md
#   IGNITION_ADMIN_PASSWORD   the Administrator password of a site made here and of the API login
# serve: waits for Postgres, makes PULSAR_SITE if missing, then serves the site (IGNITION_SITE, else the only one;
# a tenant docker with no site yet waits until create_site makes one). worker | scheduler run the job processes.
# Anything else runs `python -m pulsar.ignition <args>`.
set -eu
umask 027
ROOT="${IGNITION_ROOT:-/srv/pulsar}"
mkdir -p "$ROOT/sites" "$ROOT/logs" "$ROOT/run"
[ -f "$ROOT/sites/common_site_config.json" ] || printf '{"db_type": "postgres"}\n' >"$ROOT/sites/common_site_config.json"
[ -f "$ROOT/sites/apps.txt" ] || : >"$ROOT/sites/apps.txt"
ign() { python -m pulsar.ignition --root "$ROOT" "$@"; }

wait_db() {
  python - <<'PY'
import os, sys, time
import psycopg
for _ in range(120):
    try:
        psycopg.connect(host=os.environ.get("IGNITION_DB_HOST", "127.0.0.1"), port=int(os.environ.get("IGNITION_DB_PORT", "5432")),
                        user=os.environ.get("IGNITION_DB_ROOT_USER", "postgres"),
                        password=os.environ.get("IGNITION_DB_ROOT_PASSWORD", ""), dbname="postgres", connect_timeout=3).close()
        sys.exit(0)
    except Exception:
        time.sleep(1)
sys.exit("pulsar: postgres did not answer")
PY
}

make_site() {
  site="$1"
  [ -f "$ROOT/sites/$site/site_config.json" ] && return 0
  persona=tenant
  [ "${PULSAR_ROLE:-tenant}" = hub ] && persona=control
  ign new-site "$site" --persona "$persona" --engine pulsar
  if [ -n "${PULSAR_SITE_EXTRA:-}" ]; then
    SITE_DIR="$ROOT/sites/$site" python - <<'PY'
import json, os
path = os.path.join(os.environ["SITE_DIR"], "site_config.json")
conf = json.load(open(path))
conf.update(json.loads(os.environ["PULSAR_SITE_EXTRA"]))
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(conf, fh, indent=1)
os.replace(tmp, path)
PY
  fi
}

first_site() {
  for d in "$ROOT"/sites/*/; do
    [ -f "${d}site_config.json" ] && grep -q '"pulsar_engine"' "${d}site_config.json" && {
      basename "$d"
      return 0
    }
  done
  return 1
}

cmd="${1:-serve}"
case "$cmd" in
serve | worker | scheduler)
  shift || true
  wait_db
  [ -n "${PULSAR_SITE:-}" ] && make_site "$PULSAR_SITE"
  if [ -z "${IGNITION_SITE:-}" ]; then
    until site="$(first_site)"; do sleep 5; done
    # serve with no IGNITION_SITE serves every site by Host header (a shared tenant docker);
    # worker and scheduler run one site
    if [ "$cmd" != serve ]; then
      IGNITION_SITE="$site"
      export IGNITION_SITE
    fi
  fi
  if [ -z "${IGNITION_ADMIN_PASSWORD:-}" ] && [ -z "${IGNITION_API_TOKEN:-}" ]; then
    # a tenant docker that the server agent fills has no env login; serve still needs one, so it gets a
    # random token nobody knows (logins go through the site's stored users, set by new-site)
    IGNITION_API_TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
    export IGNITION_API_TOKEN
  fi
  # Sticks engine (tenant dockers only): started next to serve when the image carries it and STICKS_TENANT is set.
  if [ "$cmd" = serve ] && [ -n "${STICKS_TENANT:-}" ] && [ -f "${STICKS_ENGINE:-/nonexistent}" ]; then
    node "$STICKS_ENGINE" >>"$ROOT/logs/sticks-engine.log" 2>&1 &
  fi
  case "$cmd" in
  serve) exec python -m pulsar.ignition --root "$ROOT" serve --engine pulsar --host 0.0.0.0 --port "${PULSAR_PORT:-8000}" "$@" ;;
  *) exec python -m pulsar.ignition --root "$ROOT" "$cmd" --engine pulsar "$@" ;;
  esac
  ;;
*)
  exec python -m pulsar.ignition --root "$ROOT" "$@"
  ;;
esac
