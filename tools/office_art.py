#!/usr/bin/env python3
"""The office the apps draw, from the designer's office on the website
(site/img/office: three backgrounds for day, dusk and night, the furniture
behind the 团子 and the furniture in front of them; user, 2026-11-09:
「现在的网站的办公室环境渲染的很好啊…app的办公室能不能也这样」「不要taller」).

The website's room is nearly square; the apps' strip is 392 × 178 points.
So the band from the window's top to the sofa's feet is kept whole and the
wall and floor are carried on sideways (each row's own colour) instead of
cropping the furniture. Written under the old names, which both apps read:

  room.png, room-dusk.png, room-night.png   background + the furniture behind
  room-front.png (and -dusk, -night)        the furniture in front: the same
                                            picture at every hour

  python3 -I tools/office_art.py          (from the repository root)

Needs Pillow and numpy. The seats and desks in theme.swift `arrangement()`
and apps/windows/ui/panel.js are measured in these pictures' points
(k = 178 / band height).
"""
import site
import sys

sys.path.append(site.getusersitepackages())
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "site" / "img" / "office"
OUT = ROOT / "apps" / "widget" / "assets" / "theme-b"

# In the website's 1680 × 1520 pixels: the window's top is at 279, the sofa's
# feet end at 1211; the outer 6 columns are the picture's rounded border.
TOP, BOTTOM, EDGE = 249, 1241, 6
ASPECT = 392 / 178


def load(name):
    a = np.asarray(Image.open(SRC / f"{name}.webp").convert("RGBA"))
    return a[TOP:BOTTOM, EDGE:a.shape[1] - EDGE]


def widen(a, opaque):
    """Carries each row's edge colour out to the strip's width (clear for
    the furniture layers, which have nothing at their edges)."""
    h, w = a.shape[:2]
    width = round(h * ASPECT)
    left = (width - w) // 2
    right = width - w - left
    if opaque:
        lc = np.repeat(a[:, :1], left, axis=1)
        rc = np.repeat(a[:, -1:], right, axis=1)
    else:
        lc = np.zeros((h, left, 4), a.dtype)
        rc = np.zeros((h, right, 4), a.dtype)
    return np.concatenate([lc, a, rc], axis=1), left


def main():
    back, _ = widen(load("back"), False)
    front, left = widen(load("front"), False)
    behind = Image.fromarray(back)
    for when, name in [("day", "room"), ("dusk", "room-dusk"), ("night", "room-night")]:
        bg, _ = widen(load(f"bg-{when}"), True)
        img = Image.fromarray(bg)
        img.alpha_composite(behind)
        img.save(OUT / f"{name}.png", optimize=True)
    for name in ["room-front", "room-front-dusk", "room-front-night"]:
        Image.fromarray(front).save(OUT / f"{name}.png", optimize=True)
    h = BOTTOM - TOP
    k = 178 / h
    print(f"wrote room*.png and room-front*.png, {front.shape[1]} × {h} px")
    print(f"website x → points: (x - {EDGE} + {left}) × {k:.5f};  y → points: (y - {TOP}) × {k:.5f}")


if __name__ == "__main__":
    main()
