#!/bin/bash
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

# Build the Ignition + Frappe v16 + composed product image
# (platform/ignition.Dockerfile, target ignition_rokctapp) and smoke-test it.
#
#   MONOREPO_PAT=... platform/scripts/build_ignition_image.sh --core ../core
#
# The token goes in as a BuildKit secret read from the environment
# (MONOREPO_PAT, else GITHUB_TOKEN); it is never a build arg.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE=""
TAG="ignition-rokctapp:local"
PRODUCT="rokctapp"
PROTOCOL_REF="main"
RCORE_REF="main"
FRAPPE_REF="version-16-hotfix"
SMOKE=1

usage() {
  cat <<'EOF'
Usage: build_ignition_image.sh --core DIR [options]

  --core DIR            RokctAI/core checkout (holds pulsar/ and docker/ignition/bench)
  --tag TAG             image tag (default ignition-rokctapp:local)
  --product NAME        compose template (default rokctapp)
  --protocol-ref REF    The-Rokct-Protocol ref (default main)
  --rcore-ref REF       rcore shell ref (default main)
  --frappe-ref REF      frappe ref (default version-16-hotfix)
  --no-smoke            skip the post-build checks
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --core) CORE="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --product) PRODUCT="$2"; shift 2 ;;
    --protocol-ref) PROTOCOL_REF="$2"; shift 2 ;;
    --rcore-ref) RCORE_REF="$2"; shift 2 ;;
    --frappe-ref) FRAPPE_REF="$2"; shift 2 ;;
    --no-smoke) SMOKE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$CORE" ] || { usage >&2; exit 2; }
[ -d "$CORE/pulsar/pulsar/ignition" ] || { echo "no Ignition under $CORE/pulsar/pulsar" >&2; exit 2; }
[ -f "$CORE/docker/ignition/bench" ] || { echo "no $CORE/docker/ignition/bench" >&2; exit 2; }
command -v docker >/dev/null || { echo "docker is not installed" >&2; exit 3; }
docker info >/dev/null 2>&1 || { echo "docker daemon is not reachable" >&2; exit 3; }

SECRET_ARGS=()
if [ -n "${MONOREPO_PAT:-}" ]; then
  SECRET_ARGS=(--secret "id=git_token,env=MONOREPO_PAT")
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  SECRET_ARGS=(--secret "id=git_token,env=GITHUB_TOKEN")
else
  echo "warning: no MONOREPO_PAT/GITHUB_TOKEN; private repos will fail to clone" >&2
fi

DOCKER_BUILDKIT=1 docker build \
  -f "$REPO_ROOT/platform/ignition.Dockerfile" \
  --build-context "core=$(cd "$CORE" && pwd)" \
  "${SECRET_ARGS[@]}" \
  --build-arg "PRODUCT=$PRODUCT" \
  --build-arg "PROTOCOL_REF=$PROTOCOL_REF" \
  --build-arg "RCORE_REF=$RCORE_REF" \
  --build-arg "FRAPPE_REF=$FRAPPE_REF" \
  --target ignition_rokctapp \
  -t "$TAG" \
  "$REPO_ROOT"

[ "$SMOKE" = 1 ] || exit 0

echo "--- smoke: runner help"
docker run --rm "$TAG" --help >/dev/null
echo "--- smoke: frappe and rcore import, apps.txt has frappe first"
docker run --rm --entrypoint python "$TAG" -c '
import json, frappe, rcore, pulsar.ignition
apps = open("/opt/ignition/sites/apps.txt").read().split()
assert apps[:2] == ["frappe", "rcore"], apps
assert frappe.__version__.startswith("16."), frappe.__version__
b = json.load(open("/opt/ignition/ignition_build.json"))
assert b["frappe"]["patches"] == ["fixtures-duplicate-key", "link-filters-json-list"], b["frappe"]
assert json.load(open("/opt/ignition/sites/common_site_config.json"))["db_type"] == "postgres"
print("frappe", frappe.__version__, b["frappe"]["sha"][:12], "| rcore modules:", " ".join(b["rcore_modules"]))
'
echo "--- smoke: no token in the image"
if docker run --rm --entrypoint sh "$TAG" -c \
    'grep -rIlE "x-access-token:[A-Za-z0-9_]{20,}@" /opt/ignition /opt/pulsar /home/ignition 2>/dev/null | head -n 5' \
    | grep -q .; then
  echo "found x-access-token in the image" >&2
  exit 1
fi
echo "--- smoke: status (bench wrapper)"
docker run --rm --entrypoint bench "$TAG" status
echo "image $TAG ok"
