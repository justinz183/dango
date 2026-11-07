#!/usr/bin/env python3
"""Renders the website's pictures with the app itself into site/media/, so
the site's 团子, office, panel and cards are always the app's own:

- every job's 团子 and every role's (dango-widget --snapshot-dango),
- the office with a cast at work, napping and waiting,
- the panel, a week's share image, the boss card and the corner pet, in
  Chinese and in English, from SAMPLE data: this Mac's numbers scaled by
  SCALE, with every session title and project name dropped, so the site
  shows no one's real totals or projects.

Run from the repository root after `cargo build --release` and
`apps/widget/build.sh`:

  python3 -I site/render_media.py

Reads $DANGO_HOME (default ~/.dango) only through a copy; writes nothing
there.
"""
import json
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MEDIA = REPO / "site" / "media"
WIDGET = REPO / "target" / "release" / "dango-widget"
DANGO = REPO / "target" / "release" / "dango"
SOURCE = Path(os.environ.get("DANGO_HOME", Path.home() / ".dango"))
SCALE = 0.6
# The office on the home page: who sits where, and doing what.
CAST = [("swe", "working"), ("data", "working"), ("designer", "waiting"), ("video", "idle"), ("writer", "sleeping"), ("doctor", "idle")]


def run(args, home=None):
    # The site is light and in daylight, whatever this Mac's theme and clock say.
    if args[0] == WIDGET:
        args = list(args) + ["--light", "--hour", "12"]
    env = dict(os.environ)
    if home:
        env["DANGO_HOME"] = str(home)
    subprocess.run([str(a) for a in args], check=True, cwd=REPO, env=env, stdout=subprocess.DEVNULL)


def out(args, home):
    env = dict(os.environ, DANGO_HOME=str(home))
    return subprocess.run([str(a) for a in args], check=True, cwd=REPO, env=env, capture_output=True, text=True).stdout


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


def job_ids():
    text = (REPO / "assets" / "occupations.toml").read_text(encoding="utf-8")
    return [m.group(1) for blk in text.split("[[occupation]]")[1:] for m in [re.search(r'^id = "(\w+)"', blk, re.M)]]


def main():
    if MEDIA.exists():
        shutil.rmtree(MEDIA)
    for d in ("job", "role"):
        (MEDIA / d).mkdir(parents=True)
    for job in job_ids():
        run([WIDGET, "--snapshot-dango", MEDIA / "job" / f"{job}.png", "--job", job, "--width", 360])
    layout = json.loads((REPO / "apps" / "widget" / "assets" / "dango" / "dango.json").read_text())
    for role in sorted(layout["roles"]):
        run([WIDGET, "--snapshot-dango", MEDIA / "role" / f"{role}.png", "--role", role, "--width", 240])
    run([WIDGET, "--snapshot-dango", MEDIA / "role" / "plain.png", "--width", 240])
    run([WIDGET, "--snapshot-dango", MEDIA / "dango-working.png", "--job", "swe", "--status", "working", "--width", 520])
    run([WIDGET, "--snapshot-office", MEDIA / "office.png", "--jobs", ",".join(j for j, _ in CAST), "--statuses", ",".join(s for _, s in CAST), "--scale", "2.5"])

    with tempfile.TemporaryDirectory() as tmp:
        for lang in ("zh", "en"):
            home = Path(tmp) / lang
            home.mkdir()
            src = sqlite3.connect(SOURCE / "data.db")
            dst = sqlite3.connect(home / "data.db")
            src.backup(dst)
            src.close()
            dst.close()
            run([DANGO, "lang", lang], home)
            widget = home / "widget.json"
            widget.write_text(json.dumps(sample(json.loads(widget.read_text())), ensure_ascii=False))
            result = sample(json.loads(out([DANGO, "abti", "--json"], home)))
            week = sample(json.loads(out([DANGO, "abti", "--report", "week"], home)))
            (home / "result.json").write_text(json.dumps(result, ensure_ascii=False))
            (home / "week.json").write_text(json.dumps(week, ensure_ascii=False))
            run([WIDGET, "--snapshot-dashboard", MEDIA / f"panel-{lang}.png", "--range", 7], home)
            run([WIDGET, "--abti", home / "week.json", MEDIA / f"share-week-{lang}.png", "--page", "share"], home)
            run([WIDGET, "--abti", home / "result.json", MEDIA / f"card-{lang}.png", "--page", "card"], home)
            run([WIDGET, "--snapshot-pet", MEDIA / f"pet-{lang}.png", "--state", "working", "--job", "swe", "--receipt"], home)
    files = sorted(p for p in MEDIA.rglob("*.png"))
    print(f"wrote {len(files)} pictures to {MEDIA}")


if __name__ == "__main__":
    main()
