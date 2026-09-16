import { OURS, factory, lens, send } from "../lib/chain.js";
import { decorate } from "../lib/decorate.js";

/** GET /api/tokens?start=0&count=50 -- every launch, oldest first. */
export default async function handler(req, res) {
  try {
    if (!OURS.lens || !OURS.factory) {
      return send(res, 503, { error: "LENS/FACTORY not configured" });
    }
    const total = Number(await factory().launchCount());
    const start = Math.max(0, Number(req.query?.start ?? 0) || 0);
    const count = Math.min(100, Math.max(1, Number(req.query?.count ?? 50) || 50));

    const rows = await lens().tokenViews(start, count);
    send(res, 200, { total, start, count: rows.length, tokens: rows.map(decorate) }, 15);
  } catch (e) {
    send(res, 500, { error: e.shortMessage ?? e.message });
  }
}
