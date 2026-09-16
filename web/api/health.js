import { ethers } from "ethers";
import { CHAIN_ID, OURS, provider, factory, lens, send } from "../lib/chain.js";

/**
 * One request that says which link in the chain is broken, rather than a page
 * that silently renders zeros. Every check reports pass/fail independently.
 */
export default async function handler(req, res) {
  const checks = [];
  const t0 = Date.now();

  const check = async (name, fn) => {
    const started = Date.now();
    try {
      const detail = await fn();
      checks.push({ name, ok: true, ms: Date.now() - started, ...detail });
    } catch (e) {
      checks.push({ name, ok: false, ms: Date.now() - started, error: e.shortMessage ?? e.message });
    }
  };

  let p;
  await check("rpc", async () => {
    p = provider();
    const [net, block, fee] = await Promise.all([p.getNetwork(), p.getBlockNumber(), p.getFeeData()]);
    if (Number(net.chainId) !== CHAIN_ID) {
      throw new Error(`wrong chain: got ${net.chainId}, expected ${CHAIN_ID}`);
    }
    return {
      chainId: Number(net.chainId),
      block,
      gasPriceGwei: Number(ethers.formatUnits(fee.gasPrice ?? 0n, "gwei")).toFixed(3),
    };
  });

  if (p) {
    await check("poolManager", async () => {
      if (!OURS.poolManager) throw new Error("POOL_MANAGER is not configured");
      const code = await p.getCode(OURS.poolManager);
      if (code === "0x") throw new Error("no bytecode at POOL_MANAGER");
      return { address: OURS.poolManager, bytes: (code.length - 2) / 2 };
    });

    await check("factory", async () => {
      if (!OURS.factory) throw new Error("FACTORY is not configured");
      const code = await p.getCode(OURS.factory);
      if (code === "0x") throw new Error("no bytecode at FACTORY");
      const f = factory(p);
      const [count, official, fee] = await Promise.all([f.launchCount(), f.officialToken(), f.launchFee()]);
      return {
        address: OURS.factory,
        launches: Number(count),
        officialToken: official,
        officialLaunched: official !== ethers.ZeroAddress,
        launchFeeUsdc: ethers.formatEther(fee),
      };
    });

    await check("lens", async () => {
      if (!OURS.lens) throw new Error("LENS is not configured");
      const code = await p.getCode(OURS.lens);
      if (code === "0x") throw new Error("no bytecode at LENS");
      const f = factory(p);
      const n = Number(await f.launchCount());
      if (n === 0) return { address: OURS.lens, note: "no launches yet, read path untested" };
      const first = await f.launchedTokens(0);
      const v = await lens(p).tokenView(first);
      return { address: OURS.lens, sampledToken: v.symbol, reserveWei: v.reserve.toString(), phase: Number(v.phase) };
    });
  }

  const ok = checks.every((c) => c.ok);
  send(res, ok ? 200 : 503, { ok, ms: Date.now() - t0, checks }, 0);
}
