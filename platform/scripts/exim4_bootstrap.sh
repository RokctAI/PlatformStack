#!/bin/bash
# =============================================================================
# RokctAI - Exim4 Bootstrap Configuration
# Safe fresh-VPS bootstrap for Exim4
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# COLORS
# =============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

step() { printf "${BLUE}  - %s... ${NC}" "$1"; }
done_ok() { echo -e "${GREEN}✓ DONE${NC}"; }
fail() {
  echo -e "${RED}✗ FAILED: $1${NC}"
  exit 1
}

# =============================================================================
# ENVIRONMENT VARIABLES
# =============================================================================

PRIMARY_HOSTNAME="${PRIMARY_HOSTNAME:-mail.juvo.app}"
FORCE_REGEN_DKIM="${FORCE_REGEN_DKIM:-0}"

MAIL_DOMAINS="${MAIL_DOMAINS:-juvo.app rokct.ai}"

FORWARD_TO="${FORWARD_TO:-sinyage@gmail.com}"

TLS_CERT="${TLS_CERT:-/etc/letsencrypt/live/${PRIMARY_HOSTNAME}/fullchain.pem}"
TLS_KEY="${TLS_KEY:-/etc/letsencrypt/live/${PRIMARY_HOSTNAME}/privkey.pem}"

DKIM_BASE="${DKIM_BASE:-/etc/exim4/dkim}"
DKIM_SELECTOR="${DKIM_SELECTOR:-dkim}"

SMTP_AUTH_USER="${SMTP_AUTH_USER:-hello@juvo.app}"
SMTP_AUTH_PASS="${SMTP_AUTH_PASS:-}"

EXIM_USER="${EXIM_USER:-Debian-exim}"

SKIP_EXIM="${SKIP_EXIM:-0}"

# Logging setup
LOG_FILE="/var/log/exim4_bootstrap.log"
exec > >(tee -a "${LOG_FILE}") 2>&1 || true

# =============================================================================
# 1. LOCAL MACROS
# =============================================================================

step "Writing local macros"

cat >/etc/exim4/conf.d/main/00_local_macros <<EOF
primary_hostname = ${PRIMARY_HOSTNAME}
daemon_smtp_ports = 25 : 587
DKIM_SELECTOR = ${DKIM_SELECTOR}
tls_require_ciphers = ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384
acl_smtp_auth = acl_check_auth
EOF

done_ok

# =============================================================================
# 2. SET SYSTEM HOSTNAME
# =============================================================================

step "Setting system hostname"

hostnamectl set-hostname "${PRIMARY_HOSTNAME}"

if grep -q "^127\.0\.1\.1" /etc/hosts; then
  sed -i "s/^127\.0\.1\.1.*$/127\.0\.1\.1 ${PRIMARY_HOSTNAME}/" /etc/hosts
else
  echo "127.0.1.1 ${PRIMARY_HOSTNAME}" >> /etc/hosts
fi

echo "${PRIMARY_HOSTNAME}" > /etc/mailname

done_ok

# =============================================================================
# 3. TLS OPTIONS
# =============================================================================

step "Configuring TLS"

mkdir -p /etc/exim4/conf.d/main

# Verify TLS cert files exist
if [ ! -f "${TLS_CERT}" ]; then
  echo -e "${YELLOW}  TLS cert not found at ${TLS_CERT} - run certbot first${NC}"
  TLS_CERT_EXISTS=0
else
  TLS_CERT_EXISTS=1
fi

cat >/etc/exim4/conf.d/main/01_tls_paths <<EOF
tls_certificate = ${TLS_CERT}
tls_privatekey = ${TLS_KEY}
tls_advertise_hosts = *
EOF

sed -i 's/^tls_certificate = MAIN_TLS_CERT/#tls_certificate = MAIN_TLS_CERT/' /etc/exim4/conf.d/main/03_exim4-config_tlsoptions

done_ok

# =============================================================================
# 4. LETSENCRYPT PERMISSIONS
# =============================================================================

step "Fixing certificate permissions"

chgrp -R "${EXIM_USER}" /etc/letsencrypt/live /etc/letsencrypt/archive
chmod 750 /etc/letsencrypt/live /etc/letsencrypt/archive

done_ok

# =============================================================================
# 5. STARTTLS ACL
# =============================================================================

step "Configuring STARTTLS ACL"

cat >/etc/exim4/conf.d/main/01_starttls_acl <<'EOF'
acl_smtp_starttls = acl_check_starttls
EOF

cat >/etc/exim4/conf.d/acl/30_exim4-config_starttls <<'EOF'
acl_check_starttls:
  accept
EOF

done_ok

# =============================================================================
# 6. SMTP AUTH
# =============================================================================

step "Configuring SMTP AUTH"

cat >/etc/exim4/conf.d/auth/10_server_auth <<'EOF'
plain_server:
  driver = plaintext
  public_name = PLAIN
  server_prompts = :
  server_condition = ${if crypteq{$auth3}{${extract{2}{:}{${lookup{$auth2}lsearch{/etc/exim4/passwd}{$value}fail}}}}{yes}{no}}
  server_set_id = $auth2
  server_advertise_condition = ${if def:tls_in_cipher}

login_server:
  driver = plaintext
  public_name = LOGIN
  server_prompts = Username:: : Password::
  server_condition = ${if crypteq{$auth2}{${extract{2}{:}{${lookup{$auth1}lsearch{/etc/exim4/passwd}{$value}fail}}}}{yes}{no}}
  server_set_id = $auth1
  server_advertise_condition = ${if def:tls_in_cipher}
EOF

done_ok

# =============================================================================
# 7. SMTP AUTH PASSWORD FILE
# =============================================================================

step "Creating SMTP password file"

if [ -n "${SMTP_AUTH_PASS}" ]; then
  HASHED_PASS=$(openssl passwd -6 "${SMTP_AUTH_PASS}")
  cat >/etc/exim4/passwd <<EOF
${SMTP_AUTH_USER}:${HASHED_PASS}
EOF
fi

if [ -f /etc/exim4/passwd ]; then
  chown root:${EXIM_USER} /etc/exim4/passwd
  chmod 640 /etc/exim4/passwd
fi

done_ok

# =============================================================================
# 8. CHECK DEPENDENCIES
# =============================================================================

step "Checking system dependencies"

for cmd in curl dig nc; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    NEED_INSTALL=1
    break
  fi
done

if [ "${NEED_INSTALL:-0}" = "1" ]; then
  apt-get update && apt-get install -y curl dnsutils netcat-openbsd
fi

done_ok

# =============================================================================
# 9. RATE LIMITING FOR AUTH
# =============================================================================

step "Configuring rate limiting for auth"

cat >/etc/exim4/conf.d/acl/50_exim4-config_rate_limit <<'EOF'
# Rate limit authentication attempts
acl_check_auth:
  deny
    ratelimit = 10 / 1h / strict / $sender_host_address
    log_message = AUTH rate limit exceeded
EOF

done_ok

# =============================================================================
# 10. DKIM KEYS
# =============================================================================

step "Generating DKIM keys"

mkdir -p "${DKIM_BASE}"

for domain in ${MAIL_DOMAINS}; do
  DOMAIN_DIR="${DKIM_BASE}/${domain}"
  mkdir -p "${DOMAIN_DIR}"

  PRIVATE_KEY="${DOMAIN_DIR}/mail.private"
  PUBLIC_KEY="${DOMAIN_DIR}/mail.public"

  if [ ! -f "${PRIVATE_KEY}" ] || [ "${FORCE_REGEN_DKIM}" = "1" ]; then
    openssl genrsa -out "${PRIVATE_KEY}" 2048 >/dev/null 2>&1
    openssl rsa -in "${PRIVATE_KEY}" -pubout -out "${PUBLIC_KEY}" >/dev/null 2>&1
  fi

  PUBKEY=$(openssl rsa -in "${PRIVATE_KEY}" -pubout 2>/dev/null | grep -v "\-----" | tr -d '\n')

  cat >"${DOMAIN_DIR}/dns_record.txt" <<EOF
${DKIM_SELECTOR}._domainkey.${domain}. TXT "v=DKIM1; k=rsa; p=${PUBKEY}"
EOF

  chown -R "${EXIM_USER}" "${DOMAIN_DIR}"
  chmod 640 "${PRIVATE_KEY}"
  chmod 644 "${PUBLIC_KEY}"
done

done_ok

# =============================================================================
# 11. DKIM LOOKUP FILE
# =============================================================================

step "Writing DKIM lookup file"

>/etc/exim4/dkim_keys
for domain in ${MAIL_DOMAINS}; do
  echo "${domain}: ${DKIM_BASE}/${domain}/mail.private" >>/etc/exim4/dkim_keys
done

chown root:"${EXIM_USER}" /etc/exim4/dkim_keys
chmod 640 /etc/exim4/dkim_keys

done_ok

# =============================================================================
# 12. DKIM TRANSPORT
# =============================================================================

step "Creating DKIM transport"

cat >/etc/exim4/conf.d/transport/32_dkim_transport <<EOF
remote_smtp_dkim:
  driver = smtp
  dkim_domain = \${lookup{\$sender_address_domain}lsearch{/etc/exim4/dkim_keys}{\$sender_address_domain}{}}
  dkim_selector = DKIM_SELECTOR
  dkim_private_key = \${lookup{\$sender_address_domain}lsearch{/etc/exim4/dkim_keys}{\$value}{0}}
  dkim_canon = relaxed
EOF

done_ok

# =============================================================================
# 13. ROUTER PATCH
# =============================================================================

step "Patching primary router"

ROUTER_FILE="/etc/exim4/conf.d/router/200_exim4-config_primary"

if ! grep -q "transport = remote_smtp_dkim" "${ROUTER_FILE}"; then
  sed -i 's/transport = remote_smtp/transport = remote_smtp_dkim/g' "${ROUTER_FILE}"
fi

done_ok

# =============================================================================
# 14. CATCHALL FORWARD
# =============================================================================

step "Configuring catchall forwarding"

DOMAIN_LIST=$(echo "${MAIL_DOMAINS}" | tr ' ' ':')

cat >/etc/exim4/conf.d/router/850_exim4-config_catch_all_forward <<EOF
catch_all_forward:
  driver = redirect
  domains = ${DOMAIN_LIST}
  data = ${FORWARD_TO}
  unseen
  no_verify
EOF

done_ok

# =============================================================================
# 15. POSTMASTER/ABUSE ALIASES
# =============================================================================

step "Creating postmaster/abuse aliases"

cat >/etc/exim4/conf.d/router/860_postmaster_abuse <<EOF
postmaster_alias:
  driver = redirect
  local_parts = postmaster
  domains = +local_domains
  data = ${FORWARD_TO}
  file_transport = address_file

abuse_alias:
  driver = redirect
  local_parts = abuse
  domains = +local_domains
  data = ${FORWARD_TO}
EOF

done_ok

# =============================================================================
# 16. UPDATE-EXIM4.CONF.CONF
# =============================================================================

step "Updating update-exim4.conf.conf"

OTHER_HOSTNAMES=$(echo "${MAIL_DOMAINS}" | tr ' ' ':')
OTHER_HOSTNAMES="${PRIMARY_HOSTNAME}:${OTHER_HOSTNAMES}"

cat >/etc/exim4/update-exim4.conf.conf <<EOF
dc_eximconfig_configtype='internet'
dc_other_hostnames='${OTHER_HOSTNAMES}'
dc_local_interfaces='0.0.0.0 ; ::0'
dc_readhost=''
dc_relay_domains=''
dc_minimaldns='false'
dc_relay_nets=''
dc_smarthost=''
CFILEMODE='644'
dc_use_split_config='true'
dc_hide_mailname=''
dc_mailname_in_oh='true'
dc_localdelivery='mail_spool'
EOF

done_ok

# =============================================================================
# 17. REBUILD AND VALIDATE
# =============================================================================

step "Rebuilding and validating Exim configuration"

update-exim4.conf || fail "update-exim4.conf failed"
exim -bV >/dev/null 2>&1 || fail "exim -bV failed"
exim -C /var/lib/exim4/config.autogenerated -bV >/dev/null 2>&1 || fail "exim autogenerated config validation failed"
exim -bP primary_hostname | grep -q "${PRIMARY_HOSTNAME}" || fail "primary_hostname validation failed"
exim -bP authenticators | grep -q "plain_server" || fail "authenticators validation failed"

done_ok

# =============================================================================
# 18. CHECK REVERSE DNS
# =============================================================================

step "Checking reverse DNS"

PUBLIC_IP=$(curl -s https://api.ipify.org)
PTR_RECORD=$(dig +short -x "${PUBLIC_IP}" 2>/dev/null | sed 's/\.$//' | tr -d '\n')

if [ "${PTR_RECORD}" = "${PRIMARY_HOSTNAME}" ]; then
  echo -e "${GREEN}✓ PTR: ${PTR_RECORD}${NC}"
  PTR_STATUS="${GREEN}✓ OK${NC}"
else
  echo -e "${YELLOW}⚠ PTR mismatch: expected ${PRIMARY_HOSTNAME}, got '${PTR_RECORD}'${NC}"
  echo -e "${YELLOW}  Set PTR record in VPS provider control panel${NC}"
  PTR_STATUS="${RED}✗ MISMATCH${NC}"
fi

done_ok

# =============================================================================
# 19. CHECK PORT 25
# =============================================================================

step "Checking port 25 connectivity"

if timeout 10 bash -c "echo QUIT | nc -w 5 gmail-smtp-in.l.google.com 25" 2>/dev/null | grep -q "220"; then
  echo -e "${GREEN}✓ Port 25 reachable${NC}"
  PORT25_STATUS="${GREEN}✓ OK${NC}"
else
  echo -e "${YELLOW}⚠ Port 25 may be blocked (common on OVH, requires support ticket)${NC}"
  PORT25_STATUS="${RED}✗ BLOCKED?${NC}"
fi

done_ok

# =============================================================================
# 20. FAIL2BAN SETUP
# =============================================================================

step "Installing Fail2ban for Exim"

if command -v apt-get >/dev/null 2>&1; then
  apt-get install -y fail2ban
fi

cat >/etc/fail2ban/jail.d/exim4.conf <<'EOF'
[exim4-auth]
enabled = true
port = smtp,587
filter = exim4
logpath = /var/log/exim4/mainlog
maxretry = 5
bantime = 3600
findtime = 3600
EOF

cat >/etc/fail2ban/filter.d/exim4.conf <<'EOF'
[Definition]
failregex = .*auth.*login.*failed.*
ignoreregex =
EOF

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart fail2ban || true
fi

done_ok

# =============================================================================
# 21. START EXIM
# =============================================================================

if [ "${SKIP_EXIM}" = "1" ]; then
  echo -e "${BLUE}  - SKIP_EXIM=1, skipping restart${NC}"
else
  step "Restarting Exim"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart exim4 || fail "systemctl restart exim4 failed"
  else
    service exim4 restart || fail "service exim4 restart failed"
  fi
  done_ok
fi

# =============================================================================
# 22. PRINT DNS RECORDS
# =============================================================================

echo ""
echo -e "${GREEN}=== DNS RECORDS TO CONFIGURE ===${NC}"

for domain in ${MAIL_DOMAINS}; do
  if [ -f "${DKIM_BASE}/${domain}/dns_record.txt" ]; then
    echo -e "${BLUE}${domain}:${NC}"
    cat "${DKIM_BASE}/${domain}/dns_record.txt"
    echo ""
  fi
done

echo -e "${BLUE}SPF:${NC}"
echo -e "  ${PRIMARY_HOSTNAME}. TXT \"v=spf1 a mx ip4:${PUBLIC_IP} ~all\""
echo ""

echo -e "${BLUE}DMARC:${NC}"
echo -e "  _dmarc.${PRIMARY_HOSTNAME}. TXT \"v=DMARC1; p=quarantine; rua=mailto:${FORWARD_TO}; fo=1\""
echo ""

# =============================================================================
# 23. SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   CONFIGURATION SUMMARY${NC}"
echo -e "${GREEN}========================================${NC}"
if [ "$(hostname -f 2>/dev/null || hostname)" = "${PRIMARY_HOSTNAME}" ]; then
  echo -e "  Hostname:    ${GREEN}✓ ${PRIMARY_HOSTNAME}${NC}"
else
  echo -e "  Hostname:    ${RED}✗ MISMATCH${NC}"
fi
echo -e "  PTR Record:  ${PTR_STATUS}"
if [ "${TLS_CERT_EXISTS}" = "1" ]; then
  echo -e "  TLS Cert:    ${GREEN}✓ ${TLS_CERT}${NC}"
else
  echo -e "  TLS Cert:    ${YELLOW}✗ NOT FOUND${NC}"
fi
echo -e "  DKIM Keys:   ${GREEN}✓ Generated${NC}"
echo -e "  Port 25:     ${PORT25_STATUS}"
echo -e "${GREEN}========================================${NC}"

echo -e "${GREEN}Configuration Complete.${NC}"