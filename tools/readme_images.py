#!/usr/bin/env python3
"""The README's pictures, rendered by the app itself (docs/images):

  office.png          the office with a cast (light, at noon)
  crew.jpg            the 20 job dangos
  desk-<lang>.jpg     the dango in the corner and the panel it opens
  card-<lang>.jpg     the ABTI card
  share-<lang>.jpg    last week's share card

for the six README languages. SAMPLE data, as on the website (site/render_app.py `sample`):
this Mac's numbers × 0.6 with every session title and project name dropped. ~/.dango is only
read, through a SQLite backup into a temporary folder.

Run from the repository root after `cargo build --release -p cli` and `apps/widget/build.sh`:

  python3 -I tools/readme_images.py

(2026-11-10, user: the README's product picture had black corners and still showed the old
office and the arrow logo.)
"""
import datetime
import importlib.util
import json
import os
import site
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.append(site.getusersitepackages())
from PIL import Image, ImageDraw, ImageFilter  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "docs" / "images"
WIDGET = Path(os.environ.get("DANGO_WIDGET", REPO / "target/release/dango-widget"))
DANGO = REPO / "target/release/dango"
SOURCE = Path(os.environ.get("DANGO_HOME", Path.home() / ".dango"))
LANGS = ["en", "zh", "ko", "ja", "fr", "es"]
LIGHT = ["--light", "--hour", "12"]

spec = importlib.util.spec_from_file_location("render_app", REPO / "site/render_app.py")
render_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render_app)
sample = render_app.sample

# The office's cast: who sits where comes from their state (theme.swift `arrangement`).
CAST = [("designer", "waiting"), ("writer", "idle"), ("research", "sleeping"), ("video", "sleeping"), ("swe", "working"), ("data", "working")]
# The 20 jobs in the order the website shows them, as theme.swift `packRoles` dresses them.
ROLES = ["R06", "R19", "R09", "R07", "R04", "R18", "R08", "R02", "R03", "R05",
         "R11", "R21", "R13", "R14", "R15", "R16", "R01", "R12", "R17", "R20"]


def run(args, home, stdout=None):
    env = dict(os.environ, DANGO_HOME=str(home))
    return subprocess.run([str(a) for a in args], check=True, cwd=REPO, env=env,
                          stdout=stdout if stdout is not None else subprocess.DEVNULL)


def jpg(im, out, quality=88):
    bg = Image.new("RGB", im.size, (255, 255, 255))
    bg.paste(im, mask=im.split()[-1] if im.mode == "RGBA" else None)
    bg.save(out, "JPEG", quality=quality, optimize=True, progressive=True)


def rounded(im, r):
    """The picture with rounded corners (transparent outside them)."""
    im = im.convert("RGBA")
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width - 1, im.height - 1), r, fill=255)
    a = Image.composite(im.split()[-1], Image.new("L", im.size, 0), mask)
    im.putalpha(a)
    return im


def shadowed(canvas, im, x, y, blur=40, dy=18, alpha=60):
    sh = Image.new("RGBA", (im.width + blur * 4, im.height + blur * 4), (0, 0, 0, 0))
    sh.paste((20, 24, 40, alpha), (blur * 2, blur * 2), im.split()[-1])
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(sh, (x - blur * 2, y - blur * 2 + dy))
    canvas.alpha_composite(im, (x, y))


def gradient(w, h):
    """The desktop behind the dango: the website's soft blue → lilac → peach."""
    stops = [(0.0, (220, 231, 247)), (0.55, (238, 232, 246)), (1.0, (249, 231, 223))]
    g = Image.new("RGB", (w, h))
    px = g.load()
    for yy in range(h):
        for xx in range(w):
            u = (xx / w + yy / h) / 2
            for (a, ca), (b, cb) in zip(stops, stops[1:]):
                if a <= u <= b:
                    k = (u - a) / (b - a)
                    px[xx, yy] = tuple(round(ca[i] + (cb[i] - ca[i]) * k) for i in range(3))
                    break
    return g.convert("RGBA")


def widget_json(home, lang):
    """widget.json in `lang`, sampled, with the office's cast and today = the last day with work."""
    run([DANGO, "lang", lang], home)
    w = sample(json.loads((home / "widget.json").read_text()))
    days = list(w["days"])
    while days and days[-1]["usd"] == 0:
        days.pop()
    last = days[-1]
    w["days"] = days
    w["today"] = {"usd": last["usd"], "cost": last["cost"], "hours": last["hours"], "person_days": last["hours"] / 8,
                  "leverage": last["usd"] / last["cost"] if last["cost"] else None}
    jobs = {j["id"]: j for j in w["occupations"]}
    now = int(datetime.datetime.now().timestamp() * 1000)
    w["office"] = [{"id": i, "name": jobs[i]["name"], "color": jobs[i].get("color", "#888888"), "scene": "desk", "helpers": 0, "usd": 0.0,
                    "working": st == "working", "status": "waiting" if st == "waiting" else None, "status_since": now - 60000 if st == "waiting" else None,
                    "since": now - {"working": 1, "waiting": 2, "idle": 12, "sleeping": 120}[st] * 60000} for i, st in CAST]
    (home / "widget.json").write_text(json.dumps(w, ensure_ascii=False))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    today = datetime.date.today()
    last_sunday = today - datetime.timedelta(days=(today.weekday() + 1) % 7 or 7)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        home = tmp / "home"
        home.mkdir()
        src, dst = sqlite3.connect(SOURCE / "data.db"), sqlite3.connect(home / "data.db")
        src.backup(dst)
        src.close()
        dst.close()

        # The office and the crew have no words in them.
        widget_json(home, "en")
        run([WIDGET, "--snapshot-office", tmp / "office.png", "--jobs", ",".join(i for i, _ in CAST),
             "--statuses", ",".join(s for _, s in CAST), "--scale", 5, "--t", 0.9, *LIGHT], home)
        office = Image.open(tmp / "office.png").convert("RGBA")
        office = office.resize((1960, office.height * 1960 // office.width), Image.LANCZOS)
        office.save(OUT / "office.png", optimize=True)        # PNG: its rounded corners stay clear on a dark page
        cells = []
        for r in ROLES:
            run([WIDGET, "--snapshot-dango", tmp / f"{r}.png", "--role", r, "--width", 300], home)
            cells.append(Image.open(tmp / f"{r}.png").convert("RGBA"))
        cw, ch = 207, max(c.height for c in cells) * 207 // 300
        crew = Image.new("RGBA", (cw * 10 + 32, ch * 2 + 40), (246, 246, 247, 255))
        for k, c in enumerate(cells):
            c = c.resize((cw, c.height * cw // c.width), Image.LANCZOS)
            crew.alpha_composite(c, (16 + (k % 10) * cw, 20 + (k // 10) * ch + (ch - c.height)))
        jpg(crew, OUT / "crew.jpg")

        bg = gradient(1800, 1120)
        for lang in LANGS:
            widget_json(home, lang)
            # The dango in the corner, with what it just earned; and the panel, cut below the ABTI card.
            run([WIDGET, "--snapshot-pet", tmp / "pet.png", "--state", "working", "--job", "swe", "--receipt", "--scale", 4, *LIGHT], home)
            run([WIDGET, "--snapshot-dashboard", tmp / "panel.png", "--range", 7, "--scale", 2, *LIGHT], home)
            pet = Image.open(tmp / "pet.png").convert("RGBA")
            panel = Image.open(tmp / "panel.png").convert("RGBA")
            panel = rounded(panel.crop((0, 0, panel.width, PANEL_CUT)), 104)
            panel = panel.resize((panel.width * 700 // panel.width, panel.height * 700 // panel.width), Image.LANCZOS)
            desk = bg.copy()
            shadowed(desk, panel, 1800 - 700 - 90, (1120 - panel.height) // 2)
            pet = pet.resize((pet.width * 620 // pet.width, pet.height * 620 // pet.width), Image.LANCZOS)
            desk.alpha_composite(pet, (130, 1120 - pet.height - 90))
            jpg(desk, OUT / f"desk-{lang}.jpg")

            # The ABTI card and last week's share card, from the same sample.
            for name, args, page in (("card", ["abti", "--json"], "card"), ("share", ["abti", "--report", "week", "--day", last_sunday.isoformat()], "share")):
                with open(tmp / f"{name}.json", "w") as f:
                    run([DANGO, *args], home, stdout=f)
                d = sample(json.loads((tmp / f"{name}.json").read_text()))
                d["lang"] = lang
                (tmp / f"{name}.json").write_text(json.dumps(d, ensure_ascii=False))
                run([WIDGET, "--abti", tmp / f"{name}.json", tmp / f"{name}.png", "--page", page, "--lang", lang], home)
                im = Image.open(tmp / f"{name}.png").convert("RGBA")
                jpg(im.resize((720, im.height * 720 // im.width), Image.LANCZOS) if name == "card" else im.resize((900, im.height * 900 // im.width), Image.LANCZOS),
                    OUT / f"{name}-{lang}.jpg")
            print("rendered", lang)
    print(f"wrote office, crew and {len(LANGS)} × desk / card / share to {OUT}")


# Where the panel picture is cut, at --scale 2: just below the ABTI card (measured on the
# 2026-11-10 panel; re-measure if the panel's top half changes).
PANEL_CUT = 2330

if __name__ == "__main__":
    main()
