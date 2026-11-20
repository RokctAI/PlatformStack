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

# Tenant mode of the Ignition image: the Ignition equivalent of MODE=api in
# platform/docker-entrypoint.sh (the bench image). Run as `tenant` through
# ignition-entrypoint, which has already put apps.txt and the default
# common_site_config.json in place.
#
#   1. wait for the database
#   2. write the stack keys (db_host, redis_*, default_site) into
#      sites/common_site_config.json
#   3. create the Postgres extensions rcore needs (cube, earthdistance, vector)
#      in template1, so the new site database inherits them
#   4. new-site SITE_NAME (persona tenant) when the sites volume has none, then
#      migrate on every later start
#   5. set app_role, link ~/.rok into the site's private folder
#   6. run serve, worker and scheduler, and exit when any of them exits
#
# Inputs (same names the tenant compose file already passes to the bench image):
#   SITE_NAME, DB_HOST, DB_PORT, DB_PASSWORD (postgres superuser password),
#   ADMIN_PASSWORD, INSTALL_APPS, REDIS_CACHE, REDIS_QUEUE, REDIS_SOCKETIO,
#   APP_ROLE (default tenant), DB_ROOT_USER (default postgres).
# No secret is ever printed.
set -eu
umask 027

: "${SITE_NAME:?SITE_NAME is required}"
IGNITION_ROOT="${IGNITION_ROOT:-/opt/ignition}"
SITES="$IGNITION_ROOT/sites"
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_ROOT_USER="${DB_ROOT_USER:-postgres}"
APP_ROLE="${APP_ROLE:-tenant}"

export IGNITION_ADMIN_PASSWORD="${IGNITION_ADMIN_PASSWORD:-${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}}"
export IGNITION_DB_ROOT_PASSWORD="${IGNITION_DB_ROOT_PASSWORD:-${DB_ROOT_PASSWORD:-${DB_PASSWORD:?DB_PASSWORD is required}}}"
export IGNITION_DB_ROOT_USER="${IGNITION_DB_ROOT_USER:-$DB_ROOT_USER}"

echo "Ignition tenant starting (site $SITE_NAME)"

# 1. Database wait (bounded, 120 s)
tries=0
until PGPASSWORD="$IGNITION_DB_ROOT_PASSWORD" pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ROOT_USER" >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge 60 ]; then
    echo "Database at $DB_HOST:$DB_PORT not ready after 120 s" >&2
    exit 1
  fi
  sleep 2
done

# 2. Stack keys into common_site_config.json (merge, keep everything else)
SITES="$SITES" python - <<'PY'
import json, os
path = os.path.join(os.environ["SITES"], "common_site_config.json")
try:
    with open(path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
cfg.setdefault("db_type", os.environ.get("IGNITION_DB_TYPE", "postgres"))
cfg["db_host"] = os.environ["DB_HOST"]
cfg["db_port"] = int(os.environ["DB_PORT"])
cfg["default_site"] = os.environ["SITE_NAME"]
for key, env in (("redis_cache", "REDIS_CACHE"), ("redis_queue", "REDIS_QUEUE"), ("redis_socketio", "REDIS_SOCKETIO")):
    if os.environ.get(env):
        cfg[key] = os.environ[env]
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=1)
os.replace(tmp, path)
PY

# 3. Extensions in template1 (the stack must create them as superuser; rcore's after_install only warns)
for ext in cube earthdistance vector; do
  PGPASSWORD="$IGNITION_DB_ROOT_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ROOT_USER" -d template1 \
    -c "CREATE EXTENSION IF NOT EXISTS $ext;" >/dev/null 2>&1 ||
    echo "Warning: extension $ext not created in template1"
done

# 4. Site
if [ ! -f "$SITES/$SITE_NAME/site_config.json" ]; then
  echo "Creating site $SITE_NAME"
  apps="rcore"
  for a in ${INSTALL_APPS:-}; do
    case " $apps " in *" $a "*) ;; *) apps="$apps $a" ;; esac
  done
  # shellcheck disable=SC2086 # apps is a short space separated list of app names
  python -m pulsar.ignition new-site "$SITE_NAME" --persona tenant --apps $apps
else
  echo "Site $SITE_NAME exists, migrating"
  python -m pulsar.ignition migrate "$SITE_NAME"
fi

# 5. Role and ROK persistence
python - <<'PY'
import json, os
path = os.path.join(os.environ["SITES"], os.environ["SITE_NAME"], "site_config.json")
with open(path) as f:
    cfg = json.load(f)
cfg["app_role"] = os.environ["APP_ROLE"]
if os.environ.get("EMAIL_ENCRYPTION_KEY"):
    cfg.setdefault("email_encryption_key", os.environ["EMAIL_ENCRYPTION_KEY"])
tmp = path + ".tmp"
with open(tmp, "w", opener=lambda p, fl: os.open(p, fl, 0o600)) as f:
    json.dump(cfg, f, indent=1)
os.replace(tmp, path)
PY
mkdir -p "$SITES/$SITE_NAME/private/rok"
if [ ! -L "$HOME/.rok" ]; then
  rm -rf "$HOME/.rok" 2>/dev/null || true
  ln -sfn "$SITES/$SITE_NAME/private/rok" "$HOME/.rok" || true
fi

# 6. Processes. serve is PID-wise a child so one exit stops the container
# (compose restarts it), as the bench api mode does.
python -m pulsar.ignition worker &
W=$!
python -m pulsar.ignition scheduler &
S=$!
python -m pulsar.ignition serve --port 8000 &
V=$!
trap 'kill $W $S $V 2>/dev/null || true' TERM INT
code=0
while kill -0 "$W" 2>/dev/null && kill -0 "$S" 2>/dev/null && kill -0 "$V" 2>/dev/null; do
  sleep 2
done
for p in $W $S $V; do
  kill -0 "$p" 2>/dev/null || { wait "$p" || code=$?; echo "Process $p exited with code $code, stopping"; }
done
kill $W $S $V 2>/dev/null || true
exit "${code:-1}"
