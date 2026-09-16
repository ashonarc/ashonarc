/**
 * Self-hosted entry point.
 *
 * The VPS runs the exact same handler files Vercel runs, behind a plain Node
 * server, so the two deployments cannot drift apart. The handlers expect the
 * Express-shaped request and response Vercel hands them -- `req.query` already
 * parsed, `res.status(n).send(body)` -- which the Node http module does not
 * provide, so this file supplies that shape and nothing else.
 *
 *   PORT   listening port (default 8080)
 *   HOST   bind address (default 127.0.0.1 -- nginx terminates the public side)
 */
import http from "node:http";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(ROOT, "public");
const PORT = Number(process.env.PORT || 8080);
const HOST = process.env.HOST || "127.0.0.1";

/** pathToFileURL: a bare absolute path is not a valid ESM specifier. */
const load = async (rel) => (await import(pathToFileURL(path.join(ROOT, rel)).href)).default;

const handlers = {
  health: await load("api/health.js"),
  tokens: await load("api/tokens.js"),
  token: await load("api/token/[address].js"),
  keeper: await load("api/cron/keeper.js"),
  config: await load("api/config.js"),
};

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
  ".webmanifest": "application/manifest+json",
};

/** Give the response the two methods the handlers call. */
function shim(res) {
  res.status = (code) => {
    res.statusCode = code;
    return res;
  };
  res.send = (body) => {
    res.end(body);
    return res;
  };
  return res;
}

function json(res, code, body) {
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(body));
}

async function serveStatic(req, res, pathname) {
  const rel = pathname === "/" ? "index.html" : decodeURIComponent(pathname).replace(/^\/+/, "");
  const file = path.resolve(PUBLIC_DIR, rel);
  // Resolve first, then check: "/../.env" and "/%2e%2e/.env" both normalise to
  // a path outside PUBLIC_DIR, and only a post-resolution check catches both.
  if (file !== PUBLIC_DIR && !file.startsWith(PUBLIC_DIR + path.sep)) {
    return json(res, 403, { error: "forbidden" });
  }

  let stat;
  try {
    stat = await fsp.stat(file);
  } catch {
    return json(res, 404, { error: "not found" });
  }
  if (stat.isDirectory()) return json(res, 404, { error: "not found" });

  const ext = path.extname(file).toLowerCase();
  res.setHeader("Content-Type", MIME[ext] ?? "application/octet-stream");
  res.setHeader("Content-Length", stat.size);
  res.setHeader("Last-Modified", stat.mtime.toUTCString());
  // The page is the thing that changes on every deploy; the images are not.
  res.setHeader("Cache-Control", ext === ".html" ? "no-cache" : "public, max-age=3600");

  if (req.method === "HEAD") return res.end();
  fs.createReadStream(file).pipe(res);
}

const server = http.createServer(async (req, res) => {
  shim(res);
  const url = new URL(req.url, "http://localhost");
  const pathname = url.pathname;

  if (req.method === "OPTIONS") {
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
    return res.status(204).send("");
  }
  if (req.method !== "GET" && req.method !== "HEAD" && req.method !== "POST") {
    return json(res, 405, { error: "method not allowed" });
  }

  // A fresh object rather than a spread of the request: IncomingMessage is a
  // stream, and the handlers only ever read these three fields.
  const shimmed = { query: Object.fromEntries(url.searchParams), headers: req.headers, method: req.method };

  try {
    if (pathname === "/api/health") return await handlers.health(shimmed, res);
    if (pathname === "/api/config") return await handlers.config(shimmed, res);
    if (pathname === "/api/tokens") return await handlers.tokens(shimmed, res);
    if (pathname === "/api/cron/keeper") return await handlers.keeper(shimmed, res);

    // nginx denies /api/cron/ from outside; the timer reaches this port directly.
    const m = pathname.match(/^\/api\/token\/([^/]+)\/?$/);
    if (m) {
      shimmed.query.address = decodeURIComponent(m[1]);
      return await handlers.token(shimmed, res);
    }

    if (pathname.startsWith("/api/")) return json(res, 404, { error: "no such endpoint" });
    return await serveStatic(req, res, pathname);
  } catch (e) {
    // A handler that throws before sending would otherwise hang the socket
    // until the client gives up, with nothing in the log to explain it.
    console.error(`[${req.method} ${pathname}]`, e);
    if (!res.headersSent) json(res, 500, { error: e.message ?? "internal error" });
    else res.end();
  }
});

// A stuck RPC upstream must not pin a socket open forever.
server.requestTimeout = 120_000;
server.headersTimeout = 65_000;

server.listen(PORT, HOST, () => {
  console.log(`ashonpons listening on http://${HOST}:${PORT}`);
});

// systemd sends SIGTERM on restart; exit cleanly so it does not have to SIGKILL.
for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => server.close(() => process.exit(0)));
}
