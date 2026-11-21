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

# Master VPS ingress (platform/docker-compose.yml service ingress, container rokct-ingress). The one owner of 80/443.
# - /etc/nginx/conf.d is the host's: the server agent writes tenant and custom-domain vhosts there
#   (custom-<domain>.conf) and reloads with `docker exec rokct-ingress nginx -s reload`.
# - This script writes 00-hub.conf for SITE_NAME -> HUB_UPSTREAM: HTTP with the ACME webroot until the hub-cert
#   service has a certificate in /etc/letsencrypt/live/SITE_NAME, then HTTPS. It re-checks every 5 minutes and
#   reloads nginx when the file changed, so issued and renewed certificates are picked up.
set -eu
: "${SITE_NAME:?set SITE_NAME}"
UPSTREAM="${HUB_UPSTREAM:-http://app:8000}"
WEBROOT="${ACME_WEBROOT:-/var/www/acme}"
CONF=/etc/nginx/conf.d/00-hub.conf
mkdir -p "$WEBROOT" /etc/nginx/conf.d

render() {
  live="/etc/letsencrypt/live/$SITE_NAME"
  proxy="    location / {
        proxy_pass $UPSTREAM;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 50m;
    }"
  acme="    location ^~ /.well-known/acme-challenge/ { root $WEBROOT; }"
  echo "# managed by rokct-ingress; do not edit"
  # unknown hosts get no site
  echo "server { listen 80 default_server; server_name _;
$acme
    location / { return 444; } }"
  if [ -f "$live/fullchain.pem" ] && [ -f "$live/privkey.pem" ]; then
    echo "server { listen 80; server_name $SITE_NAME;
$acme
    location / { return 301 https://\$host\$request_uri; } }"
    echo "server { listen 443 ssl; server_name $SITE_NAME;
    ssl_certificate $live/fullchain.pem;
    ssl_certificate_key $live/privkey.pem;
$proxy
}"
  else
    echo "server { listen 80; server_name $SITE_NAME;
$acme
$proxy
}"
  fi
}

write() {
  render >"$CONF.new"
  if cmp -s "$CONF.new" "$CONF"; then
    rm -f "$CONF.new"
    return 1
  fi
  mv "$CONF.new" "$CONF"
}

rm -f /etc/nginx/conf.d/default.conf
write || true
(
  while sleep 300; do
    if write && nginx -t >/dev/null 2>&1; then nginx -s reload; fi
    # renewed certificates keep the same paths: reload every 12 hours regardless
    n=$((${n:-0} + 1))
    if [ "$n" -ge 144 ]; then
      n=0
      nginx -s reload
    fi
  done
) &
exec nginx -g 'daemon off;'
