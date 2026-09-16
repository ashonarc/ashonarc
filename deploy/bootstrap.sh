#!/usr/bin/env bash
# One-time provisioning for the AshonPons box. Idempotent: safe to re-run.
# Expects to run as a sudo-capable user on Ubuntu 24.04.
set -euo pipefail

APP_DIR=/opt/ashonpons
APP_USER=ashonpons
NODE_MAJOR=22
STAGE=/tmp/ashonpons-deploy

log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# A freshly booted cloud image is usually still running unattended-upgrades,
# and apt fails outright rather than waiting for the lock.
wait_for_apt() {
  for _ in $(seq 1 60); do
    if ! sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  echo "apt lock still held after five minutes" >&2
  return 1
}

log "swap"
# 911 MB of RAM, and npm's resolver alone can spike past that.
if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
  sudo fallocate -l 1G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
free -m | sed -n '1,3p'

log "packages"
export DEBIAN_FRONTEND=noninteractive
wait_for_apt
sudo -E apt-get update -qq
sudo -E apt-get install -y -qq ca-certificates curl gnupg nginx

log "node ${NODE_MAJOR}"
# The apt repo rather than piping NodeSource's setup script into a shell: this
# way every package is checked against a pinned signing key, and security
# updates arrive through the normal channel.
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
  sudo install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | sudo gpg --dearmor --yes -o /usr/share/keyrings/nodesource.gpg
  sudo chmod a+r /usr/share/keyrings/nodesource.gpg
  echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
  wait_for_apt
  sudo -E apt-get update -qq
  sudo -E apt-get install -y -qq nodejs
fi
node -v
npm -v

log "service account"
id -u "$APP_USER" >/dev/null 2>&1 \
  || sudo useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
sudo mkdir -p "$APP_DIR/app"
sudo chown -R "$APP_USER:$APP_USER" "$APP_DIR"

log "keeper wrapper"
sudo install -o root -g root -m 0755 "$STAGE/keeper-tick.sh" "$APP_DIR/keeper-tick.sh"

log "systemd units"
sudo install -o root -g root -m 0644 "$STAGE/systemd/ashonpons.service"        /etc/systemd/system/
sudo install -o root -g root -m 0644 "$STAGE/systemd/ashonpons-keeper.service" /etc/systemd/system/
sudo install -o root -g root -m 0644 "$STAGE/systemd/ashonpons-keeper.timer"   /etc/systemd/system/
sudo systemctl daemon-reload

log "nginx"
# Once certificates exist, install the TLS variant instead. Without this branch
# a second bootstrap would overwrite the live config with the HTTP-only one and
# quietly drop the site back to plain HTTP.
# live/ is root-only (0700), so a plain [ -f ] as ubuntu never sees the cert.
if sudo test -f /etc/letsencrypt/live/ashonarc.xyz/fullchain.pem && [ -f "$STAGE/nginx-ashonpons-tls.conf" ]; then
  echo "certificate present -- installing the TLS config"
  sudo install -o root -g root -m 0644 "$STAGE/nginx-ashonpons-tls.conf" /etc/nginx/sites-available/ashonpons
else
  echo "no certificate yet -- installing the HTTP-only config"
  sudo install -o root -g root -m 0644 "$STAGE/nginx-ashonpons.conf" /etc/nginx/sites-available/ashonpons
fi
sudo ln -sfn /etc/nginx/sites-available/ashonpons /etc/nginx/sites-enabled/ashonpons
# Ubuntu's stock site is also a default_server on :80 and would collide.
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx

log "done"
