#!/bin/bash
# Copyright (c) 2026 ROKCT INTELLIGENCE (PTY) LTD
# SPDX-License-Identifier: AGPL-3.0-only
#
# Waits for the mail host's certificate (hub-cert issues it), so SMTP AUTH is only
# ever offered over TLS, then configures Exim (exim4_bootstrap.sh) and runs it in
# the foreground. Password guessing is limited by Exim's AUTH ratelimit (10 tries an
# hour per address, acl_check_auth in exim4_bootstrap.sh). A renewed certificate is read per connection, no restart needed.
set -eu
CERT="/etc/letsencrypt/live/${PRIMARY_HOSTNAME}/fullchain.pem"
until [ -f "$CERT" ]; do
  echo "hub-mail: waiting for the certificate of ${PRIMARY_HOSTNAME} (hub-cert issues it once DNS points here)"
  sleep 60
done
SKIP_EXIM=1 SKIP_FAIL2BAN=1 /usr/local/bin/exim4_bootstrap.sh || { echo "hub-mail: bootstrap failed"; exit 1; }
chown -R Debian-exim:Debian-exim /var/spool/exim4 /var/log/exim4 2>/dev/null || true
exec exim -bdf -q30m
