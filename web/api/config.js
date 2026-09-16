import {
  CHAIN_ID, RPC_URL, EXPLORER, BRIDGE_URL, UNISWAP_URL, NETWORK_NAME, OURS, abi, factory, send,
} from "../lib/chain.js";

/**
 * GET /api/config -- everything the page needs to talk to the chain itself:
 * network parameters (so it can add Arc to a wallet), addresses, ABIs, and the
 * official token. The page does not trust the API for anything it can read
 * from the contracts directly; this is bootstrap, not data.
 */
export default async function handler(req, res) {
  try {
    let official = "";
    try {
      official = await factory().officialToken();
    } catch {
      official = "";
    }
    send(res, 200, {
      chainId: CHAIN_ID,
      chainIdHex: "0x" + CHAIN_ID.toString(16),
      networkName: NETWORK_NAME,
      rpcUrl: RPC_URL,
      explorer: EXPLORER,
      bridgeUrl: BRIDGE_URL,
      uniswapUrl: UNISWAP_URL,
      nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
      factory: OURS.factory,
      lens: OURS.lens,
      platformSink: OURS.sink,
      poolManager: OURS.poolManager,
      officialToken: official,
      // Reown (WalletConnect) project id; public by nature, lives in the env so a
      // rehearsal box and the real site can use different projects.
      reownProjectId: process.env.REOWN_PROJECT_ID || "",
      abi,
    }, 60);
  } catch (e) {
    send(res, 500, { error: e.shortMessage ?? e.message });
  }
}
