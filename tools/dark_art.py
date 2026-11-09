#!/usr/bin/env python3
"""The dark theme's 团子: B01W, the body white (user, 2026-11-07: 「dark的
theme是白团子」). Its outline stays dark, its black fill becomes white
keeping its shading, its gloss stays the brightest; eyes and accessories go
on it unchanged. (The office's dusk and night pictures used to be made here
from the day one; since 2026-11-09 they are the designer's own, from the
website: tools/office_art.py.)

  python3 -I tools/dark_art.py          (from the repository root)

Needs numpy and Pillow.
"""
import site
import sys

sys.path.append(site.getusersitepackages())
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "apps" / "widget" / "assets"


def luma(a):
    return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]


def white_body():
    a = np.asarray(Image.open(ART / "dango" / "B01.png").convert("RGBA")).astype(float)
    # Outline (luma < 12) dark, the fill (20–45) white with its shading, the gloss white.
    v = np.interp(luma(a), [0, 12, 20, 45, 60, 255], [30, 34, 226, 251, 255, 255])
    a[..., 0] = a[..., 1] = v * 0.995
    a[..., 2] = v
    Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).save(ART / "dango" / "B01W.png")


if __name__ == "__main__":
    white_body()
    print("wrote dango/B01W.png")
