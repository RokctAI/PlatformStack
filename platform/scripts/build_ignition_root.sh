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

# Build an Ignition root: Frappe v16 plus one composed product app (rcore),
# laid out the way Ignition expects (apps/frappe, apps/rcore, sites/apps.txt
# with frappe first). No bench, no database, no Redis: the site is created
# later by `python -m pulsar.ignition new-site` against the real stack.
#
# Used by platform/ignition.Dockerfile (inside the image build) and by hand
# on any machine, e.g. to check a compose before building the image:
#
#   platform/scripts/build_ignition_root.sh --root /tmp/ign-root
#   platform/scripts/build_ignition_root.sh --root /tmp/ign-root --python python3.14
#
# Git auth: MONOREPO_PAT (preferred) or GITHUB_TOKEN from the environment, or
# a file named by --token-file (the image build passes a BuildKit secret this
# way). The token is handed to git through GIT_CONFIG_* environment variables
# of the child processes only. It is never written to a file, a git config,
# a remote URL or the output tree, and never printed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT=""
PRODUCT="${PRODUCT:-rokctapp}"
PROTOCOL_REF="${PROTOCOL_REF:-main}"
PROTOCOL_REPO="${PROTOCOL_REPO:-https://github.com/RokctAI/The-Rokct-Protocol}"
RCORE_REF="${RCORE_REF:-main}"
FRAPPE_REPO="${FRAPPE_REPO:-https://github.com/frappe/frappe}"
FRAPPE_REF="${FRAPPE_REF:-version-16-hotfix}"
PYTHON_BIN=""
TOKEN_FILE=""
COMPOSE_PY="${COMPOSE_PY:-$SCRIPT_DIR/compose_product.py}"

usage() {
  cat <<'EOF'
Usage: build_ignition_root.sh --root DIR [options]

  --root DIR            Ignition root to create (must not contain apps/rcore yet)
  --product NAME        compose template (default rokctapp)
  --protocol-ref REF    The-Rokct-Protocol ref (default main; pin a SHA for releases)
  --protocol-repo URL   protocol repository (default RokctAI/The-Rokct-Protocol;
                        a file:// clone lets you test a template change)
  --rcore-ref REF       rcore shell ref (default main)
  --frappe-ref REF      frappe/frappe ref (default version-16-hotfix)
  --python BIN          also create DIR/env with BIN (Python 3.14 for Frappe v16)
                        and pip install frappe, the composed app and its deps
  --token-file FILE     read the git token from FILE instead of the environment

The compose always runs with ROKCT_COMPOSE_STRICT=1.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --product) PRODUCT="$2"; shift 2 ;;
    --protocol-ref) PROTOCOL_REF="$2"; shift 2 ;;
    --protocol-repo) PROTOCOL_REPO="$2"; shift 2 ;;
    --rcore-ref) RCORE_REF="$2"; shift 2 ;;
    --frappe-ref) FRAPPE_REF="$2"; shift 2 ;;
    --python) PYTHON_BIN="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$ROOT" ] || { usage >&2; exit 2; }

log() { echo "[ignition-root] $*"; }
die() { echo "[ignition-root] ERROR: $*" >&2; exit 1; }

# --- git token (never echoed) -------------------------------------------------
TOKEN=""
if [ -n "$TOKEN_FILE" ]; then
  if [ -s "$TOKEN_FILE" ]; then
    TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
  fi
else
  TOKEN="${MONOREPO_PAT:-${GITHUB_TOKEN:-}}"
fi
[ "$TOKEN" = "***" ] && TOKEN=""
if [ -n "$TOKEN" ]; then
  log "git token: present"
else
  log "git token: absent (public clones only; private module repos will fail)"
fi

# Run a command with the token available to git through the environment only.
with_git_auth() {
  if [ -n "$TOKEN" ]; then
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="url.https://x-access-token:${TOKEN}@github.com/.insteadOf" \
    GIT_CONFIG_VALUE_0="https://github.com/" \
    MONOREPO_PAT="$TOKEN" \
      "$@"
  else
    env -u MONOREPO_PAT -u GITHUB_TOKEN "$@"
  fi
}

ROOT="$(mkdir -p "$ROOT" && cd "$ROOT" && pwd)"
APPS="$ROOT/apps"
SITES="$ROOT/sites"
[ -e "$APPS/rcore" ] && die "$APPS/rcore already exists; use a fresh root"
[ -e "$APPS/frappe" ] && die "$APPS/frappe already exists; use a fresh root"
mkdir -p "$APPS" "$SITES" "$ROOT/logs" "$ROOT/backups" "$ROOT/.rokct/config"

# --- 1. compose the product app straight into apps/rcore ------------------------
log "composing product '$PRODUCT' (protocol $PROTOCOL_REF, shell $RCORE_REF), strict"
with_git_auth env ROKCT_COMPOSE_STRICT=1 python3 "$COMPOSE_PY" \
  --product "$PRODUCT" \
  --protocol-repo "$PROTOCOL_REPO" \
  --protocol-ref "$PROTOCOL_REF" \
  --shell-ref "$RCORE_REF" \
  --output "$APPS/rcore"
[ -f "$APPS/rcore/rcore/modules.txt" ] || die "compose left no rcore/modules.txt"

# The persona marker comes with the composed app (rcore shell = tenant). Copy
# it to the root too, where Ignition writes it on new-site/install-app.
if [ -f "$APPS/rcore/.rokct/config/app_type" ]; then
  cp "$APPS/rcore/.rokct/config/app_type" "$ROOT/.rokct/config/app_type"
  log "persona marker: $(cat "$ROOT/.rokct/config/app_type")"
fi

# --- 2. Frappe v16 ----------------------------------------------------------------
log "cloning frappe $FRAPPE_REPO @ $FRAPPE_REF"
git clone --quiet --depth 1 --branch "$FRAPPE_REF" "$FRAPPE_REPO" "$APPS/frappe"
FRAPPE_SHA="$(git -C "$APPS/frappe" rev-parse HEAD)"
log "frappe resolved to $FRAPPE_SHA"

# --- 3. apps.txt (frappe first) and build provenance --------------------------
printf 'frappe\nrcore\n' > "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

python3 - "$ROOT" "$PRODUCT" "$FRAPPE_REPO" "$FRAPPE_REF" "$FRAPPE_SHA" <<'PY'
import json, os, sys, time
root, product, frepo, fref, fsha = sys.argv[1:6]
with open(os.path.join(root, "apps", "rcore", "composed_provenance.json")) as f:
    composed = json.load(f)
with open(os.path.join(root, "apps", "rcore", "rcore", "modules.txt")) as f:
    modules = [line.strip() for line in f if line.strip()]
out = {
    "product": product,
    "frappe": {"repo": frepo, "ref_requested": fref, "sha": fsha},
    "rcore": composed,
    "rcore_modules": modules,
    "apps_txt": ["frappe", "rcore"],
    "built_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
with open(os.path.join(root, "ignition_build.json"), "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
print("[ignition-root] provenance written: ignition_build.json (%d modules)" % len(modules))
PY

# --- 4. optional: Python env with frappe + rcore installed --------------------
if [ -n "$PYTHON_BIN" ]; then
  log "creating $ROOT/env with $PYTHON_BIN"
  "$PYTHON_BIN" -m venv "$ROOT/env"
  PIP=("$ROOT/env/bin/python" -m pip install --no-cache-dir --disable-pip-version-check)
  "${PIP[@]}" --upgrade pip wheel
  log "pip install -e apps/frappe"
  "${PIP[@]}" -e "$APPS/frappe"
  # Same order Ignition's deps step uses: requirements.txt, then the app.
  if [ -f "$APPS/rcore/requirements.txt" ]; then
    log "pip install -r apps/rcore/requirements.txt"
    with_git_auth "${PIP[@]}" -r "$APPS/rcore/requirements.txt"
  fi
  log "pip install -e apps/rcore"
  with_git_auth "${PIP[@]}" -e "$APPS/rcore"
  log "import check: frappe, rcore"
  (cd "$SITES" && "$ROOT/env/bin/python" -c \
    "import frappe, rcore; print('[ignition-root] frappe', frappe.__version__, '| rcore', getattr(rcore, '__version__', '?'))")
fi

log "done: $ROOT (apps: frappe, rcore)"
