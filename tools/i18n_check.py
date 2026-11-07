#!/usr/bin/env python3
"""Lists every English line the interface shows and checks that the Korean,
Japanese, French and Spanish tables (assets/i18n/<code>.json) have each one.
English is the key: Swift's L(中, 英), the Windows app's L(中, 英) in
apps/windows/ui/*.js, Rust's t(中, 英) / f(中, 英, …),
the `_en` words in assets/abti.json and the jobs' `name_en`. In Swift,
whatever is not a string literal ("\\(n) days", name + " tier") becomes a
{} hole, which is how the tables write templates.

  python3 -I tools/i18n_check.py            missing lines per language (exit 1 if any)
  python3 -I tools/i18n_check.py --keys     every English line, as a JSON list

The terminal's text report (crates/daemon/src/report.rs) is not translated:
Korean, Japanese, French and Spanish read it in English.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGS = ["ko", "ja", "fr", "es"]
SWIFT = ["main", "theme", "abti", "story"]
# Rust files whose text the six languages read.
RUST = [
    "crates/core/src/render.rs",
    "crates/core/src/occupation.rs",
    "crates/core/src/progress.rs",
    "crates/daemon/src/widget.rs",
    "crates/daemon/src/abti.rs",
    "crates/daemon/src/ingest.rs",
    "crates/daemon/src/config.rs",
    "crates/cli/src/main.rs",
    "apps/windows/src/main.rs",
]
# The Windows app's pages.
JS = sorted((ROOT / "apps" / "windows" / "ui").glob("*.js"))


def swift_string(src, i):
    """The literal starting at src[i] == '"': (text with \\(…) as {}, end index)."""
    out, j = [], i + 1
    while src[j] != '"':
        if src[j] == "\\" and src[j + 1] == "(":
            depth, j = 1, j + 2
            while depth:
                if src[j] == "(":
                    depth += 1
                elif src[j] == ")":
                    depth -= 1
                elif src[j] == '"':
                    _, j = swift_string(src, j)
                    continue
                j += 1
            out.append("{}")
            continue
        if src[j] == "\\":
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(src[j + 1], src[j + 1]))
            j += 2
            continue
        out.append(src[j])
        j += 1
    return "".join(out), j + 1


def args_of(src, i):
    """The top-level arguments of the call whose '(' is at src[i], as source text."""
    depth, j, start, args = 1, i + 1, i + 1, []
    while depth:
        c = src[j]
        if c == '"':
            _, j = swift_string(src, j)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append(src[start:j])
                break
        elif c == "," and depth == 1:
            args.append(src[start:j])
            start = j + 1
        j += 1
    return args


def template(expr):
    """`"Since " + AB.monthDay(from)` → "Since {}"; a literal stays itself."""
    parts, depth, cur, k = [], 0, "", 0
    expr = expr.strip()
    while k < len(expr):
        c = expr[k]
        if c == '"':
            _, end = swift_string(expr, k)
            cur += expr[k:end]
            k = end
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "+" and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += c
        k += 1
    parts.append(cur.strip())
    out = ""
    for p in parts:
        if p.startswith('"') and p.endswith('"'):
            out += swift_string(p, 0)[0]
        else:
            out += "{}"
    return out


def swift_keys():
    keys = set()
    for name in SWIFT:
        src = (ROOT / "apps" / "widget" / f"{name}.swift").read_text(encoding="utf-8")
        for m in re.finditer(r"(?<![\w.])L\(", src):
            a = args_of(src, m.end() - 1)
            if len(a) == 2:
                keys.add(template(a[1]))
    return keys


def js_string(src, i):
    """The JS literal ("…", '…' or `…`) at src[i]: (text with ${…} as {}, end index)."""
    q, out, j = src[i], [], i + 1
    while src[j] != q:
        if q == "`" and src[j] == "$" and src[j + 1] == "{":
            depth, j = 1, j + 2
            while depth:
                if src[j] in "\"'`":
                    _, j = js_string(src, j)
                    continue
                depth += {"{": 1, "}": -1}.get(src[j], 0)
                j += 1
            out.append("{}")
            continue
        if src[j] == "\\":
            out.append({"n": "\n", "t": "\t"}.get(src[j + 1], src[j + 1]))
            j += 2
            continue
        out.append(src[j])
        j += 1
    return "".join(out), j + 1


def js_args(src, i):
    """The top-level arguments of the JS call whose '(' is at src[i]."""
    depth, j, start, args = 1, i + 1, i + 1, []
    while depth:
        c = src[j]
        if c in "\"'`":
            _, j = js_string(src, j)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append(src[start:j])
                break
        elif c == "," and depth == 1:
            args.append(src[start:j])
            start = j + 1
        j += 1
    return args


def js_template(expr):
    """`b.scale + " tier"` → "{} tier"; literals stay themselves."""
    parts, depth, cur, k, expr = [], 0, "", 0, expr.strip()
    while k < len(expr):
        c = expr[k]
        if c in "\"'`":
            _, end = js_string(expr, k)
            cur += expr[k:end]
            k = end
            continue
        depth += {"(": 1, "[": 1, "{": 1, ")": -1, "]": -1, "}": -1}.get(c, 0)
        if c == "+" and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += c
        k += 1
    parts.append(cur.strip())
    return "".join(js_string(p, 0)[0] if p[:1] in "\"'`" and p[-1:] == p[:1] else "{}" for p in parts)


def js_keys():
    keys = set()
    for f in JS:
        src = f.read_text(encoding="utf-8")
        for m in re.finditer(r"(?<![\w.])L\(", src):
            a = js_args(src, m.end() - 1)
            if len(a) == 2:
                keys.add(js_template(a[1]))
    return keys


RUST_CALL = re.compile(r'(?:\.t|\.f|\bs)\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"')


def rust_keys():
    keys = set()
    for f in RUST:
        src = (ROOT / f).read_text(encoding="utf-8")
        src = src.split("#[cfg(test)]")[0]
        for m in RUST_CALL.finditer(src):
            keys.add(m.group(2).encode().decode("unicode_escape").encode("latin-1").decode("utf-8"))
    return keys


def config_keys():
    keys = set()

    def walk(x):
        if isinstance(x, dict):
            for k, v in x.items():
                if k.endswith("_en") or k == "en":
                    for s in (v if isinstance(v, list) else v.values() if isinstance(v, dict) else [v]):
                        if isinstance(s, str):
                            keys.add(s)
                if k == "tiers" and isinstance(v, list):
                    keys.update(t[2] for t in v if isinstance(t, list) and len(t) > 2 and isinstance(t[2], str))
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)

    walk(json.loads((ROOT / "assets" / "abti.json").read_text(encoding="utf-8")))
    jobs = (ROOT / "assets" / "occupations.toml").read_text(encoding="utf-8")
    keys.update(re.findall(r'^(?:name_en|label_en) = "([^"]+)"', jobs, re.M))
    return keys


def all_keys():
    k = swift_keys() | rust_keys() | config_keys() | js_keys()
    # Holes alone and plain numbers are not text.
    return sorted(x for x in k if x.strip() and re.sub(r"\{\}|[\d\s.,:%/×+\-$·—]", "", x))


def main():
    keys = all_keys()
    if "--keys" in sys.argv:
        print(json.dumps(keys, ensure_ascii=False, indent=1))
        return 0
    bad = 0
    for code in LANGS:
        table = json.loads((ROOT / "assets" / "i18n" / f"{code}.json").read_text(encoding="utf-8"))
        missing = [k for k in keys if k not in table]
        holes = [k for k in keys if k in table and (k.count("{}") != max(table[k].count("{}"), len(re.findall(r"\{\d\}", table[k])))
                                                    or set(re.findall(r"\{[a-z_]+\}", k)) != set(re.findall(r"\{[a-z_]+\}", table[k])))]
        # Spaces at either end join the line to its neighbours: keep them.
        edges = [k for k in keys if k in table and (k[:len(k) - len(k.lstrip(" "))], k[len(k.rstrip(" ")):])
                 != (table[k][:len(table[k]) - len(table[k].lstrip(" "))], table[k][len(table[k].rstrip(" ")):])]
        holes += edges
        print(f"{code}: {len(keys) - len(missing)}/{len(keys)} lines" + (f", {len(holes)} with the wrong number of holes" if holes else ""))
        for k in missing[:20]:
            print("  missing:", k)
        for k in holes[:20]:
            print("  holes:", k, "→", table[k])
        bad += len(missing) + len(holes)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
