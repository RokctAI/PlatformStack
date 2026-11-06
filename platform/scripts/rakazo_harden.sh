#!/bin/bash
# =============================================================================
# RokctAI - Sticks server (Rakazo) hardening
# Idempotent. Edits the stack's .env only. Never prints secret values.
# Usage: RAKAZO_ENV_FILE=/opt/rakazo/.env [SIGNUP_ALLOWLIST=a@x.com,@corp.com] rakazo_harden.sh
# =============================================================================
set -Eeuo pipefail
umask 077

ENV_FILE="${RAKAZO_ENV_FILE:-.env}"
SIGNUP_ALLOWLIST_VALUE="${SIGNUP_ALLOWLIST:-}"
# 1 = refuse to continue when other workloads share this host (docker socket risk)
STRICT_OWN_HOST="${RAKAZO_STRICT_OWN_HOST:-0}"

[ -f "${ENV_FILE}" ] || { echo "ERROR: env file not found: ${ENV_FILE}" >&2; exit 1; }

# set_kv KEY VALUE: replace an active or commented line, else append.
set_kv() {
  local key="$1" val="$2"
  if grep -qE "^#?[[:space:]]*${key}=" "${ENV_FILE}"; then
    sed -i -E "0,/^#?[[:space:]]*${key}=.*/s||${key}=${val}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${val}" >>"${ENV_FILE}"
  fi
}

# 1. Sign-ups: closed unless an allowlist is given.
if [ -n "${SIGNUP_ALLOWLIST_VALUE}" ]; then
  set_kv SIGNUPS_ENABLED true
  set_kv SIGNUP_ALLOWLIST "${SIGNUP_ALLOWLIST_VALUE}"
  echo "signups: allowlist only"
else
  set_kv SIGNUPS_ENABLED false
  echo "signups: closed"
fi

# 2. Sandbox computers: public-internet egress only (no host/LAN/metadata).
set_kv SANDBOX_COMPUTER_EGRESS restricted
echo "sandbox egress: restricted"

# 3. Never allow plain-http secrets to private hosts.
set_kv RAKAZO_SECRETS_ALLOW_PRIVATE_HTTP 0
echo "private-http secrets: off"

# 4. Required secrets must exist (shape only, values never printed).
for k in BETTER_AUTH_SECRET ENCRYPTION_KEY SANDBOX_SUPERVISOR_TOKEN; do
  if ! grep -qE "^${k}=.+" "${ENV_FILE}"; then
    set_kv "${k}" "$(openssl rand -hex 32)"
    echo "${k}: generated"
  else
    echo "${k}: set"
  fi
done
chmod 600 "${ENV_FILE}"

# 5. Own-host guard: the supervisor mounts the Docker socket, so a sandbox
#    escape owns the host. Warn (or refuse) if other workloads share it.
if command -v docker >/dev/null 2>&1; then
  OTHERS=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -v -i -E 'rakazo|computer' | wc -l || true)
  if [ "${OTHERS:-0}" -gt 0 ]; then
    echo "WARNING: ${OTHERS} non-Rakazo containers share this host; Rakazo's Docker socket makes a sandbox escape a host takeover. Use a separate VPS."
    [ "${STRICT_OWN_HOST}" = "1" ] && { echo "ERROR: RAKAZO_STRICT_OWN_HOST=1, refusing." >&2; exit 2; }
  fi
fi

# 6. Approvals are a per-user setting (not env): remind, cannot force.
echo "NOTE: keep each user's Approvals mode on Ask or Auto, never 'Never ask'; avoid 'Always allow' on our own backend for bots that browse the web."
echo "done"
