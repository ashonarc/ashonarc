"""Render social cards in the site's Bonfire style. Text is drawn by us, never by a model.

    python scripts/tweet_cards.py [--fonts assets/fonts] [--out assets/social]

Fonts (all OFL): ArchivoBlack-Regular.ttf, IBMPlexMono-Medium.ttf, IBMPlexMono-Regular.ttf.
English only: the project never publishes Chinese copy.
"""
import argparse
import os

from PIL import Image, ImageDraw, ImageFont

W, H = 1600, 900
PAD = 80
BG, INK, HOT, DIM, MUTE, BLACK = (21, 21, 20), (242, 242, 240), (252, 82, 1), (140, 140, 138), (92, 92, 90), (17, 17, 17)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS = {}


def font(kind, size):
    key = (kind, size)
    if key not in FONTS:
        path = {
            "display": "ArchivoBlack-Regular.ttf",
            "mono": "IBMPlexMono-Medium.ttf",
            "mono-r": "IBMPlexMono-Regular.ttf",
        }[kind]
        FONTS[key] = ImageFont.truetype(os.path.join(FONT_DIR, path), size)
    return FONTS[key]


def tracked(draw, xy, text, f, fill, tracking=0.0):
    """Draw text with letter-spacing (fraction of font size), returns the end x."""
    x, y = xy
    step = f.size * tracking
    for ch in text:
        draw.text((x, y), ch, font=f, fill=fill)
        x += draw.textlength(ch, font=f) + step
    return x


def tracked_width(draw, text, f, tracking=0.0):
    return sum(draw.textlength(ch, font=f) for ch in text) + f.size * tracking * max(0, len(text) - 1)


def wrap(draw, text, f, max_w):
    words = text.split(" ")
    lines, cur = [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=f) <= max_w or not cur:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def frame(canvas_bg=BG):
    im = Image.new("RGB", (W, H), canvas_bg)
    d = ImageDraw.Draw(im)
    return im, d


def wordmark(d, im, y=H - PAD - 34, color=INK):
    """Flame + ASHONARC, bottom-left. The site stays unnamed until it is public."""
    logo = Image.open(os.path.join(ROOT, "assets", "ash-logo-64.png")).convert("RGBA").resize((44, 44), Image.LANCZOS)
    if color == BLACK:
        tinted = Image.new("RGBA", logo.size, BLACK + (0,))
        tinted.putalpha(logo.split()[3])
        logo = tinted
    im.paste(logo, (PAD, y - 4), logo)
    tracked(d, (PAD + 58, y), "ASHONARC", font("display", 26), color, -0.01)


def kicker(d, y, text, color=HOT):
    tracked(d, (PAD, y), text, font("mono", 24), color, 0.14)
    return y + 44


def title(d, y, lines, size=104, color=INK, lh=0.92):
    f = font("display", size)
    for ln in lines:
        d.text((PAD - 4, y), ln, font=f, fill=color)
        y += int(size * lh)
    return y


def rule_line(d, y, x0=PAD, x1=W - PAD, color=INK, w=2):
    d.rectangle([x0, y, x1, y + w - 1], fill=color)


def feebar(d, y, x0=PAD, x1=W - PAD, h=28):
    d.rectangle([x0, y, x1, y + h], outline=INK, width=2)
    inner = x1 - x0 - 4
    a = x0 + 2
    b = a + int(inner * 0.85)
    c = b + int(inner * 0.10)
    d.rectangle([a, y + 2, b, y + h - 2], fill=HOT)
    d.rectangle([b, y + 2, c, y + h - 2], fill=INK)
    d.rectangle([c, y + 2, x1 - 2, y + h - 2], fill=DIM)
    return y + h


# ------------------------------------------------------------------ cards
def card_rules():
    im, d = frame()
    y = kicker(d, PAD, "ASHONARC · LAUNCHPAD ON ARC · SAME RULES FOR EVERY TOKEN")
    y = title(d, y + 8, ["EVERY TRADE", "PAYS 3%."], 112)
    y = feebar(d, y + 26)
    f = font("mono", 26)
    y += 16
    tracked(d, (PAD, y), "85% POOL", f, HOT, 0.08)
    tracked(d, (PAD + 420, y), "10% ISSUER", f, INK, 0.08)
    tracked(d, (PAD + 860, y), "5% $ASH POOL", f, DIM, 0.08)
    y += 70
    rule_line(d, y)
    y += 30
    fm = font("mono-r", 30)
    rows = [
        ("BURN", "q tokens  →  q ÷ supply × pool, in USDC, same transaction"),
        ("WINDOW", "30 days from launch  →  then the residual goes to the issuer, once"),
        ("POOL", "one contract per token · no owner · no pause · no admin withdrawal"),
    ]
    for k, v in rows:
        tracked(d, (PAD, y + 4), k, font("mono", 22), HOT, 0.14)
        d.text((PAD + 190, y), v, font=fm, fill=INK)
        y += 56
    wordmark(d, im)
    tracked(d, (W - PAD - tracked_width(d, "NOT DEFLATION. IT'S A WITHDRAWAL.", font("mono", 22), 0.1), H - PAD - 30), "NOT DEFLATION. IT'S A WITHDRAWAL.", font("mono", 22), DIM, 0.1)
    return im


def card_vs():
    im, d = frame()
    y = kicker(d, PAD, "WHY A POOL, NOT “DIVIDENDS”")
    y = title(d, y + 8, ["DIVIDENDS NEED VOLUME.", "A FLOOR NEEDS A BALANCE."], 82)
    y += 40
    top, bottom = y, H - PAD - 110
    mid = W // 2
    # left: dividends (dark), right: floor (orange)
    d.rectangle([PAD, top, mid - 10, bottom], outline=INK, width=2)
    d.rectangle([mid + 10, top, W - PAD, bottom], fill=HOT)
    fl = font("mono", 22)
    fb = font("mono-r", 28)
    L = ("DIVIDENDS", ["paid out of new trades", "chart goes quiet → payout goes to 0", "you hold, you wait, you hope"])
    R = ("THE POOL", ["filled by past trades, sitting in USDC", "chart goes quiet → still there", "burn any time, take your share"])
    for (x0, hdr, lines, col, bodycol) in ((PAD + 40, L[0], L[1], INK, INK), (mid + 50, R[0], R[1], BLACK, BLACK)):
        yy = top + 36
        tracked(d, (x0, yy), hdr, font("display", 40), col, 0.0)
        yy += 78
        d.rectangle([x0, yy, x0 + 120, yy + 5], fill=col)
        yy += 40
        for ln in lines:
            d.text((x0, yy), ln, font=fb, fill=bodycol)
            yy += 54
    d.text((PAD, bottom + 26), "Selling usually pays more than burning. Every token page shows both quotes.", font=font("mono-r", 22), fill=DIM)
    wordmark(d, im)
    return im


def card_proof():
    im, d = frame()
    y = kicker(d, PAD, "BEFORE ASKING ANYONE FOR A CENT")
    y = title(d, y + 8, ["REHEARSED ON", "ARC MAINNET."], 104)
    steps = [
        ("01", "LAUNCH", "token + curve + pool, one tx"),
        ("02", "GRADUATE", "into Uniswap v4 · 477k gas ≈ $0.01"),
        ("03", "FEES → POOL", "LP fee collected, 90% to the pool"),
        ("04", "BURN → USDC", "paid exactly the quoted amount"),
    ]
    foot = "Every transaction is public. Hashes in the thread."
    y += 36
    cw = (W - 2 * PAD - 3 * 16) // 4
    for i, (n, h, s) in enumerate(steps):
        x0 = PAD + i * (cw + 16)
        x1 = x0 + cw
        last = i == len(steps) - 1
        if last:
            d.rectangle([x0, y, x1, y + 250], fill=HOT)
        else:
            d.rectangle([x0, y, x1, y + 250], outline=INK, width=2)
        col = BLACK if last else INK
        d.text((x0 + 22, y + 18), n, font=font("display", 44), fill=HOT if not last else BLACK)
        tracked(d, (x0 + 22, y + 96), h, font("display", 26), col, 0.0)
        for j, ln in enumerate(wrap(d, s, font("mono-r", 20), cw - 44)):
            d.text((x0 + 22, y + 140 + j * 28), ln, font=font("mono-r", 20), fill=(col if last else DIM))
    d.text((PAD, y + 290), foot, font=font("mono-r", 24), fill=DIM)
    wordmark(d, im)
    return im


def card_ash():
    im, d = frame(HOT)
    tracked(d, (PAD, PAD), "OFFICIAL TOKEN · SAME CONTRACTS · 90% OF ITS FEES TO ITS OWN POOL", font("mono", 24), BLACK, 0.14)
    y = title(d, PAD + 60, ["$ASH."], 260, BLACK, 0.9)
    lines = ["Launches on the same rules as every other token.", "Opening buy and every parameter published before the block.", "Only on the official site. Anything else with the name is fake."]
    f = font("mono-r", 30)
    y += 30
    for ln in lines:
        d.text((PAD, y), ln, font=f, fill=BLACK)
        y += 50
    logo = Image.open(os.path.join(ROOT, "assets", "ash-logo-512.png")).convert("RGBA")
    dark = Image.new("RGBA", logo.size, (17, 17, 17, 0))
    # flame in black on orange keeps the two-colour rule
    alpha = logo.split()[3]
    dark.putalpha(alpha)
    dark = dark.resize((300, 300), Image.LANCZOS)
    im.paste(dark, (W - PAD - 300, H - PAD - 300), dark)
    wordmark(d, im, color=BLACK)
    return im


def main():
    global FONT_DIR
    ap = argparse.ArgumentParser()
    ap.add_argument("--fonts", default=os.path.join(ROOT, "assets", "fonts"))
    ap.add_argument("--out", default=os.path.join(ROOT, "assets", "social"))
    a = ap.parse_args()
    FONT_DIR = a.fonts
    os.makedirs(a.out, exist_ok=True)
    cards = {
        "card-rules.png": card_rules,
        "card-vs.png": card_vs,
        "card-proof.png": card_proof,
        "card-ash.png": card_ash,
    }
    for name, fn in cards.items():
        fn().save(os.path.join(a.out, name), optimize=True)
        print("wrote", name)


if __name__ == "__main__":
    main()
