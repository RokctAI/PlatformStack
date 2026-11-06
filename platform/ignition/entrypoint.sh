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

# Entrypoint of the Ignition + Frappe v16 + composed app image
# (platform/ignition.Dockerfile). sites/ is a volume, so the app list baked
# into the image is put back into sites/apps.txt on every start: baked apps
# first, in baked order (frappe first), then any other app already listed.
# Then the Ignition runner runs with the given arguments (serve, worker,
# scheduler, new-site, migrate, backup, restore, ...).
set -eu
umask 027

IGNITION_ROOT="${IGNITION_ROOT:-/opt/ignition}"
IGNITION_HOST="${IGNITION_HOST:-0.0.0.0}"
export IGNITION_ROOT IGNITION_HOST

SITES="$IGNITION_ROOT/sites"
BAKED="$IGNITION_ROOT/apps.baked.txt"
APPS_TXT="$SITES/apps.txt"

if [ -f "$BAKED" ] && [ -d "$SITES" ] && [ -w "$SITES" ]; then
  tmp="$SITES/.apps.txt.$$"
  {
    cat "$BAKED"
    if [ -f "$APPS_TXT" ]; then
      grep -vxF -f "$BAKED" "$APPS_TXT" | grep -v '^[[:space:]]*$' || true
    fi
  } > "$tmp"
  mv "$tmp" "$APPS_TXT"
  [ -f "$SITES/common_site_config.json" ] || printf '{}\n' > "$SITES/common_site_config.json"
fi

exec python -m pulsar.ignition "$@"
