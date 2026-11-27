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

# hub-cert service (platform/docker-compose.yml): the hub domain's certificate (and the mail host's) by webroot through rokct-ingress,
# retried every 10 minutes until DNS points here, then `certbot renew` twice a day. rokct-ingress picks it up.
set -eu
: "${SITE_NAME:?set SITE_NAME}"
if [ -n "${LETSENCRYPT_EMAIL:-}" ]; then
  who="--email $LETSENCRYPT_EMAIL"
else
  who="--register-unsafely-without-email"
fi
# shellcheck disable=SC2086
until certbot certonly --webroot -w /var/www/acme --non-interactive --agree-tos --keep-until-expiring \
  --cert-name "$SITE_NAME" -d "$SITE_NAME" $who; do
  sleep 600
done
# The mail host's certificate (hub-mail offers SMTP AUTH over TLS only), same webroot: the ingress answers ACME
# challenges for any name pointed here. Tried every 10 minutes until its DNS points here, without holding up
# the hub certificate's renewals.
mail_cert() {
  [ -n "${MAIL_HOSTNAME:-}" ] && [ ! -f "/etc/letsencrypt/live/$MAIL_HOSTNAME/fullchain.pem" ] || return 0
  # shellcheck disable=SC2086
  certbot certonly --webroot -w /var/www/acme --non-interactive --agree-tos --keep-until-expiring \
    --cert-name "$MAIL_HOSTNAME" -d "$MAIL_HOSTNAME" $who || true
}
# Next.js site certificates (platform/sites/routes.list), same webroot; each tried until its DNS points here.
site_certs() {
  [ -f /rokct/routes.list ] || return 0
  grep -v '^#' /rokct/routes.list | while read -r dom _; do
    [ -n "$dom" ] && [ ! -f "/etc/letsencrypt/live/$dom/fullchain.pem" ] || continue
    # shellcheck disable=SC2086
    certbot certonly --webroot -w /var/www/acme --non-interactive --agree-tos --keep-until-expiring \
      --cert-name "$dom" -d "$dom" $who || true
  done
}
n=0
while :; do
  mail_cert
  site_certs
  sleep 600
  n=$((n + 1))
  if [ "$n" -ge 72 ]; then
    n=0
    certbot renew -q || true
  fi
done
