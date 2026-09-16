# web — read API, keeper, site

Plain Node, no build step. Everything chain-specific comes from environment variables (see
`../.env.example`), so the same code serves the Arc testnet rehearsal and mainnet.

## Endpoints

| Path | Purpose |
| --- | --- |
| `GET /api/config` | Chain parameters, contract addresses, ABIs, official token, Reown project id — the page bootstraps from this |
| `GET /api/health` | Checks RPC, PoolManager, Factory and Lens one by one and names the broken link; 200 when all pass, 503 otherwise |
| `GET /api/tokens?start=0&count=50` | Every launch with pool, floor per token, deadline and locked share |
| `GET /api/token/{address}` | All fields for one token plus its Uniswap V4 pool id |
| `GET /api/token/{address}?buy=&for=&sell=&q=` | Adds `buyQuote` / `sellQuote` / `redeemQuote` in wei — the same math the trade executes |
| `GET /api/cron/keeper` | Collects LP fees from graduated positions into their pools; dry-run unless `KEEPER_EXECUTE=true` |

Amounts are given both as `...Wei` strings and formatted values. The page only computes on wei.

## Running

```bash
npm ci
CHAIN_ID=5042 RPC_URL=https://rpc.mainnet.arc.io FACTORY=0x… LENS=0x… PLATFORM_SINK=0x… \
POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951 PORT=8080 node server.mjs
```

`server.mjs` wraps the Vercel-shaped handlers in a plain HTTP server for the self-hosted box;
`../deploy/` has the nginx and systemd units, including the 15-minute keeper timer.

## Site

`public/index.html` is the whole front end: hash routes (`#/`, `#/launches`, `#/token/0x…`,
`#/launch`, `#/docs`), ethers v6 (vendored UMD), an injected-wallet path and a WalletConnect path
that loads Reown AppKit on demand with Arc defined as a custom network.
