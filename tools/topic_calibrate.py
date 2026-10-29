#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Checks the topic classifier against this machine's own prompts.

  python3 tools/topic_calibrate.py          every Claude Code / Codex prompt on
                                            this Mac through the classifier:
                                            counts per topic and short samples
  python3 tools/topic_calibrate.py --why    which keywords each prompt on stdin
                                            hits, per family

Prompts are read from ~/.claude/projects and ~/.codex/sessions, trimmed to
400 characters, kept in memory and printed at most 64 characters wide.
Nothing is written anywhere. Needs the dango-core "topic" example (cargo).
"""
import collections, glob, io, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Context that Claude Code and Codex put in the user role but nobody typed.
NOISE = re.compile(r"^\[\d+\]|^Retained source order|^\{ ?\"|^assistant:|^Base directory|^\[Image:|^# |^\[\{|^<|^/")


def load_table(path):
    occ, fam, cur = [], [], None
    for line in open(path, encoding="utf-8"):
        s = line.strip()
        if s == "[[occupation]]":
            cur = {}
            occ.append(cur)
            continue
        if s == "[[family]]":
            cur = {}
            fam.append(cur)
            continue
        if s.startswith("[") or cur is None or "=" not in s:
            continue
        k, v = s.split("=", 1)
        try:
            cur[k.strip()] = json.loads(v.strip())
        except Exception:
            pass
    return {"occupation": occ, "family": fam}


def why(prompts):
    """Mirrors core::occupation::topic_candidates, showing the hits."""
    t = load_table(os.path.join(ROOT, "assets/occupations.toml"))
    fams = [f["id"] for f in t["family"]]
    for prompt in prompts:
        p = prompt.lower()
        padded = " " + "".join(c if (c.isascii() and c.isalnum()) or c in "+#./-" else " " for c in p) + " "
        hit = lambda kw: (" " + kw.strip() + " ") in padded if kw.isascii() else kw in p
        by = {}
        for o in t["occupation"]:
            s = [k for k in o.get("strong", []) if hit(k)]
            w = [k for k in o.get("weak", []) if k not in o.get("strong", []) and hit(k)]
            tells = [k for k in o.get("tell", []) if hit(k)]
            if s or w or tells:
                e = by.setdefault(o["family"], [0, False, []])
                e[0] += 2 * len(s) + len(w)
                e[1] |= bool(s)
                e[2].append(f"{o['id']}: strong{s} weak{w}" + (f" tell{tells}" if tells else ""))
        ok = {f: v for f, v in by.items() if v[0] >= 3 or (v[0] >= 2 and v[1])}
        top = max((v[0] for v in ok.values()), default=0)
        wins = [f for f in fams if f in ok and ok[f][0] == top]
        print(f"→ {' / '.join(wins) or 'none'}   {prompt[:60]}")
        for f in fams:
            if f in by:
                print(f"     {f:12} {by[f][0]:2}{'*' if by[f][1] else ' '}  " + " | ".join(by[f][2]))


def prompts_on_disk():
    home = os.path.expanduser("~")
    out = []

    def add(text):
        t = re.sub(r"\s+", " ", text).strip()
        if len(t) < 6 or NOISE.match(t) or "local-command" in t or "system-reminder" in t:
            return
        out.append(t[:400])

    for f in glob.glob(home + "/.claude/projects/*/*.jsonl"):
        for line in io.open(f, encoding="utf-8", errors="ignore"):
            if '"type":"user"' not in line and '"type": "user"' not in line:
                continue
            try:
                j = json.loads(line)
            except Exception:
                continue
            if j.get("type") != "user":
                continue
            c = (j.get("message") or {}).get("content")
            if isinstance(c, str):
                add(c)
            elif isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "text":
                        add(b.get("text", ""))
    n_claude = len(out)
    for f in glob.glob(home + "/.codex/sessions/**/*.jsonl", recursive=True):
        for line in io.open(f, encoding="utf-8", errors="ignore"):
            if "user" not in line:
                continue
            try:
                j = json.loads(line)
            except Exception:
                continue
            p = j.get("payload") or j
            if p.get("type") == "message" and p.get("role") == "user":
                for b in p.get("content") or []:
                    if isinstance(b, dict) and b.get("type") in ("input_text", "text"):
                        add(b.get("text", ""))
    return out, n_claude


def scan():
    prompts, n_claude = prompts_on_disk()
    uniq = list(dict.fromkeys(prompts))
    print(f"{n_claude} claude + {len(prompts) - n_claude} codex prompts, {len(uniq)} unique")
    run = subprocess.run(["cargo", "run", "-q", "-p", "dango-core", "--example", "topic"],
                         input="\n".join(uniq) + "\n", capture_output=True, text=True, cwd=ROOT)
    rows = [l.split("\t", 1) for l in run.stdout.splitlines() if "\t" in l]
    print("counts:", dict(collections.Counter(r[0] for r in rows).most_common()))
    by = collections.defaultdict(list)
    for topic, text in rows:
        by[topic].append(text)
    for topic in sorted(by):
        if topic == "-":
            continue
        print(f"\n## {topic} ({len(by[topic])})")
        for t in by[topic][:10 if topic != "swe" else 6]:
            print("  ·", t[:64])
    print(f"\n## no topic, long (of {len(by['-'])})")
    for t in [x for x in by["-"] if len(x) > 50][:16]:
        print("  ·", t[:64])


if __name__ == "__main__":
    if "--why" in sys.argv:
        why([l.strip() for l in sys.stdin if l.strip()])
    else:
        scan()
