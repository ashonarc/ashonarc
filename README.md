# AshonArc

**Not deflation. It's a withdrawal.** — [ashonarc.xyz](https://ashonarc.xyz) · [@AshonArc](https://x.com/AshonArc)

A token launchpad on [Arc](https://docs.arc.io) (Circle's L1, chain id 5042, native gas = USDC).
Every token launched here pays a 3% fee on each trade. Most of that fee lands in the token's own
USDC redemption pool. Any holder can burn tokens at any time inside a 30-day window and withdraw
their pro-rata share of the pool. No owner, no pause, no admin withdrawal on anything that holds
holders' money.

| | its own pool | issuer | official pool |
| --- | --- | --- | --- |
| any token | 85% | 10% | 5% |
| official token ($ASH) | 90% | 10% | — |

The official token runs on exactly the same contracts; other tokens just route 5% of their fees
into its pool while that pool is open.

## How it works

1. **Launch** — `LaunchFactory.launch()` deploys a 1B-supply ERC-20, a bonding curve and a
   redemption vault in one transaction, takes a 1 USDC fee, and executes the issuer's optional
   opening buy tax-free. The curve claims its Uniswap V4 pool id at launch so nobody can front-run it.
2. **Trade on the curve** — constant-product curve with a virtual USDC reserve. Buys in the first
   3 seconds pay a snipe tax that decays from 99% to 0; the tax goes to the pool too.
3. **Graduate** — when the real USDC reserve reaches the threshold, the reserve and matching tokens
   move into a full-range Uniswap V4 position the curve holds forever; the unsold remainder is burned.
   From then on trading happens on Uniswap and the position's 1% LP fee keeps feeding the pool
   through a permissionless `collectFees()`.
4. **Burn to withdraw** — `RedemptionVault.redeem(q)` burns `q` tokens and pays `q / supply × pool`
   in the same transaction. Burning never changes anyone else's floor. Selling usually pays more;
   the site shows both quotes side by side.
5. **Deadline** — 30 days after launch redemption closes and whatever is left goes to the issuer, once.

Production parameters: virtual reserve 5,000 USDC, graduation at 10,000 USDC of real reserve
(≈ ×9 from the opening price, ≈ 45k USDC market cap), launch fee 1 USDC. They are constructor
arguments of the factory and cannot be changed after deployment.

## Contracts

| Contract | Role |
| --- | --- |
| `LaunchFactory` | One-call launch; deploys token, curve and vault; launches the official token once (owner) |
| `CurveDeployer` | Creates `BondingCurve` instances; split out of the factory for the EIP-170 size limit |
| `BondingCurve` | Buy / sell, snipe tax, fee split, issuer `claim()`, graduation into Uniswap V4, `collectFees()` |
| `RedemptionVault` | `redeem()` / `previewRedeem()`, `fund()`, issuer `withdrawResidual()` after the deadline |
| `LaunchToken` | Plain ERC-20 with burn, no privileged functions |
| `PlatformSink` | Receives the 5% route once the official pool has closed |
| `LaunchpadLens` | Read-only aggregator: one call returns everything a token page shows |

Arc-specific behaviour the contracts account for: transfers to `address(0)` and to blocklisted
addresses revert, so every payout to an external address is pull-based; the mempool drops
transactions below 20 gwei; timestamps are not strictly increasing across blocks.

Production on Arc mainnet:

| | |
| --- | --- |
| **$ASH token** | `0x43dD25d0Ac3D64Ad6dA61e81CDBF83Fbbd4ac33b` |
| $ASH curve / vault | `0x437b3511f5B52Cac5318aF35Ca4dF4B86cBe032e` / `0x72609ECB3d1ae3155825634570744af011e0c6dE` |
| LaunchFactory | `0x2274232f228f14A90fce00f7c982D6F4418Fc045` |
| LaunchpadLens | `0xb51a24f0bc37A85218B2A8cCD21Bf60D2ECD341a` |
| CurveDeployer | `0x97F5427f419d7713dC1bBfc9Bd34e6278323B947` |
| PlatformSink | `0xa26B26B855e7Be58111840959C03bdCE4de7Cc41` |

Every address above is verified on [Sourcify](https://sourcify.dev) (chain 5042). Transaction hashes and the
account-level checks for every rehearsal are in [DEPLOYMENTS.md](DEPLOYMENTS.md).

## Repository

```
contracts/   Solidity (0.8.26, OpenZeppelin 5, Uniswap v4-core)
test/        Foundry: unit, adversarial, and a full lifecycle against a fork of Arc mainnet
script/      forge deploy scripts
deploy/      production parameters, VPS provisioning (nginx, systemd keeper timer)
web/         read API (/api/tokens, /api/token/:address, /api/health), keeper, and the single-page site
scripts/     ABI export, the Python curve model that generates test cases, brand assets
assets/      brand kit
docs/        model outputs
```

## Build and test

```bash
forge install
forge build
forge test                                   # 108 tests
forge test --match-path test/ForkArc.t.sol   # against Arc mainnet (needs ARC_RPC_URL or the default public RPC)
```

The web app is plain Node (no build step): `cd web && npm ci && node server.mjs` with the variables
from `.env.example`.

## Status

Experimental contracts on a new chain. No audit. The pool only holds what fees actually delivered,
and nothing here is advice.

MIT — see [LICENSE](LICENSE).
