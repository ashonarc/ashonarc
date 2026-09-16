"""Social share card (1200x630) in the same style as assets/ash-x-header-b.png.

    python scripts/og_card.py            -> web/public/og.png
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
A = os.path.join(ROOT, "assets")
W, H = 1200, 630
BG, INK, HOT, DIM = (21, 21, 20), (242, 242, 240), (252, 82, 1), (140, 140, 138)

im = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(im)
FLAME = 300
flame = Image.open(os.path.join(A, "ash-logo-512.png")).convert("RGBA").resize((FLAME, FLAME), Image.LANCZOS)
im.paste(flame, (W - FLAME - 60, (H - FLAME) // 2), flame)
x = 72
max_w = W - FLAME - 60 - x - 36


def fit(path, text, start):
    size = start
    while size > 20:
        f = ImageFont.truetype(path, size)
        if f.getlength(text) <= max_w:
            return f
        size -= 2
    return f


black_path = os.path.join(A, "fonts", "ArchivoBlack-Regular.ttf")
mono = ImageFont.truetype(os.path.join(A, "fonts", "IBMPlexMono-Medium.ttf"), 26)
black = fit(black_path, "IT'S A WITHDRAWAL.", 78)
d.text((x, 150), "LAUNCHPAD · BURN-TO-WITHDRAW · USDC · ARC", font=mono, fill=INK)
d.text((x, 215), "NOT DEFLATION.", font=black, fill=INK)
d.text((x, 215 + black.size + 14), "IT'S A WITHDRAWAL.", font=black, fill=HOT)
d.text((x, 420), "Trading fees fill a pool. Burn your $ASH,", font=mono, fill=DIM)
d.text((x, 456), "withdraw your share.", font=mono, fill=DIM)
out = os.path.join(ROOT, "web", "public", "og.png")
im.save(out, optimize=True)
print(out, im.size)
