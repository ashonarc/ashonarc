# Deployments

Chain: Arc mainnet, chain id 5042. RPC `https://rpc.mainnet.arc.io`. Explorer https://www.arcexplorer.org
(`/tx/0x…`, `/address/0x…`). Every contract below is verified on Sourcify (chain 5042).

Arc's gas price sat at a flat 20 gwei for months and started moving on 2026-09-16 (21.7 gwei seen).
A transaction priced below the current base fee is dropped silently — no error, no receipt — so read
`cast gas-price` before broadcasting and add a margin.

## $ASH — launched 2026-09-16, block 21,164,618

| | |
| --- | --- |
| Token (Ash / ASH) | `0x43dD25d0Ac3D64Ad6dA61e81CDBF83Fbbd4ac33b` |
| Bonding curve | `0x437b3511f5B52Cac5318aF35Ca4dF4B86cBe032e` |
| Redemption vault | `0x72609ECB3d1ae3155825634570744af011e0c6dE` |
| Launch tx | `0x2cf79895d20e0dab6b34f6e091cd414e54a2d3472a847602c905cd0dba59b264` (4,939,514 gas at 79 gwei) |
| Issuer | `0xe55EBE1Fe460Fc2A9c7D7F3eBF1b213F0f588673` |
| Opening buy | 80 USDC → 15,282,810.78 ASH (1.53% of supply), tax-free inside the launch tx |
| Pool deadline | `1792157453` = 2026-10-16 13:30:53 UTC |

Checked right after the block: sink +1 USDC (launch fee); vault = 90% × 3% of all buys; issuer claimable = 10% × 3%; snipe tax 0.
Within two minutes of the block, seven more buys had arrived from other wallets (about 450 USDC net), all after the
3-second window. All three contracts verified on Sourcify.

## Production infrastructure — 2026-09-16

Deployer, factory owner and sink owner: `0xe55EBE1Fe460Fc2A9c7D7F3eBF1b213F0f588673`.
Parameters: virtual reserve **5,000 USDC**, graduation at **10,000 USDC** of real reserve, launch fee **1 USDC**,
Uniswap V4 PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`. Cost 0.273 USDC at 30 gwei.

| Contract | Address | Deploy tx | Gas |
| --- | --- | --- | --- |
| PlatformSink | `0xa26B26B855e7Be58111840959C03bdCE4de7Cc41` | `0x15ecc6e0…49e57bc7` | 322,429 |
| CurveDeployer | `0x97F5427f419d7713dC1bBfc9Bd34e6278323B947` | `0x2c2d8bbc…e8feb67a` | 3,746,748 |
| LaunchFactory | `0x2274232f228f14A90fce00f7c982D6F4418Fc045` | `0x0e267cc5…258f7303` | 2,777,028 |
| LaunchpadLens | `0xb51a24f0bc37A85218B2A8cCD21Bf60D2ECD341a` | `0x87f889ed…65812d247` | 2,259,087 |

The official token was launched with `script/LaunchOfficial.s.sol` and the parameters in `deploy/ash-mainnet.env`;
third-party launches are open since then.

## Mainnet rehearsal — 2026-09-16

A throwaway deployment of the same bytecode with the parameters scaled down 50,000× so the whole lifecycle
could be exercised for cents: virtual reserve 0.1 USDC, graduation at 0.16 USDC, launch fee 0.02 USDC.
Deployer: the test key `0x6C55eB9Ca91c80DA430a1dEE4b1A5c3870D13571`. Funded with 1 USDC bridged from
Arbitrum over CCTP (`scripts/batch-cctp-arbitrum-to-arc.mjs`).

| Contract | Address | Deploy tx | Gas |
| --- | --- | --- | --- |
| PlatformSink | `0x2Ed87C817FA3CcDaA6648Ed501B3356773a323aF` | `0x0308ec86…2709fa2e` | 322,429 |
| CurveDeployer | `0xbCd1B8EDAda6934cB73B4E3F7fe82C6F809F7068` | `0xbafa355f…852103e0` | 3,746,748 |
| LaunchFactory | `0x837b7897a2E3bC2884009fA3a3203E4FF0d2bc7c` | `0x7b61d8fa…ce4e3c9f` | 2,776,968 |
| LaunchpadLens | `0x1Fa1b0C0a1112c95CC7C59686BeeFc49e890AF6B` | `0x3952f1d2…50dfde50` | 2,259,087 |
| Rehearsal / REHRSL (official test token) | `0x52F6DCF23B110B91b224f72eb683614B79447776` — curve `0xdF34…a052`, vault `0x42c5…8275` | `0x88688740…1d9a3657` | 4,831,733 |
| Test Frog / TFROG (third-party test token) | `0xf4aadBEC89737440d84EaE589Da91d7EF60b1CDb` — curve `0xd849…0880`, vault `0xBE02…fC87` | `0x3a0bc825…5faca663` | 4,795,316 |
| PoolSwapTest (test router; Arc has no V4 quoter or router) | `0x616be4235dD1bA4dAc9Ca57E53a19b1A5bC5bB11` | `0xdb71f059…2d248dac8` | — |

The rehearsal addresses equal the Arc testnet ones: same deployer, same starting nonce.

### Official test token, full lifecycle

| Step | Tx | Result |
| --- | --- | --- |
| Official launch (fee 0.02 + opening buy 0.04) | `0x88688740…` | Sink +0.02; official pool 0.00108 = 90% × 3% × 0.04; issuer share 0.00012 held on the curve; issuer received 279.5M tokens |
| Graduation buy of 0.13 (real reserve 0.0388 → 0.1649 ≥ 0.16) | `0x6c370685…bfaa2036b` | 477,092 gas. 0.1649 USDC + 235.0M tokens into a full-range V4 position (L = 6.22e21), 142.5M burned; curve holds 0 tokens and exactly `totalClaimable` USDC |
| Lens `tokenView` | — | sqrtPriceX96 / liquidity / lockedInPool read from the real PoolManager, phase = 1 |
| V4 swap 0.12 USDC through PoolSwapTest | `0x6110d00f…4b4f4c6` | 125,098 gas, 98.4M tokens out |
| Keeper: dry run, then `collectFees()` | `0xdeeaeab4…dbc201f1d` | Dry run found 1 graduated token with 0.0012 pending; execute 142,014 gas; official pool +0.00108 (90%) |
| Burn 72.09M tokens | `0xdb8717c9…f7d9dba2` | `previewRedeem` 0.000476695 == paid; `totalSupply` decreased by exactly the burned amount |
| Issuer `claim()` | `0x30449762…4e9ecfdcc` | 0.00063 paid (0.00051 + 10% of the LP fee); curve balance 0 |

### Third-party test token, full lifecycle (functional test of every path a user can take)

Each step took the site's own quote first and compared it with the on-chain result.

| Step | Tx | Result |
| --- | --- | --- |
| Launch (fee 0.02 + opening buy 0.02) | `0x3a0bc825…5faca663` | TFROG pool 0.00051 = 85% × 3% × 0.02, official pool +0.00003 (5%), sink +0.02, issuer share 0.00006 (10%), snipe tax 0 (issuer exempt) |
| Buy 0.03 | — | 164.12M tokens = the curve formula; 85 / 10 / 5 deltas exact |
| Sell 82.06M | — | quote 0.015646545352743561 == paid |
| Burn 24.45M (10%) | — | `previewRedeem` 0.000041237297441373 == paid; supply decreased exactly |
| Buy 1 USDC → graduation (threshold 0.16) | `0x34a610c1…8d010c7f0` | 520,500 gas; 1.0024 USDC + 82.48M tokens into V4, 8.23M burned |
| Issuer `claim()` | — | 0.003198 paid exactly, curve balance 0 |
| V4 swap 0.05 → keeper pass | — | 0.0005 pending < 0.001 threshold → skipped by design |
| V4 swap 0.1 → keeper pass from the VPS timer | `0x097ca6bc…71f81c7c9` | 204,677 gas; 0.0015 collected: pool +85% (rounding favours the pool), issuer +10%, official pool +5% |

Total spent across both rehearsals: about 1.9 USDC, of which roughly 0.7 was gas.

## Site

https://ashonarc.xyz runs on the self-hosted box described in [deploy/README.md](deploy/README.md):
`web/server.mjs` in front of the read API, the single-page site in `web/public/index.html`, and a systemd
timer that runs the keeper every 15 minutes (`KEEPER_EXECUTE=true`, gas price read from the node with a margin).
`/api/health` checks RPC, PoolManager, Factory and Lens one by one.

## Arc testnet rehearsal — 2026-09-15

Chain id 5042002, RPC `https://rpc.testnet.arc.network`. The testnet has no Uniswap V4, so a PoolManager
(`0xFE5f170B23621521ABe2FCbA25A532a3190c94aa`) and PoolSwapTest (`0x66F4E4689430E7eB3Fd2B5aB1dC21F124AA06F0f`)
were deployed first. Parameters 5 / 8 / 1 USDC. Launch → trade → redeem → graduate → V4 swap → collect → claim
all passed with the 85 / 10 / 5 split exact; graduation cost 515,156 gas. The contract addresses are the same
as the mainnet rehearsal above.

## History

The mechanism was first rehearsed on Robinhood Chain (chain id 4663) on 2026-09-08/09 on top of the PONS
launchpad, before the project moved to its own contracts on Arc. Those deployments are superseded and are kept
only in git history.
