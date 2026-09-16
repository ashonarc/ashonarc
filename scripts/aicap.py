"""Brand asset generation against the aicap service. Token comes from .env."""
import argparse, io, json, mimetypes, os, secrets, sys, time, urllib.error, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def env(key, default=None):
    if os.environ.get(key):
        return os.environ[key]
    try:
        for line in io.open(os.path.join(ROOT, ".env"), encoding="utf-8"):
            k, _, v = line.partition("=")
            if k.strip() == key:
                return v.strip()
    except OSError:
        pass
    return default


BASE = env("AICAP_BASE", "https://ai.nofuns.xyz")
TOKEN = env("AICAP_TOKEN")


class AiCapError(RuntimeError):
    pass


def _req(path, method="GET", body=None, ctype=None, timeout=300, tries=4):
    """Retries transient network failures.

    A dropped TLS handshake while polling would otherwise abandon a job that is
    already running and already paid for, so only genuine HTTP responses end
    the loop.
    """
    last = None
    for attempt in range(tries):
        req = urllib.request.Request(BASE + path, data=body, method=method,
                                     headers={"Authorization": "Bearer " + TOKEN})
        if ctype:
            req.add_header("Content-Type", ctype)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.getcode(), r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except Exception as e:  # SSL EOF, reset connection, DNS blip
            last = e
            if attempt < tries - 1:
                time.sleep(2 * (attempt + 1))
    raise AiCapError("network error after %d tries: %s" % (tries, last))


def post_json(path, payload, timeout=300):
    code, raw = _req(path, "POST", json.dumps(payload).encode(), "application/json", timeout)
    d = json.loads(raw.decode("utf-8"))
    # 202 means accepted and still running, not failed.
    if code >= 400 and "job_id" not in d:
        raise AiCapError("http %s: %s" % (code, d.get("detail")))
    return d


def post_form(path, fields, files, timeout=300):
    bd = "----ac" + secrets.token_hex(16)
    m = ("--" + bd).encode()
    parts = []
    for k, v in fields.items():
        if v is None:
            continue
        if isinstance(v, bool):
            v = "true" if v else "false"
        parts += [m, b"\r\n",
                  ('Content-Disposition: form-data; name="%s"\r\n\r\n' % k).encode(),
                  str(v).encode("utf-8"), b"\r\n"]
    for name, fn, raw in files:
        mime = mimetypes.guess_type(fn)[0] or "application/octet-stream"
        parts += [m, b"\r\n",
                  ('Content-Disposition: form-data; name="%s"; filename="%s"\r\n' % (name, fn)).encode("utf-8"),
                  ("Content-Type: %s\r\n\r\n" % mime).encode(), raw, b"\r\n"]
    parts += [m, b"--\r\n"]
    code, rawb = _req(path, "POST", b"".join(parts), "multipart/form-data; boundary=" + bd, timeout)
    d = json.loads(rawb.decode("utf-8"))
    if code >= 400 and "job_id" not in d:
        raise AiCapError("http %s: %s" % (code, d.get("detail")))
    return d


def wait(job, timeout=1800):
    jid = job["job_id"] if isinstance(job, dict) else job
    t0, last = time.time(), None
    while time.time() - t0 < timeout:
        code, raw = _req("/v1/jobs/" + jid)
        j = json.loads(raw.decode("utf-8"))
        if j.get("step") != last:
            print("   %s %s" % (j["status"], j.get("step")), flush=True)
            last = j.get("step")
        if j["status"] == "done":
            return j
        if j["status"] == "failed":
            raise AiCapError(j.get("error") or "job failed")
        time.sleep(3)
    raise AiCapError("timed out after %ds (job_id=%s)" % (timeout, jid))


def download(artifact):
    code, raw = _req(artifact["url"], timeout=900)
    if code != 200:
        raise AiCapError("artifact download failed: http %s" % code)
    return raw


def save(job, prefix, outdir=os.path.join(ROOT, "assets")):
    os.makedirs(outdir, exist_ok=True)
    paths = []
    for i, a in enumerate(job.get("artifacts") or []):
        if a.get("kind") != "image":
            continue
        ext = (a.get("name") or "x.png").rsplit(".", 1)[-1]
        p = os.path.join(outdir, "%s-%d.%s" % (prefix, i + 1, ext))
        io.open(p, "wb").write(download(a))
        paths.append(p)
        print("   saved %s (%s bytes)" % (os.path.relpath(p, ROOT), a.get("bytes")))
    u = job.get("usage") or {}
    print("   usage: calls=%s cost_cny=%s model=%s" % (u.get("calls"), u.get("cost_cny"), u.get("model")))
    return paths


def text2image(prompt, prefix, size="1024x1024", n=1, transparent=False, quality="standard"):
    print("-> %s  (%s, n=%d%s)" % (prefix, size, n, ", transparent" if transparent else ""), flush=True)
    job = post_json("/v1/text2image", {"prompt": prompt, "size": size, "n": n,
                                       "transparent": transparent, "quality": quality, "wait": True})
    if job.get("status") != "done":
        job = wait(job)
    return save(job, prefix)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--size", default="1024x1024")
    ap.add_argument("--n", type=int, default=1)
    ap.add_argument("--transparent", action="store_true")
    ap.add_argument("--quality", default="standard")
    a = ap.parse_args()
    text2image(a.prompt, a.prefix, a.size, a.n, a.transparent, a.quality)
