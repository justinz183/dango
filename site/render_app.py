#!/usr/bin/env python3
"""The website's product pictures, rendered by the app itself (user,
2026-11-09: 「网站上有个问题就是截图还是老的，我要你用新的产品截图更新网站」):
the panel and the corner 团子 in the six languages, into site/img/app/.

SAMPLE data: this Mac's numbers scaled by SCALE, with every session title
and project name dropped, so the site shows no one's real totals or
projects; light theme, at noon, with a cast in the office.

Run from the repository root after `cargo build --release -p cli` and
`apps/widget/build.sh`:

  python3 -I site/render_app.py

Reads $DANGO_HOME (default ~/.dango) only through a copy; writes nothing
there. Needs Pillow (for WebP).
"""
import json
import os
import re
import site
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.append(site.getusersitepackages())
from PIL import Image  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "site" / "img" / "app"
WIDGET = REPO / "target" / "release" / "dango-widget"
DANGO = REPO / "target" / "release" / "dango"
SOURCE = Path(os.environ.get("DANGO_HOME", Path.home() / ".dango"))
SCALE = 0.6
LANGS = ["zh", "en", "ko", "ja", "fr", "es"]
# Who is in the office: two at the desks (one waving), one asleep on the
# sofa, one waiting for an approval.
CAST = "working,happy,sleeping,waiting"

SCALED = re.compile(r"(usd|cost|tokens)|^(hours|person_days|minutes|day_usd)$", re.I)
PRIVATE = {"projects", "title", "titles", "project", "cwd"}


def sample(v, key=""):
    """Numbers scaled, titles and project names gone."""
    if isinstance(v, dict):
        return {k: sample(x, k) for k, x in v.items() if k not in PRIVATE and not (k == "sessions" and isinstance(x, list))}
    if isinstance(v, list):
        if key in ("hours", "by_hour") and all(isinstance(x, (int, float)) for x in v):
            return [x * SCALE for x in v]
        return [sample(x, key) for x in v]
    if isinstance(v, (int, float)) and not isinstance(v, bool) and SCALED.search(key):
        return type(v)(v * SCALE) if isinstance(v, float) else round(v * SCALE)
    return v


def run(args, home):
    env = dict(os.environ, DANGO_HOME=str(home))
    subprocess.run([str(a) for a in args], check=True, cwd=REPO, env=env, stdout=subprocess.DEVNULL)


def webp(png, out, width):
    im = Image.open(png).convert("RGBA")
    im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
    im.save(out, "WEBP", quality=88, method=6)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    light = ["--light", "--hour", "12"]
    with tempfile.TemporaryDirectory() as tmp:
        for lang in LANGS:
            home = Path(tmp) / lang
            home.mkdir()
            src, dst = sqlite3.connect(SOURCE / "data.db"), sqlite3.connect(home / "data.db")
            src.backup(dst)
            src.close()
            dst.close()
            run([DANGO, "lang", lang], home)
            widget = home / "widget.json"
            widget.write_text(json.dumps(sample(json.loads(widget.read_text())), ensure_ascii=False))
            panel, pet = home / "panel.png", home / "pet.png"
            run([WIDGET, "--snapshot-dashboard", panel, "--range", 7, "--office", 4, "--statuses", CAST, "--scale", 2, *light], home)
            run([WIDGET, "--snapshot-pet", pet, "--state", "working", "--job", "swe", "--receipt", "--scale", 2, *light], home)
            webp(panel, OUT / f"panel-{lang}.webp", 880)
            webp(pet, OUT / f"pet-{lang}.webp", 460)
    print(f"wrote {len(LANGS) * 2} pictures to {OUT}")


if __name__ == "__main__":
    main()
