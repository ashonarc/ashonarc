"""Fails if any shipped artefact contains CJK text.

The contracts are published and verifiable, and the page is public; both are an
English-language project. Documentation under docs/ is deliberately exempt --
it is written for the team, not for users.
"""
import glob, io, re, sys

CJK = re.compile(r"[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uff00-\uffef]")
PATTERNS = [
    "contracts/*.sol",
    "script/*.sol",
    "test/*.sol",
    "web/public/*.html",
    "web/api/*.js",
    "web/api/**/*.js",
    "web/lib/*.js",
    "keeper/*.mjs",
    "web/server.mjs",
    "deploy/*.sh",
    "deploy/*.conf",
    "deploy/systemd/*",
]

def main():
    bad = 0
    for pattern in PATTERNS:
        for path in sorted(glob.glob(pattern, recursive=True)):
            if "node_modules" in path:
                continue
            try:
                text = io.open(path, encoding="utf-8").read()
            except OSError:
                continue
            for number, line in enumerate(text.split("\n"), 1):
                if CJK.search(line):
                    print("%s:%d  %s" % (path, number, line.strip()[:90]))
                    bad += 1
    if bad:
        print("\n%d line(s) contain CJK text in shipped code" % bad)
        return 1
    print("shipped code is English-only")
    return 0

if __name__ == "__main__":
    sys.exit(main())
