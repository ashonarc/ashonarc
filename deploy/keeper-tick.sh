#!/bin/sh
# One keeper pass, driven by the systemd timer.
#
# It calls the app port directly rather than going through nginx, which returns
# 404 for /api/cron/ so the endpoint is unreachable from outside the box. The
# response body is printed so `journalctl -u ashonpons-keeper` shows what the
# pass actually did, not merely that it ran.
set -eu
set -a
. /opt/ashonpons/.env
set +a

curl -sS --max-time 300 \
  -H "Authorization: Bearer ${CRON_SECRET:-}" \
  "http://127.0.0.1:${PORT:-8080}/api/cron/keeper"
echo
