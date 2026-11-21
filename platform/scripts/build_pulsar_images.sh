#!/usr/bin/env bash
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

# Build the Pulsar-engine images (platform/pulsar/Dockerfile): pulsar-hub and pulsar-tenant.
# Stages a context with the Pulsar framework (core pulsar/) and every SDK package (<repo>/<pkg>/pulsar) of the repo
# checkouts under PULSAR_SRC (default: the folder that holds PlatformStack), without tests, caches or .git.
#   PULSAR_SRC=/path/to/checkouts TAG=local platform/scripts/build_pulsar_images.sh
# PULSAR_WHEELS=<dir of .whl files> installs the Python dependencies from there instead of PyPI (offline builds).
# Separate from build_ecosystem.sh / the bench images, which it does not touch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${PULSAR_SRC:-$(cd "$HERE/../.." && pwd)}"
TAG="${TAG:-local}"
REPOS="${PULSAR_REPOS:-core control pay corporate zones agent hardware productivity commerce designer Users}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
[ -d "$SRC/core/pulsar/pulsar" ] || { echo "no core checkout at $SRC/core" >&2; exit 1; }
mkdir -p "$STAGE/framework" "$STAGE/sdk"
copy() {  # copy a pulsar/ folder without tests, caches or bytecode
    mkdir -p "$2"
    tar -C "$1" --exclude='__pycache__' --exclude='*.pyc' --exclude='tests' --exclude='cmds_tests' -cf - . | tar -C "$2" -xf -
}
copy "$SRC/core/pulsar" "$STAGE/framework"
for repo in $REPOS; do
    [ -d "$SRC/$repo" ] || { echo "skip $repo (no checkout)"; continue; }
    for pkg in "$SRC/$repo"/*/pulsar; do
        [ -d "$pkg" ] || continue
        rel="${pkg#"$SRC/"}"
        [ "$rel" = "core/pulsar" ] && continue
        copy "$pkg" "$STAGE/sdk/$rel"
    done
done
cp "$HERE/pulsar/Dockerfile" "$HERE/pulsar/entrypoint.sh" "$STAGE/"
mkdir -p "$STAGE/wheels"
if [ -n "${PULSAR_WHEELS:-}" ]; then cp "$PULSAR_WHEELS"/*.whl "$STAGE/wheels/"; fi
for target in pulsar-hub pulsar-tenant; do
    docker build -f "$STAGE/Dockerfile" --target "$target" -t "$target:$TAG" "$STAGE"
done
echo "built pulsar-hub:$TAG pulsar-tenant:$TAG"
