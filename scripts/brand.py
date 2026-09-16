"""Build the whole brand set from one source silhouette.

    python scripts/brand.py

Source: assets/ash-logo-eth-legacy.png (the original flame). Its ETH cutout is
filled and replaced by an arc: a round-capped half circle cut out of the lower
body of the flame (the user's design, 2026-09-16). Fire for the burn, an arc
for Arc; nothing else.
Outputs, all in assets/:
  ash-logo.png + -512/-256/-128/-64/-32   transparent flame with the arc cutout
  ash-avatar.png / -400 / -200            X avatar, dark background baked in, circle-safe
  ash-banner.png                          1536x512, flame left, sparks drifting right
  ash-x-header-b.png                      1500x500 X header with the slogan
  social/video/flame-loop-first-frame.png 1920x1080 first frame for the loop video
Text is rendered by us from assets/fonts (OFL). English only.
"""
import os
import random

import numpy as np
import scipy.ndimage as ndi
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
A = os.path.join(ROOT, "assets")
FONTS = os.path.join(A, "fonts")
HOT = (252, 82, 1)
HOT_LIGHT = (255, 179, 138)
BG = (21, 21, 20)
INK = (242, 242, 240)


def font(name, size, wght=None):
    f = ImageFont.truetype(os.path.join(FONTS, name), size)
    if wght is not None:
        try:
            f.set_variation_by_axes([wght, 100])  # Archivo axes: wght, wdth
        except Exception:
            pass
    return f


# ------------------------------------------------------------------ logo
def make_logo():
    src = Image.open(os.path.join(A, "ash-logo-eth-legacy.png")).convert("RGBA")
    alpha = np.array(src)[:, :, 3]
    solid = alpha > 127
    filled = ndi.binary_fill_holes(solid)
    holes = filled & ~solid
    ys, xs = np.where(holes)
    hx0, hx1, hy0, hy1 = xs.min(), xs.max(), ys.min(), ys.max()
    cx, cy = (hx0 + hx1) / 2, (hy0 + hy1) / 2
    box_w, box_h = (hx1 - hx0) * 0.80, (hy1 - hy0) * 0.86

    # the arc: a half circle (3 o'clock -> 6 -> 9) with round caps, drawn supersampled
    ss = 4
    S = alpha.shape[0] * ss
    ccx, ccy, r, stroke = 512 * ss, 586 * ss, 206 * ss, 118 * ss  # r is the stroke's centreline
    m = Image.new("L", (S, S), 0)
    dm = ImageDraw.Draw(m)
    R = r + stroke / 2  # PIL strokes inward from the bounding circle
    dm.arc([ccx - R, ccy - R, ccx + R, ccy + R], start=0, end=180, fill=255, width=stroke)
    for ex in (ccx - r, ccx + r):
        dm.ellipse([ex - stroke / 2, ccy - stroke / 2, ex + stroke / 2, ccy + stroke / 2], fill=255)
    glyph = np.array(m.resize(alpha.shape[::-1], Image.LANCZOS), dtype=np.float32) / 255.0

    # smooth edge of the filled silhouette: keep the original anti-aliasing outside, solid inside
    base = np.array(src)[:, :, 3].astype(np.float32) / 255.0
    base[filled] = 1.0  # also the half-transparent rim of the old cutout, or its outline ghosts through
    new_alpha = np.clip(base * (1.0 - glyph), 0, 1)
    out = np.zeros((alpha.shape[0], alpha.shape[1], 4), dtype=np.uint8)
    out[:, :, 0], out[:, :, 1], out[:, :, 2] = HOT
    out[:, :, 3] = (new_alpha * 255).astype(np.uint8)
    logo = Image.fromarray(out, "RGBA")
    logo.save(os.path.join(A, "ash-logo.png"))
    for sz in (512, 256, 128, 64, 32):
        logo.resize((sz, sz), Image.LANCZOS).save(os.path.join(A, f"ash-logo-{sz}.png"))
    print("logo: arc cutout centre (512, 586), centreline r 206, stroke 118")
    return logo



# ------------------------------------------------------------------ avatar
def make_avatar(logo):
    S = 1000
    im = Image.new("RGBA", (S, S), BG + (255,))
    mk = logo.crop(logo.getbbox())
    target_h = int(S * 0.62)
    mk = mk.resize((int(mk.width * target_h / mk.height), target_h), Image.LANCZOS)
    im.paste(mk, ((S - mk.width) // 2, (S - mk.height) // 2), mk)
    # nothing orange may fall outside the inscribed circle X will crop to
    arr = np.array(im)
    yy, xx = np.mgrid[0:S, 0:S]
    outside = (xx - S / 2) ** 2 + (yy - S / 2) ** 2 > (S / 2) ** 2
    orange = (arr[:, :, 0] > 200) & (arr[:, :, 1] < 120)
    assert int((orange & outside).sum()) == 0, "flame leaks outside the circle"
    im.convert("RGB").save(os.path.join(A, "ash-avatar.png"))
    for sz in (400, 200):
        im.convert("RGB").resize((sz, sz), Image.LANCZOS).save(os.path.join(A, f"ash-avatar-{sz}.png"))
    print("avatar: circle-safe")


# ------------------------------------------------------------------ sparks
def sparks(d, x0, x1, y_mid, n=110, seed=7, size=(4, 22), spread=(60, 190), light_every=3):
    """A trail of embers thinning out to the right: plain rhombi and dots, no ETH lines."""
    rnd = random.Random(seed)
    for i in range(n):
        t = rnd.random() ** 0.75
        x = x0 + (x1 - x0) * t
        sp = spread[0] + (spread[1] - spread[0]) * t
        y = y_mid + rnd.gauss(0, sp / 2.2) - 30 * t
        s = size[1] * (1 - t) ** 1.3 * (0.4 + rnd.random()) + size[0] * rnd.random()
        s = max(size[0] * 0.6, s)
        col = HOT_LIGHT if i % light_every == 0 else HOT
        if rnd.random() < 0.65:
            tilt = rnd.uniform(-0.25, 0.25) * s
            d.polygon([(x, y - s), (x + s * 0.58 + tilt, y), (x, y + s), (x - s * 0.58 + tilt, y)], fill=col)
        else:
            r = s * 0.3
            d.ellipse([x - r, y - r, x + r, y + r], fill=col)


def paste_flame(im, logo, x, y, h):
    flame = logo.crop(logo.getbbox())
    flame = flame.resize((int(flame.width * h / flame.height), h), Image.LANCZOS)
    im.paste(flame, (x, y), flame)
    return flame.width


# ------------------------------------------------------------------ banner / first frame
def make_banner(logo):
    W, H = 1536, 512
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    fw = paste_flame(im, logo, 60, 56, 400)
    sparks(d, 60 + fw - 10, 1060, H // 2 - 10, n=120, seed=11, size=(3, 16), light_every=4)
    im.save(os.path.join(A, "ash-banner.png"))
    # video first frame: same composition on 16:9
    F = Image.new("RGB", (1920, 1080), BG)
    F.paste(im.resize((1920, 640), Image.LANCZOS), (0, 220))
    os.makedirs(os.path.join(A, "social", "video"), exist_ok=True)
    F.save(os.path.join(A, "social", "video", "flame-loop-first-frame.png"))
    print("banner + first frame")


# ------------------------------------------------------------------ X header
def make_header(logo):
    W, H = 1500, 500
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    paste_flame(im, logo, 1240, 90, 320)
    # embers rise up and left from the flame tip, staying above the slogan (text ends x≈780, y≥168)
    sparks(d, 1250, 880, 120, n=70, seed=5, size=(3, 14), spread=(30, 110), light_every=4)
    title = font("ArchivoBlack-Regular.ttf", 58)
    sub = font("Archivo[wdth,wght].ttf", 30, wght=500)
    d.text((95, 168), "NOT DEFLATION.", font=title, fill=INK)
    d.text((95, 234), "IT'S A WITHDRAWAL.", font=title, fill=HOT)
    d.text((97, 312), "Trading fees fill a pool. Burn your $ASH, withdraw your share.", font=sub, fill=(200, 200, 198))
    im.save(os.path.join(A, "ash-x-header-b.png"))
    print("header")


if __name__ == "__main__":
    logo = make_logo()
    make_avatar(logo)
    make_banner(logo)
    make_header(logo)
