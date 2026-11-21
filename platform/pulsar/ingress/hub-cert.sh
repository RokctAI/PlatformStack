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

# hub-cert service (platform/docker-compose.yml): the hub domain's certificate by webroot through rokct-ingress,
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
while :; do
  sleep 43200
  certbot renew -q || true
done
