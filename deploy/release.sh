#!/usr/bin/env bash
# Install a new build of the app and restart it. Idempotent; run after every
# push of /tmp/ashonpons-deploy/app.tar.gz.
set -euo pipefail

APP_DIR=/opt/ashonpons
APP_USER=ashonpons
STAGE=/tmp/ashonpons-deploy

log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

log "unpack"
sudo rm -rf "$STAGE/app"
mkdir -p "$STAGE/app"
tar -xzf "$STAGE/app.tar.gz" -C "$STAGE/app"

# Replace the tree wholesale rather than merging into it, so a file deleted in
# the repo also disappears here. node_modules is kept: it is not in the tarball
# and reinstalling it on every release would cost a minute for nothing.
sudo rsync --version >/dev/null 2>&1 || sudo apt-get install -y -qq rsync
sudo rsync -a --delete --exclude node_modules "$STAGE/app/" "$APP_DIR/app/"
sudo chown -R "$APP_USER:$APP_USER" "$APP_DIR/app"

log "dependencies"
cd "$APP_DIR/app"
# `npm ci` needs to write node_modules, so it runs as the owner of the tree.
# -H matters: without it HOME stays /home/ubuntu, npm cannot write its cache
# there, and the install fails on a permission error that says nothing useful.
sudo -u "$APP_USER" -H npm ci --omit=dev --no-audit --no-fund

log "restart"
sudo systemctl enable --now ashonpons.service
sudo systemctl restart ashonpons.service
sudo systemctl enable --now ashonpons-keeper.timer
sleep 2
sudo systemctl --no-pager --lines=0 status ashonpons.service | head -5

log "smoke test"
curl -sS --max-time 30 -o /dev/null -w 'local  /api/health  HTTP %{http_code}\n' http://127.0.0.1:8080/api/health
curl -sS --max-time 30 -o /dev/null -w 'nginx  /            HTTP %{http_code}\n' http://127.0.0.1/
curl -sS --max-time 30 -o /dev/null -w 'nginx  /api/cron/   HTTP %{http_code} (404 expected)\n' http://127.0.0.1/api/cron/keeper

log "done"
