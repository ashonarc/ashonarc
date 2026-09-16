# Brand kit

The flame silhouette dates from 2026-09-08. On 2026-09-16 the cut-out at its centre changed from an
Ethereum diamond to a round-capped arc: the project moved to Arc and the pools pay USDC. Fire for the burn,
an arc for Arc, nothing else. The whole set is generated from the silhouette by `scripts/brand.py`
(logo sizes, avatar, header, banner, video first frame); the social cards by `scripts/tweet_cards.py` and
`scripts/card_curve.py`; the fonts in `fonts/` are OFL. Change one thing, run the scripts, everything re-renders.

## Files

| File | Use |
| --- | --- |
| `ash-logo.png` | Primary mark, 1024×1024, real alpha |
| `ash-logo-512/256/128/64/32.png` | Exports for the site and exchanges |
| `ash-avatar.png`, `-400`, `-200` | X avatar: dark background baked in, mark sized to survive the circular crop |
| `ash-x-header-b.png` | X header with the slogan, 1500×500 |
| `ash-banner.png` | General banner, 1536×512, right half left empty for a title |
| `ash-avatar-circle-preview.png`, `ash-x-header-safezones.png` | Previews of the crop and the safe zones — reference only, never upload |
| `social/card-*.png` | Tweet cards; `social/video/` the flame loop and its first frame |
| `ash-logo-eth-legacy.png` | The old silhouette, used only as the generator's source |

Other `ash-logo-a-*`, `ash-break-*`, `-alt` files are rejected explorations, kept for reference.

## Colours

| | |
| --- | --- |
| Ember orange | `#FC5201` |
| Near-black | `#151514` |
| Off-white | `#F2F2F0` |

Flat colours only, no gradients.

## Arc geometry (1024 canvas)

Centre (512, 586), centre-line radius 206, stroke 118, round caps — hard-coded in `scripts/brand.py`.
The mark does not use the USDC roundel: that is Circle's, and it would read as an endorsement.

## Why the avatar is a separate file

X crops avatars to a circle and pads with its own colour, so the transparent `ash-logo.png` would have its
edges touching the circle and the corners clipped. `ash-avatar-*.png` bakes the dark background in and scales
the flame to 62% of the canvas so the whole mark sits inside the inscribed circle (checked by script: zero
orange pixels outside it). Upload `ash-avatar-400.png`.

## Header constraints

Two things X does to headers, both accounted for in `ash-x-header-b.png`:

1. The avatar covers the bottom-left corner (a circle of about 200 px centred near (133, 500)).
2. Phones crop roughly 64 px off the top and bottom.

Text sits in the left-middle band, between the avatar and the crop zones. All copy is rendered by script from
Archivo Black and IBM Plex Mono — the same fonts as the site — never by an image model.

## Copy rules

Everything written on an asset must be verifiable on-chain. No "guaranteed", "safe", "risk-free" or "audited";
no price promises; never describe the burn as deflation or as something that pushes the price. Burning `q` of
supply `S` against pool `R` pays `q·R/S` and leaves everyone else's floor at `R/S` — it is an exit right with an
on-chain floor, and that is all the copy claims.
