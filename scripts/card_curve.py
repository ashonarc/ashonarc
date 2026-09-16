"""Social card: the launch curve, drawn from the real formula. Same style as tweet_cards.py.

    python scripts/card_curve.py        -> assets/social/card-curve.png
"""
import os
from PIL import Image, ImageDraw, ImageFont

W, H = 1600, 900
PAD = 80
BG, INK, HOT, DIM, MUTE = (21, 21, 20), (242, 242, 240), (252, 82, 1), (140, 140, 138), (92, 92, 90)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT_DIR = os.path.join(ROOT, "assets", "fonts")
P, G, SUPPLY = 5_000.0, 10_000.0, 1e9  # production parameters, USDC / tokens


def font(name, size):
    return ImageFont.truetype(os.path.join(FONT_DIR, name), size)


def tracked(d, xy, text, f, fill, tracking=0.12):
    x, y = xy
    for ch in text:
        d.text((x, y), ch, font=f, fill=fill)
        x += d.textlength(ch, font=f) + f.size * tracking
    return x


def price_per_1m(real):
    """Spot price on the curve after `real` USDC of net buys, in USDC per 1M tokens."""
    return (P + real) ** 2 / (P * SUPPLY) * 1e6


im = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(im)
display, mono, mono_r = font("ArchivoBlack-Regular.ttf", 20), font("IBMPlexMono-Medium.ttf", 24), font("IBMPlexMono-Regular.ttf", 26)

tracked(d, (PAD, PAD), "ASHONARC · LAUNCHPAD ON ARC · FIXED IN THE CONTRACT", mono, HOT)
h1 = font("ArchivoBlack-Regular.ttf", 96)
d.text((PAD - 4, PAD + 50), "OPENS AT 5.", font=h1, fill=INK)
d.text((PAD - 4, PAD + 150), "GRADUATES AT 45.", font=h1, fill=HOT)
d.text((PAD, PAD + 268), "USDC per 1M tokens, along one constant-product curve", font=mono_r, fill=DIM)

# ---- the curve, drawn from the formula: x from 0 to G (real reserve), y = price
cx0, cy0, cw, ch = PAD, 386, W - 2 * PAD - 520, 268
d.rectangle([cx0, cy0, cx0 + cw, cy0 + ch], outline=INK, width=2)
pts = []
pmax = price_per_1m(G)
for i in range(0, 201):
    r = G * i / 200
    x = cx0 + cw * i / 200
    y = cy0 + ch - ch * (price_per_1m(r) / pmax) * 0.92 - 8
    pts.append((x, y))
d.line(pts, fill=HOT, width=8)
# graduation marker
gx, gy = pts[-1]
d.ellipse([gx - 12, gy - 12, gx + 12, gy + 12], fill=INK)
d.text((cx0, cy0 + ch + 14), "0 USDC IN THE CURVE", font=font("IBMPlexMono-Medium.ttf", 20), fill=DIM)
lbl = "10,000 USDC → GRADUATION"
d.text((cx0 + cw - d.textlength(lbl, font=font("IBMPlexMono-Medium.ttf", 20)), cy0 + ch + 14), lbl, font=font("IBMPlexMono-Medium.ttf", 20), fill=HOT)

# ---- facts, right column
fx, fy = cx0 + cw + 60, cy0 - 6
rows = [
    ("OPENING PRICE", "5 USDC / 1M tokens"),
    ("GRADUATION", "10,000 USDC of real reserve"),
    ("PRICE AT GRADUATION", "45 USDC / 1M · ×9 from open"),
    ("MARKET CAP THEN", "≈ 45,000 USDC"),
    ("AFTER", "reserve + tokens lock into Uniswap v4; unsold rest burned"),
]
small = font("IBMPlexMono-Medium.ttf", 18)
body = font("IBMPlexMono-Regular.ttf", 24)
for k, v in rows:
    tracked(d, (fx, fy), k, small, HOT)
    fy += 28
    words, line, lines = v.split(" "), "", []
    for w_ in words:
        t = (line + " " + w_).strip()
        if d.textlength(t, font=body) <= W - PAD - fx or not line:
            line = t
        else:
            lines.append(line)
            line = w_
    lines.append(line)
    for ln in lines:
        d.text((fx, fy), ln, font=body, fill=INK)
        fy += 32
    fy += 12

# ---- footer
logo = Image.open(os.path.join(ROOT, "assets", "ash-logo-64.png")).convert("RGBA").resize((44, 44), Image.LANCZOS)
im.paste(logo, (PAD, H - PAD - 40), logo)
d.text((PAD + 56, H - PAD - 38), "ASHONARC", font=font("ArchivoBlack-Regular.ttf", 28), fill=INK)
slogan = "· SAME CURVE FOR EVERY TOKEN, INCLUDING $ASH"
sf = font("IBMPlexMono-Medium.ttf", 18)
tracked(d, (PAD + 56 + d.textlength("ASHONARC", font=font("ArchivoBlack-Regular.ttf", 28)) + 16, H - PAD - 30), slogan, sf, MUTE, tracking=0.08)

out = os.path.join(ROOT, "assets", "social", "card-curve.png")
im.save(out, optimize=True)
print(out)
