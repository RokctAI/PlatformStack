# Copyright (c) 2026 ROKCT INTELLIGENCE (PTY) LTD
# SPDX-License-Identifier: AGPL-3.0-only
#
# hub-mail: our own mail server (Exim4 + DKIM), run by the hub so a new VPS sets up
# mail with no hands-on step. Hub only: never in a tenant image. No Frappe.
# Configured by platform/scripts/exim4_bootstrap.sh (safe to re-run: DKIM keys and
# mail accounts in the volumes are kept).
FROM debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      exim4-daemon-heavy opendkim opendkim-tools openssl ca-certificates curl dnsutils netcat-openbsd \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY scripts/exim4_bootstrap.sh /usr/local/bin/exim4_bootstrap.sh
COPY mail/entrypoint.sh /usr/local/bin/hub-mail-entrypoint.sh
RUN chmod +x /usr/local/bin/exim4_bootstrap.sh /usr/local/bin/hub-mail-entrypoint.sh
VOLUME ["/etc/exim4", "/var/spool/exim4", "/var/log/exim4"]
EXPOSE 25 587
ENTRYPOINT ["/usr/local/bin/hub-mail-entrypoint.sh"]
