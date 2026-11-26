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
# PULSAR_STAGE_ONLY=<dir> stages the context into <dir> and stops (CI builds it with docker/build-push-action).
# PULSAR_WHEELS=<dir of .whl files> installs the Python dependencies from there instead of PyPI (offline builds).
# Separate from build_ecosystem.sh / the bench images, which it does not touch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${PULSAR_SRC:-$(cd "$HERE/../.." && pwd)}"
TAG="${TAG:-local}"
REPOS="${PULSAR_REPOS:-core control pay corporate zones agent hardware productivity commerce designer Users}"
if [ -n "${PULSAR_STAGE_ONLY:-}" ]; then
  STAGE="$PULSAR_STAGE_ONLY"
  mkdir -p "$STAGE"
else
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
fi
[ -d "$SRC/core/pulsar/pulsar" ] || {
  echo "no core checkout at $SRC/core" >&2
  exit 1
}
mkdir -p "$STAGE/framework" "$STAGE/sdk"
copy() { # copy a pulsar/ folder without tests, caches or bytecode
  mkdir -p "$2"
  tar -C "$1" --exclude='frappe' --exclude='__pycache__' --exclude='*.pyc' --exclude='tests' --exclude='cmds_tests' -cf - . | tar -C "$2" -xf -
}
copy "$SRC/core/pulsar" "$STAGE/framework"
for repo in $REPOS; do
  [ -d "$SRC/$repo" ] || {
    echo "skip $repo (no checkout)"
    continue
  }
  for pkg in "$SRC/$repo"/*/pulsar; do
    [ -d "$pkg" ] || continue
    rel="${pkg#"$SRC/"}"
    [ "$rel" = "core/pulsar/pulsar" ] && continue
    copy "$pkg" "$STAGE/sdk/$rel"
  done
done
# Pulsar never depends on frappe/: nothing named frappe/ is staged, and no staged module may import frappe.
# refuse a stage that holds a frappe/ folder or really imports frappe (parsed, so a docstring that says
# "from frappe.session" is not an import)
no_frappe_imports() {
  python3 - "$1" <<'PY'
import ast, pathlib, sys
bad = []
for f in pathlib.Path(sys.argv[1]).rglob("*.py"):
    try:
        tree = ast.parse(f.read_text(encoding="utf-8", errors="replace"))
    except SyntaxError:
        continue
    for n in ast.walk(tree):
        names = [a.name for a in n.names] if isinstance(n, ast.Import) else [n.module or ""] if isinstance(n, ast.ImportFrom) and n.level == 0 else []
        if any(m == "frappe" or m.startswith("frappe.") for m in names):
            bad.append(f"{f}:{n.lineno}")
print("\n".join(bad), file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}
if find "$STAGE" -type d -name frappe | grep -q . || ! no_frappe_imports "$STAGE"; then
  echo "pulsar stage contains frappe/ or a frappe import: refusing to build" >&2
  exit 1
fi
cp "$HERE/pulsar/Dockerfile" "$HERE/pulsar/entrypoint.sh" "$STAGE/"
mkdir -p "$STAGE/wheels"
if [ -n "${PULSAR_WHEELS:-}" ]; then cp "$PULSAR_WHEELS"/*.whl "$STAGE/wheels/"; fi
if [ -n "${PULSAR_STAGE_ONLY:-}" ]; then
  echo "staged $STAGE"
  exit 0
fi
for target in pulsar-hub pulsar-tenant pulsar-supacharge pulsar-drone; do
  docker build -f "$STAGE/Dockerfile" --target "$target" -t "$target:$TAG" "$STAGE"
done
echo "built pulsar-hub:$TAG pulsar-tenant:$TAG pulsar-supacharge:$TAG pulsar-drone:$TAG"
