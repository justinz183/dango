#!/usr/bin/env python3
"""The dark theme's 团子 and the office's times of day, made from the light
theme's art so the shapes stay the same (user, 2026-11-07: 「dark的theme是
白团子」; the office follows the Mac's clock in both themes, 「办公室应该随着
系统时间发生变化」):

- apps/widget/assets/dango/B01W.png: the 团子's body white. Its outline
  stays dark, its black fill becomes white keeping its shading, its gloss
  stays the brightest; eyes and accessories go on it unchanged.
- apps/widget/assets/theme-b/room-dusk.png and room-front-dusk.png: the
  office at sunset and sunrise, warm, the sky purple to orange.
- apps/widget/assets/theme-b/room-night.png and room-front-night.png: the
  office at night, as the design pack's night mode says ("filter + a
  window sky of its own; geometry fixed"): the room graded dark blue, the
  window's glass a night sky with stars, the sun a crescent, the trees dark.

  python3 -I tools/dark_art.py          (from the repository root)

Needs numpy and Pillow.
"""
import site
import sys

sys.path.append(site.getusersitepackages())
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

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


def window(room):
    """The window's parts in room.png: glass, trees, clouds and the sun's disc."""
    H, W = room.shape[:2]
    r, g, b = room[..., 0], room[..., 1], room[..., 2]
    yy, xx = np.mgrid[0:H, 0:W]
    # The window, in points of the app's 392 × 178 room, then in room.png's pixels.
    k = W / 392
    x0, y0, x1, y1 = (round(v * k) for v in (99.5, 9, 203.5, 70))
    box = (xx >= x0) & (xx <= x1) & (yy >= y0) & (yy <= y1)
    wood = (r - b > 35) & (r > g) & (g > b) & (r > 120)
    total = r + g + b
    dark = total < 200
    # The sun's pale yellow only (the frame's wood is darker), so its disc
    # stays off the frame and the mullions.
    sun = box & (r > 245) & (g > 212) & (b > 130) & (b < 175)
    sy, sx = np.where(sun)
    cx, cy = (sx.min() + sx.max()) / 2, (sy.min() + sy.max()) / 2
    rad = (sx.max() - sx.min()) / 2
    disc = box & ((xx - cx) ** 2 + (yy - cy) ** 2 <= (rad + 1.25 * k) ** 2) & ~(wood & (g < 200)) & ~dark
    glass = (box & ~wood & ~dark) | disc
    tree = glass & (g > r + 15) & (g > b - 10) & (b < 200)
    cloud = glass & (r > 225) & (g > 225) & (b > 225)
    # How much of each glass pixel is sky: the frame's outline is drawn
    # anti-aliased into the glass, so its edge pixels are part sky, part line.
    sky = np.where(disc | tree | cloud, 1.0, np.clip((total - 200) / 400.0, 0, 1))
    f = np.clip((yy - y0) / (y1 - y0), 0, 1)
    return dict(k=k, box=(x0, y0, x1, y1), glass=glass, tree=tree, cloud=cloud, disc=disc, sky=sky, sun=(cx, cy, rad), f=f, xx=xx, yy=yy)


def paint_sky(out, w, sky):
    """Puts the new sky on the glass, keeping the frame's outline whole."""
    a = (w["sky"] * w["glass"])[..., None]
    out[..., :3] = a * sky + (1 - a) * out[..., :3]


def smooth(size, draw):
    """Draws at 4× and scales down, so the moon and stars have soft edges."""
    big = Image.new("RGBA", (size[0] * 4, size[1] * 4), (0, 0, 0, 0))
    draw(ImageDraw.Draw(big), 4)
    return big.resize(size, Image.LANCZOS)


def night(rgb):
    return rgb * np.array([0.30, 0.33, 0.46]) + np.array([8, 10, 20])


def dusk(rgb):
    return rgb * np.array([0.94, 0.80, 0.72]) + np.array([10, 4, 8])


def night_room():
    room = np.asarray(Image.open(ART / "theme-b" / "room.png").convert("RGBA")).astype(float)
    w = window(room)
    glass, tree, cloud, disc, f = w["glass"], w["tree"], w["cloud"], w["disc"], w["f"]
    x0, y0, x1, y1 = w["box"]
    cx, cy, rad = w["sun"]
    k = w["k"]
    out = room.copy()
    out[..., :3] = night(room[..., :3])
    sky = np.stack([14 + 22 * f, 24 + 30 * f, 58 + 50 * f], -1)
    paint_sky(out, w, sky)
    out[cloud, :3] = sky[cloud] * 0.6 + np.array([60, 66, 92]) * 0.4
    out[tree, :3] = np.array([16, 30, 34])
    img = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))
    rng = np.random.default_rng(7)
    stars = []
    for _ in range(38):
        x, y = int(rng.integers(x0 + k, x1 - k)), int(rng.integers(y0 + k, y0 + 46 * k))
        s, c = float(rng.choice([0.5, 0.5, 0.8])) * k, int(rng.integers(190, 255))
        far = (x - cx) ** 2 + (y - cy) ** 2 > (rad + 2 * k) ** 2
        if glass[y, x] and not tree[y, x] and not cloud[y, x] and far:
            stars.append((x, y, s, c))

    def sky_things(d, k):
        for x, y, s, c in stars:
            d.ellipse([(x - s / 2) * k, (y - s / 2) * k, (x + s / 2) * k, (y + s / 2) * k], fill=(c, c, 255, 255))
        mr = rad * 0.72
        d.ellipse([(cx - mr) * k, (cy - mr) * k, (cx + mr) * k, (cy + mr) * k], fill=(250, 240, 200, 255))
        d.ellipse([(cx - mr * 0.45) * k, (cy - mr * 1.2) * k, (cx + mr * 1.55) * k, (cy + mr * 0.8) * k], fill=(0, 0, 0, 0))
    # The crescent's bite is cut on its own layer, then the layer goes on the sky.
    moon = smooth(img.size, sky_things)
    Image.alpha_composite(img, moon).save(ART / "theme-b" / "room-night.png")
    front = np.asarray(Image.open(ART / "theme-b" / "room-front.png").convert("RGBA")).astype(float)
    front[..., :3] = night(front[..., :3])
    Image.fromarray(np.clip(front, 0, 255).astype(np.uint8)).save(ART / "theme-b" / "room-front-night.png")


def dusk_room():
    """Sunset (and sunrise): the room warm and a little dim, the sun gone
    below the trees, the sky purple above and orange at the horizon, so the
    day's sun fades out into it and the night's moon fades in over it."""
    room = np.asarray(Image.open(ART / "theme-b" / "room.png").convert("RGBA")).astype(float)
    w = window(room)
    glass, tree, cloud, f, xx, yy = w["glass"], w["tree"], w["cloud"], w["f"], w["xx"], w["yy"]
    x0, y0, x1, y1 = w["box"]
    k = w["k"]
    out = room.copy()
    out[..., :3] = dusk(room[..., :3])
    top, mid, low = np.array([92, 96, 168]), np.array([236, 150, 140]), np.array([255, 190, 112])
    t = f[..., None]
    sky = np.where(t < 0.55, top + (mid - top) * (t / 0.55), mid + (low - mid) * ((t - 0.55) / 0.45))
    # The glow where the sun went down, behind the trees on the right.
    gx, gy = x1 - 25 * k, y1 + 3 * k
    glow = np.exp(-(((xx - gx) / (35 * k)) ** 2 + ((yy - gy) / (23 * k)) ** 2))[..., None]
    sky = sky * (1 - 0.55 * glow) + np.array([255, 214, 140]) * 0.55 * glow
    paint_sky(out, w, sky)
    out[cloud, :3] = sky[cloud] * 0.45 + np.array([255, 204, 196]) * 0.55
    out[tree, :3] = np.array([58, 64, 66])
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(ART / "theme-b" / "room-dusk.png")
    front = np.asarray(Image.open(ART / "theme-b" / "room-front.png").convert("RGBA")).astype(float)
    front[..., :3] = dusk(front[..., :3])
    Image.fromarray(np.clip(front, 0, 255).astype(np.uint8)).save(ART / "theme-b" / "room-front-dusk.png")


if __name__ == "__main__":
    white_body()
    night_room()
    dusk_room()
    print("wrote dango/B01W.png and theme-b/room-{night,dusk}.png, room-front-{night,dusk}.png")
