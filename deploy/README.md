# Self-hosted deployment

One set of handlers, one box. `web/server.mjs` wraps the `api/*.js` handlers in a plain Node HTTP server;
nginx terminates TLS in front of it; a systemd timer runs the keeper.

## Machine

| | |
| --- | --- |
| Host | 54.250.168.250 (AWS Tokyo), Ubuntu 24.04 LTS, 2 vCPU / 911 MB / 38 GB |
| Login | user `ubuntu` with the SSH key; root login is refused |
| Node | 22.x from the NodeSource apt repository (GPG-verified packages, no `curl | sh`) |

## Layout

```
/opt/ashonpons/
  .env            0600 ashonpons:ashonpons   RPC_URL, contract addresses, CRON_SECRET, keeper settings
  keeper-tick.sh  0755 root                  called by the timer
  app/            server.mjs / api / lib / public / node_modules
```

systemd:

- `ashonpons.service` — the app, listening on `127.0.0.1:8080` behind nginx. Runs as the dedicated system
  user `ashonpons` with `ProtectSystem=strict` and `MemoryMax=500M` (the box has 911 MB and shares it with sshd).
- `ashonpons-keeper.timer` — runs the keeper every 15 minutes.
- nginx — `/etc/nginx/sites-available/ashonpons`; `/api/cron/` always returns 404 from the outside.

## Why the keeper is reachable from the timer and from nowhere else

The timer calls `127.0.0.1:8080` directly, bypassing nginx and its 404 for `/api/cron/`, so the only endpoint
that can ever send a transaction is unreachable from the internet. The handler additionally checks
`Authorization: Bearer $CRON_SECRET`. It is a dry run unless `KEEPER_EXECUTE=true` and `KEEPER_PRIVATE_KEY`
are set in `/opt/ashonpons/.env`; the keeper key only needs a little USDC for gas, since `collectFees()` is
permissionless and moves nothing to the caller.

## Redeploy

From the repository root:

```bash
bash deploy/push.sh              # pack → upload → npm ci → restart → smoke test
bash deploy/push.sh --bootstrap  # first install, or after changing systemd / nginx files
```

## Troubleshooting

```bash
sudo systemctl status ashonpons
sudo journalctl -u ashonpons -f
sudo journalctl -u ashonpons-keeper -n 50
curl -s localhost:8080/api/health
```

## Domain and HTTPS

Canonical host **ashonarc.xyz**; `www.ashonarc.xyz` and the old `ashonpons.xyz` pair 301 to it.
DNS is on Vercel (the registrar): the default apex `ALIAS → cname.vercel-dns-017.com` was removed and replaced with

| Type | Name | Value | TTL |
| --- | --- | --- | --- |
| A | @ | 54.250.168.250 | 60 |
| A | www | 54.250.168.250 | 60 |
| ALIAS | * | cname.vercel-dns-017.com. (kept; other subdomains still go to Vercel) | 60 |

The 60-second TTL is deliberate: pointing back at Vercel takes effect within a minute.

Certificate: Let's Encrypt, lineage `ashonarc.xyz`, one certificate for all four names
(`certbot certonly --nginx --cert-name ashonarc.xyz -d …`), renewed by `certbot.timer`. The account was
registered without an email address; add one with `sudo certbot update_account --email …` for expiry notices.

### Two nginx configs

| File | When |
| --- | --- |
| `nginx-ashonpons.conf` | Before a certificate exists (plain HTTP). First install on a fresh box |
| `nginx-ashonpons-tls.conf` | Once the certificate exists. This is what runs in production |

`bootstrap.sh` installs the TLS config when `/etc/letsencrypt/live/ashonarc.xyz/fullchain.pem` exists
(tested with `sudo test`, because `live/` is root-only), otherwise the plain one — so a re-run of bootstrap
cannot silently drop the site back to HTTP.

One deliberate difference from what `certbot --nginx` generates: certbot leaves `return 404` in the port-80
block, which also 404s plain `http://54.250.168.250/`. The bare IP is the fallback on a day DNS is broken,
so that block proxies instead.

## Not done

`ufw` is off. The AWS security group already controls inbound traffic (80 / 443 only); a mistyped firewall
rule on a remote box means losing access, and tightening is safer from the AWS console.
