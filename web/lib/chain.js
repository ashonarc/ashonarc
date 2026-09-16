import { ethers } from "ethers";
import { readFileSync } from "node:fs";

/**
 * Everything chain-specific comes from the environment, so one codebase serves
 * the Arc testnet rehearsal and mainnet. Amounts are native USDC at 18
 * decimals throughout; the 6-decimal ERC-20 interface at 0x3600... is never
 * touched.
 */
export const CHAIN_ID = Number(process.env.CHAIN_ID || 5042);
export const RPC_URL = process.env.RPC_URL || "";
// explorer.arc.io sits behind a Cloudflare Access login on mainnet (2026-09-16)
// and arc-scan.org bot-walls every page; arcexplorer.org is open.
export const EXPLORER = process.env.EXPLORER_URL || (CHAIN_ID === 5042002 ? "https://explorer.testnet.arc.io" : "https://www.arcexplorer.org");
export const BRIDGE_URL = process.env.BRIDGE_URL || "https://cctpbridge.app/";
export const UNISWAP_URL = process.env.UNISWAP_URL || "https://app.uniswap.org/";
export const NETWORK_NAME = CHAIN_ID === 5042002 ? "Arc Testnet" : "Arc";

export const OURS = {
  factory: process.env.FACTORY || "",
  lens: process.env.LENS || "",
  sink: process.env.PLATFORM_SINK || "",
  poolManager: process.env.POOL_MANAGER || "",
};

const load = (name) => JSON.parse(readFileSync(new URL(`./abi/${name}.json`, import.meta.url), "utf8"));

/** Exported straight from the forge artefacts by scripts/export_abi.py. */
export const abi = {
  factory: load("LaunchFactory"),
  lens: load("LaunchpadLens"),
  curve: load("BondingCurve"),
  vault: load("RedemptionVault"),
  token: load("LaunchToken"),
};

export function provider() {
  if (!RPC_URL) throw new Error("RPC_URL is not set");
  // staticNetwork avoids an extra eth_chainId on every single call.
  return new ethers.JsonRpcProvider(RPC_URL, CHAIN_ID, { staticNetwork: true });
}

export const factory = (p = provider()) => new ethers.Contract(OURS.factory, abi.factory, p);
export const lens = (p = provider()) => new ethers.Contract(OURS.lens, abi.lens, p);
export const curveAt = (address, p = provider()) => new ethers.Contract(address, abi.curve, p);
export const vaultAt = (address, p = provider()) => new ethers.Contract(address, abi.vault, p);

/** JSON.stringify cannot serialise BigInt, and silently throwing inside a
 *  serverless handler turns a data problem into a 500 with no body. */
export function jsonSafe(value) {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(jsonSafe);
  if (value && typeof value === "object") {
    const out = {};
    for (const k of Object.keys(value)) {
      if (/^\d+$/.test(k)) continue; // ethers Result exposes positional duplicates
      out[k] = jsonSafe(value[k]);
    }
    return out;
  }
  return value;
}

export function send(res, status, body, cacheSeconds = 0) {
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader(
    "Cache-Control",
    cacheSeconds > 0
      ? `public, s-maxage=${cacheSeconds}, stale-while-revalidate=${cacheSeconds * 4}`
      : "no-store"
  );
  res.status(status).send(JSON.stringify(jsonSafe(body), null, 2));
}
