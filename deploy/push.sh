#!/usr/bin/env bash
# Ship the current working tree to the box and restart it.
#
#   bash deploy/push.sh              # app only (the usual case)
#   bash deploy/push.sh --bootstrap  # also re-run system provisioning
#
# Run from the repository root, in Git Bash on Windows or any POSIX shell.
set -euo pipefail

HOST=${ASHONPONS_HOST:-54.250.168.250}
USER=${ASHONPONS_USER:-ubuntu}
KEY=${ASHONPONS_KEY:-F:/server/robinhood-burns.pem}
STAGE=/tmp/ashonpons-deploy

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

# Windows OpenSSH refuses a key whose ACL is readable by others, and `chmod`
# from Git Bash does not change the ACL. Work from a private copy instead.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$KEY" "$WORK/key.pem"
chmod 600 "$WORK/key.pem" 2>/dev/null || true
if command -v icacls >/dev/null 2>&1; then
  # Windows: the ACL must name exactly the current user. USERNAME is plain
  # ("Administrator"); whoami gives "MACHINE\user", so strip the domain.
  ME="${USERNAME:-$(whoami)}"; ME="${ME##*\\}"
  WINKEY="$(cygpath -w "$WORK/key.pem" 2>/dev/null || echo "$WORK/key.pem")"
  icacls "$WINKEY" /inheritance:r >/dev/null
  icacls "$WINKEY" /grant:r "$ME:(R)" >/dev/null
fi

SSH=(ssh -i "$WORK/key.pem" -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
SCP=(scp -q -i "$WORK/key.pem" -o StrictHostKeyChecking=accept-new)

echo "== packing =="
# tar treats "C:/..." as a remote host, so the tarball is built inside $WORK,
# which mktemp gives us as a POSIX path.
tar -czf "$WORK/app.tar.gz" -C web \
  --exclude=node_modules --exclude=.vercel --exclude='.env*' --exclude='.cron-secret.txt' .
du -h "$WORK/app.tar.gz" | cut -f1

echo "== uploading =="
"${SSH[@]}" "$USER@$HOST" "mkdir -p $STAGE/systemd"
(cd "$WORK" && "${SCP[@]}" app.tar.gz "$USER@$HOST:$STAGE/")
(cd deploy && "${SCP[@]}" bootstrap.sh release.sh keeper-tick.sh \
  nginx-ashonpons.conf nginx-ashonpons-tls.conf "$USER@$HOST:$STAGE/")
(cd deploy/systemd && "${SCP[@]}" ./*.service ./*.timer "$USER@$HOST:$STAGE/systemd/")
"${SSH[@]}" "$USER@$HOST" "cd $STAGE && sed -i 's/\r\$//' ./*.sh ./*.conf systemd/* && chmod +x ./*.sh"

if [ "${1:-}" = "--bootstrap" ]; then
  echo "== bootstrap =="
  "${SSH[@]}" "$USER@$HOST" "bash $STAGE/bootstrap.sh"
fi

echo "== release =="
"${SSH[@]}" "$USER@$HOST" "bash $STAGE/release.sh"

echo "== public check =="
curl -sS --max-time 20 -o /dev/null -w "http://$HOST/  HTTP %{http_code}\n" "http://$HOST/"
