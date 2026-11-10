#!/usr/bin/env python3
"""site/og.png, the picture a link to dangoai.org shows (1200 × 630): the wordmark, the line,
and the office with its cast (docs/images/office.png, from tools/readme_images.py). English,
like the site's front page (2026-11-10, user: 「官网首页应该是英文的」).

  python3 -I tools/og_image.py
"""
import site
import sys
from pathlib import Path

sys.path.append(site.getusersitepackages())
from PIL import Image, ImageDraw, ImageFilter, ImageFont  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
W, H = 1200, 630
INK, SUB = (28, 28, 28), (95, 96, 104)


def sf(size, weight):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    f.set_variation_by_axes([100, min(96, max(17, size)), 400, weight])
    return f


og = Image.new("RGBA", (W, H), (242, 243, 245, 255))
d = ImageDraw.Draw(og)

logo = Image.open(REPO / "docs/images/logo-light.png").convert("RGBA")
logo = logo.crop(logo.split()[-1].getbbox())
logo = logo.resize((round(logo.width * 40 / logo.height), 40), Image.LANCZOS)
og.alpha_composite(logo, (64, 150))

y = 232
for line in ("Turn your AI into", "a team you can see."):
    d.text((62, y), line, font=sf(47, 800), fill=INK)
    y += 58
y += 14
for line in ("Your AI team’s little office on your Mac.", "Who’s working, what got done, at a glance."):
    d.text((64, y), line, font=sf(21, 400), fill=SUB)
    y += 34
chip = "Free · macOS & Windows"
cf = sf(18, 500)
cw = d.textlength(chip, font=cf)
d.rounded_rectangle((64, y + 22, 64 + cw + 32, y + 22 + 38), 19, fill=(255, 255, 255, 255))
d.text((80, y + 31), chip, font=cf, fill=SUB)

# the office on the right, as a card with a soft shadow
room = Image.open(REPO / "docs/images/office.png").convert("RGBA")
cw = 520                                            # the whole room, everyone in it
ch = round(room.height * cw / room.width)
room = room.resize((cw, ch), Image.LANCZOS)
mask = Image.new("L", (cw, ch), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, cw - 1, ch - 1), 30, fill=255)
room.putalpha(mask)
sh = Image.new("RGBA", (cw + 160, ch + 160), (0, 0, 0, 0))
sh.paste((20, 24, 40, 70), (80, 80), mask)
sh = sh.filter(ImageFilter.GaussianBlur(28))
px, py = W - cw - 40, (H - ch) // 2 + 10
og.alpha_composite(sh, (px - 80, py - 80 + 16))
og.alpha_composite(room, (px, py))
og.convert("RGB").save(REPO / "site/og.png", optimize=True)
print("wrote site/og.png")
