import { ethers } from "ethers";
import { OURS, lens, send } from "../../lib/chain.js";
import { decorate } from "../../lib/decorate.js";

const UNKNOWN_TOKEN = ethers.id("UnknownToken()").slice(0, 10);

/**
 * GET /api/token/0x...                        one token, everything a detail page needs
 * GET /api/token/0x...?buy=<usdcWei>&for=0x.. tokens received for that much USDC (recipient decides the snipe tax)
 * GET /api/token/0x...?sell=<tokenWei>        USDC received for selling that many tokens on the curve
 * GET /api/token/0x...?q=<tokenWei>           USDC received for burning that many tokens through the pool
 */
export default async function handler(req, res) {
  try {
    if (!OURS.lens) return send(res, 503, { error: "LENS not configured" });
    const address = req.query?.address;
    if (!ethers.isAddress(address)) return send(res, 400, { error: "bad token address" });

    const l = lens();
    const body = decorate(await l.tokenView(address));

    const parse = (v) => {
      try {
        return BigInt(v);
      } catch {
        return null;
      }
    };

    if (req.query?.buy) {
      const amount = parse(req.query.buy);
      if (amount === null) return send(res, 400, { error: "buy must be an integer amount of USDC wei" });
      const recipient = ethers.isAddress(req.query.for) ? req.query.for : ethers.ZeroAddress;
      const [tokensOut, fee, tax] = await l.quoteBuy(address, amount, recipient);
      body.buyQuote = {
        usdcInWei: amount.toString(),
        tokensOut: ethers.formatUnits(tokensOut, 18),
        tokensOutWei: tokensOut.toString(),
        feeUsdc: ethers.formatEther(fee),
        snipeTaxUsdc: ethers.formatEther(tax),
        available: !body.graduated,
      };
    }
    if (req.query?.sell) {
      const amount = parse(req.query.sell);
      if (amount === null) return send(res, 400, { error: "sell must be an integer amount of token wei" });
      const [quoteOut, fee] = await l.quoteSell(address, amount);
      body.sellQuote = {
        tokensInWei: amount.toString(),
        usdcOut: ethers.formatEther(quoteOut),
        usdcOutWei: quoteOut.toString(),
        feeUsdc: ethers.formatEther(fee),
        available: !body.graduated,
      };
    }
    if (req.query?.q) {
      const amount = parse(req.query.q);
      if (amount === null) return send(res, 400, { error: "q must be an integer amount of token wei" });
      const out = await l.previewRedeem(address, amount);
      body.redeemQuote = {
        tokensInWei: amount.toString(),
        usdcOut: ethers.formatEther(out),
        usdcOutWei: out.toString(),
        // The page must not present burning as the better exit: after
        // graduation the market usually pays more, and it must say so.
        note: "Burning pays the pool's pro-rata share. Selling on the market usually pays more; compare before you burn.",
      };
    }

    send(res, 200, body, 10);
  } catch (e) {
    const msg = e.shortMessage ?? e.message ?? "";
    // LaunchpadLens.UnknownToken(), whether ethers decoded it or only kept the selector.
    const data = typeof e.data === "string" ? e.data : "";
    if (e.revert?.name === "UnknownToken" || data.startsWith(UNKNOWN_TOKEN) || msg.includes("UnknownToken")) {
      return send(res, 404, { error: "not a token from this launchpad" });
    }
    send(res, 500, { error: msg });
  }
}
