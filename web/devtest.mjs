/** Calls the serverless handlers directly, so the logic can be exercised
 *  without a Vercel runtime. Not shipped; a local harness only. */
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

for (const f of [".env", "../.env"]) {
  if (!fs.existsSync(f)) continue;
  for (const line of fs.readFileSync(f, "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].trim();
  }
}
for (const [k, v] of Object.entries(JSON.parse(process.argv[3] ?? "{}"))) process.env[k] = v;

function mockRes() {
  const r = { _status: 200, _body: "", headers: {} };
  r.setHeader = (k, v) => { r.headers[k] = v; };
  r.status = (s) => { r._status = s; return r; };
  r.send = (b) => { r._body = b; return r; };
  return r;
}

const [, , spec] = process.argv;
const [file, qs = ""] = spec.split("?");
const query = Object.fromEntries(new URLSearchParams(qs));
// pathToFileURL: a bare Windows absolute path is not a valid ESM specifier.
const mod = await import(pathToFileURL(path.resolve(file)).href + `?t=${Date.now()}`);
const res = mockRes();
await mod.default({ query, headers: {}, method: "GET" }, res);
console.log("HTTP", res._status, "| cache:", res.headers["Cache-Control"]);
console.log(res._body);
