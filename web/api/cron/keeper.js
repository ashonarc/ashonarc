import { ethers } from "ethers";
import { OURS, provider, factory, curveAt, vaultAt, send } from "../../lib/chain.js";

/**
 * The one job left for a keeper: pull accrued Uniswap LP fees into the
 * redemption pools of graduated tokens. Fees on the curve itself are split the
 * moment they are paid, so nothing needs sweeping before graduation.
 *
 * Every candidate is previewed with a static call first and only sent when the
 * USDC side clears the threshold, so a quiet pool costs nothing. Dry run unless
 * KEEPER_EXECUTE is exactly "true". A scheduler sends `Authorization: Bearer
 * $CRON_SECRET`; on the VPS a systemd timer reaches this port directly.
 *
 * Arc drops any transaction priced below the current base fee without an
 * error (the fee sat at 20 gwei for months, then started moving on 2026-09-16),
 * so the gas price is read from the node with a margin and floored by the env.
 */
const MIN_COLLECT_WEI = BigInt(process.env.KEEPER_MIN_COLLECT_WEI ?? "1000000000000000"); // 0.001 USDC
const GAS_PRICE_FLOOR = ethers.parseUnits(process.env.KEEPER_GAS_PRICE_GWEI ?? "21", "gwei");

async function gasPrice(p) {
  const { gasPrice: seen } = await p.getFeeData();
  const withMargin = seen ? (seen * 125n) / 100n : 0n;
  return withMargin > GAS_PRICE_FLOOR ? withMargin : GAS_PRICE_FLOOR;
}

export default async function handler(req, res) {
  const secret = process.env.CRON_SECRET;
  if (secret) {
    const auth = req.headers?.authorization ?? "";
    if (auth !== `Bearer ${secret}`) return send(res, 401, { error: "unauthorized" });
  }

  const execute = process.env.KEEPER_EXECUTE === "true";
  const log = [];
  try {
    if (!OURS.factory) return send(res, 503, { error: "FACTORY not configured" });
    const p = provider();
    const f = factory(p);

    let signer = null;
    if (execute) {
      if (!process.env.KEEPER_PRIVATE_KEY) throw new Error("KEEPER_EXECUTE set but KEEPER_PRIVATE_KEY missing");
      signer = new ethers.Wallet(process.env.KEEPER_PRIVATE_KEY, p);
      const bal = await p.getBalance(signer.address);
      log.push({ keeper: signer.address, balanceUsdc: ethers.formatEther(bal) });
      if (bal === 0n) throw new Error("keeper has no USDC for gas");
    }

    const count = Number(await f.launchCount());
    let graduated = 0;
    let collected = 0;
    let collectedWei = 0n;

    for (let i = 0; i < count; i++) {
      const token = await f.launchedTokens(i);
      const curve = curveAt(await f.curveOf(token), p);
      if (!(await curve.graduated())) continue;
      graduated++;
      const open = await vaultAt(await f.vaultOf(token), p).isOpen();
      const [quoteFees, tokenFees] = await curve.collectFees.staticCall();
      const entry = {
        token,
        poolOpen: open,
        pendingUsdc: ethers.formatEther(quoteFees),
        pendingTokens: ethers.formatUnits(tokenFees, 18),
      };
      // After the pool closes the USDC would go to the issuer's pending balance;
      // still worth collecting, but only above the same threshold.
      if (quoteFees >= MIN_COLLECT_WEI) {
        entry.action = "collectFees";
        collected++;
        collectedWei += quoteFees;
        if (execute) {
          try {
            const tx = await curve.connect(signer).collectFees({ gasPrice: await gasPrice(p) });
            const rc = await tx.wait();
            entry.tx = rc.hash;
            entry.gasUsed = Number(rc.gasUsed);
          } catch (e) {
            entry.error = e.shortMessage ?? e.message;
          }
        }
      }
      log.push(entry);
    }

    send(res, 200, {
      ok: true,
      mode: execute ? "execute" : "dry-run",
      launches: count,
      graduated,
      collections: collected,
      collectedUsdc: ethers.formatEther(collectedWei),
      log,
    });
  } catch (e) {
    send(res, 500, { ok: false, error: e.shortMessage ?? e.message, log });
  }
}
