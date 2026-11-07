#!/usr/bin/env python3
"""DANGO · ABTI go-to-market site generator.

Reads assets/abti.json and the ABTI art in apps/widget/assets/abti/ and writes a
static bilingual site (Chinese at /, English at /en/) to site/dist/.
Run from the repo root:

    python3 -I site/build.py
"""
import html
import hashlib
import json
import os
import re
import shutil
import site
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:  # `python3 -I` skips the user site-packages, which is where Pillow is installed here
    sys.path.append(site.getusersitepackages())
    from PIL import Image

# Where the site is served: dangoai.org (the user's, 2026-11-07); dango.app
# is not ours.
SITE_URL = os.environ.get("DANGO_SITE_URL", "https://dangoai.org").rstrip("/")
HERO_TYPE = "HBGO"  # the sample type used throughout the design handoff

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
MEDIA = HERE / "media"
VERSION = re.search(r'^version = "(.*)"', (REPO / "Cargo.toml").read_text(), re.M).group(1)
# The installer, served from the site itself (copied from target/dist when built).
DOWNLOAD_URL = f"/download/Dango-{VERSION}.dmg"
sys.path.insert(0, str(HERE))
import home as home_page  # noqa: E402  (site/home.py; -I leaves the script's folder off the path)
DIST = HERE / "dist"
ART = REPO / "apps" / "widget" / "assets" / "abti"
CFG = json.loads((REPO / "assets" / "abti.json").read_text(encoding="utf-8"))
DIMS = CFG["dimensions"]
TYPES = CFG["types"]
FONT_CSS = "https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600&display=swap"
SPARK = ('<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 3l4 3M2 8h5M3 13l4-3" fill="none" '
         'stroke="#2F7BF5" stroke-width="2.4" stroke-linecap="round"/></svg>')
CHECK = ('<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 8.5l3.2 3L13 4.5" fill="none" '
         'stroke="#16A34A" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>')

e = html.escape
SIZES = {}  # dist-relative image path -> (width, height)


# ---------------------------------------------------------------- images

def save_webp(src, rel, width=None):
    im = Image.open(src)
    if width and im.width > width:
        im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
    out = DIST / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    im.save(out, "WEBP", quality=85)
    SIZES[rel] = im.size


def save_og(src, rel):
    # Flattened on white (chat apps may paint transparency black) and cut to 256 colours: ~70 KB instead of ~450 KB.
    im = Image.open(src).convert("RGBA")
    flat = Image.new("RGB", im.size, "white")
    flat.paste(im, mask=im.getchannel("A"))
    out = DIST / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    flat.quantize(256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG).save(out, optimize=True)
    SIZES[rel] = im.size


def save_icons():
    art = Image.open(REPO / "apps" / "widget" / "assets" / "theme-b" / "logo-dango.png").convert("RGBA")
    side = max(art.size)
    square = Image.new("RGBA", (side, side), (255, 255, 255, 0))
    square.paste(art, ((side - art.width) // 2, (side - art.height) // 2))
    square.resize((64, 64), Image.LANCZOS).save(DIST / "favicon.png", optimize=True)
    touch = Image.new("RGB", (side, side), "white")
    touch.paste(square, mask=square.getchannel("A"))
    touch.resize((180, 180), Image.LANCZOS).save(DIST / "apple-touch-icon.png", optimize=True)


def build_images():
    for code, t in TYPES.items():
        scene = ART / "scene" / Path(t["scene"]).name
        save_webp(scene, f"img/scene/{code}.webp")
        save_og(scene, f"img/og/{code}.png")
        save_webp(ART / "icon" / Path(t["icon"]).name, f"img/icon/{code}.webp", 240)
    for role in CFG["roles"]:
        for art in [role["art"]] + role["alt_art"]:
            save_webp(MEDIA / "role" / f"{art}.png", f"img/roles/{art}.webp", 200)
    for role in CFG["hidden_roles"]:
        save_webp(MEDIA / "job" / f"{role['id']}.png", f"img/hidden/{role['id']}.webp", 200)
    # The home page's, rendered by the app (render_media.py).
    for p in sorted((MEDIA / "job").glob("*.png")):
        save_webp(p, f"img/job/{p.stem}.webp", 200)
    save_webp(MEDIA / "office.png", "img/office.webp")
    save_webp(MEDIA / "dango-working.png", "img/dango-working.webp", 260)
    for lang in ("zh", "en"):
        panel = Image.open(MEDIA / f"panel-{lang}.png")
        tmp = DIST / f"panel-{lang}.png"
        panel.crop((0, 0, panel.width, min(panel.height, round(panel.width * 1.9)))).save(tmp)
        save_webp(tmp, f"img/panel-{lang}.webp", 880)
        tmp.unlink()
        pet = Image.open(MEDIA / f"pet-{lang}.png")
        tmp = DIST / f"pet-{lang}.png"
        pet.crop(pet.getbbox()).save(tmp)
        save_webp(tmp, f"img/pet-{lang}.webp", 460)
        tmp.unlink()
        save_webp(MEDIA / f"card-{lang}.png", f"img/card-{lang}.webp", 1080)
        save_webp(MEDIA / f"share-week-{lang}.png", f"img/share-week-{lang}.webp", 1080)
    save_icons()


# ---------------------------------------------------------------- copy built from abti.json numbers

def pct(x):
    return f"{x * 100:g}%"


def usd(n):
    for div, unit in ((1_000_000, "M"), (1_000, "k")):
        if n >= div:
            return f"{n / div:g}{unit}"
    return f"{n:g}"


def hour_en(h):
    return f"{(h - 1) % 12 + 1} {'AM' if h < 12 else 'PM'}"  # no-break space keeps "8 PM" on one line


def dimension_copy():
    """Plain-language copy per axis: `home` (both sides), `rule` (how page), `side` (one per letter)."""
    ho, bu, ra, hr = DIMS["hands_off"], DIMS["build"], DIMS["range"], DIMS["hours"]
    n, sub = ho["min_tool_calls"], ho["subagent_counts"]
    t1, t1_rest = pct(ho["threshold"]), pct(1 - ho["threshold"])
    t2, t4 = pct(bu["threshold"]), pct(hr["threshold"])
    roles, share, m = len(CFG["roles"]), pct(ra["role_share_min"]), ra["min_roles"]
    ns, ne = hr["night_start"], hr["night_end"]
    ns_en, ne_en = hour_en(ns), hour_en(ne)
    sub_zh = "，或者用了子 agent" if sub else ""
    sub_en = ", or uses a subagent" if sub else ""
    return {
        "hands_off": {
            "home": {
                "zh": f"AI 在一个回合里自己连着调用工具 {n} 次以上{sub_zh}，这个回合就算你撒手了。撒手的回合超过 {t1} 是 H，否则是 M。",
                "en": f"If the AI makes {n}+ tool calls in a row on its own in a turn{sub_en}, you let go. Let go in more than {t1} of your turns and you're H. Otherwise, M.",
            },
            "rule": {
                "zh": f"一个回合里 AI 自己连着调用工具至少 {n} 次（改文件、跑命令、搜索各算一次）{sub_zh}，这个回合算「放手回合」。放手回合占全部回合超过 {t1} → H，否则 → M。",
                "en": f"A turn is hands-off when the AI makes at least {n} tool calls in a row on its own (editing a file, running a command and searching each count as one){sub_en}. More than {t1} of all your turns hands-off → H. Otherwise → M.",
            },
            "side": [
                {"zh": f"超过 {t1} 的回合里，你都撒手让 AI 自己干：一口气调用工具 {n} 次以上{sub_zh}。",
                 "en": f"In more than {t1} of your turns you let the AI run on its own: {n}+ tool calls in a row{', or a subagent' if sub else ''}."},
                {"zh": f"至少 {t1_rest} 的回合里，AI 没连着干满 {n} 步{'、也没叫子 agent' if sub else ''}，就回来等你拍板。",
                 "en": f"In at least {t1_rest} of your turns the AI checked back with you before {n} tool calls in a row{', without a subagent' if sub else ''}."},
            ],
        },
        "build": {
            "home": {
                "zh": f"改动的代码超过 {t2} 写在新建的文件里是 B；大多在已有文件上修修补补是 F。",
                "en": f"More than {t2} of your changed lines land in brand-new files: B. Mostly patching files that already exist: F.",
            },
            "rule": {
                "zh": f"新建文件里写的行数 ÷ 全部改动行数（新增 + 删除）超过 {t2} → B，否则 → F。",
                "en": f"Lines written into newly created files ÷ all changed lines (added + deleted). More than {t2} → B. Otherwise → F.",
            },
            "side": [
                {"zh": f"改动的代码里，超过 {t2} 写在新建的文件里。",
                 "en": f"More than {t2} of your changed lines went into brand-new files."},
                {"zh": f"新文件里的行数只占全部改动的 {t2} 或更少，大多是在已有文件上修修补补。",
                 "en": f"{t2} or less of your changed lines went into new files. Mostly, you patch what's already there."},
            ],
        },
        "range": {
            "home": {
                "zh": f"{roles} 个角色里，有 {m} 个或更多各干了 {share} 以上的活是 G；活集中在少数几个角色是 S。",
                "en": f"{m} or more of the {roles} crew roles each do {share}+ of the work: G. Work piled on fewer roles: S.",
            },
            "rule": {
                "zh": f"把团子干的活按金额分到 {roles} 个角色里（隐藏款各算一个）。占比 ≥ {share} 的角色有 {m} 个或更多 → G，否则 → S。",
                "en": f"Split your dangos' work across the {roles} crew roles by dollar value (each hidden role counts as one more). If {m} or more roles each take at least {share} → G. Otherwise → S.",
            },
            "side": [
                {"zh": f"活集中在少数几种：占到 {share} 以上的角色不到 {m} 个。",
                 "en": f"The work stays in a narrow lane: fewer than {m} crew roles reach {share}."},
                {"zh": f"什么活都沾：有 {m} 个或更多角色各占 {share} 以上。",
                 "en": f"A bit of everything: {m} or more crew roles each do at least {share} of the work."},
            ],
        },
        "hours": {
            "home": {
                "zh": f"本地时间 {ns} 点到次日 {ne} 点的工作时间超过 {t4} 是 O；活大多在白天干完是 L。",
                "en": f"More than {t4} of your working minutes fall between {ns_en} and {ne_en}: O. Mostly done in daylight: L.",
            },
            "rule": {
                "zh": f"按你 Mac 的本地时间，{ns} 点到次日 {ne} 点之间的工作分钟 ÷ 全部工作分钟超过 {t4} → O，否则 → L。",
                "en": f"Using your Mac's local time: working minutes between {ns_en} and {ne_en} ÷ all working minutes. More than {t4} → O. Otherwise → L.",
            },
            "side": [
                {"zh": f"{ns} 点到次日 {ne} 点的工作时间不超过 {t4}，活大多在白天干完。",
                 "en": f"{t4} or less of your working minutes fall between {ns_en} and {ne_en}. Daylight does the heavy lifting."},
                {"zh": f"超过 {t4} 的工作时间落在 {ns} 点到次日 {ne} 点之间。",
                 "en": f"More than {t4} of your working minutes fall between {ns_en} and {ne_en}."},
            ],
        },
    }


COPY = dimension_copy()


# ---------------------------------------------------------------- page context and shell

_VER = {}


def ver(rel):
    """`rel` with a short hash of its content: browsers keep the site's
    files for hours, so a changed file needs a new address to show up."""
    if rel not in _VER:
        _VER[rel] = hashlib.md5((DIST / rel).read_bytes()).hexdigest()[:10]
    return f"{rel}?v={_VER[rel]}"


class Ctx:
    """One output page: its language, its path below the language root, and the relative way back up."""

    def __init__(self, lang, path):
        self.lang, self.path = lang, path
        self.up = "../" * (path.count("/") + (lang == "en"))

    def t(self, zh, en):
        return zh if self.lang == "zh" else en

    def say(self, pair):
        return pair[self.lang]

    def f(self, obj, key):
        return obj[f"{key}_{self.lang}"]

    def link(self, target, lang=None):
        lang = lang or self.lang
        return (self.up + ("en/" if lang == "en" else "") + target) or "./"

    def url(self, path=None):
        return f"{SITE_URL}/{'en/' if self.lang == 'en' else ''}{self.path if path is None else path}"

    def img(self, rel, alt="", cls="", lazy=True):
        w, h = SIZES[rel]
        attrs = f' class="{cls}"' if cls else ""
        attrs += ' loading="lazy" decoding="async"' if lazy else ""
        return f'<img src="{self.up}{ver(rel)}" alt="{e(alt)}" width="{w}" height="{h}"{attrs}>'


def brand(c):
    return f'<a class="brand" href="{c.link("")}" aria-label="DANGO">DANGO{SPARK}</a>'


def header(c, current):
    items = [("types", "types/", c.t("16 型", "16 types")), ("how", "how/", c.t("怎么算", "How it works"))]
    nav = "".join(
        '<a href="{}"{}>{}</a>'.format(c.link(href), ' aria-current="page"' if key == current else "", e(label))
        for key, href, label in items
    )
    zh_label = '<span aria-current="true">中文</span>' if c.lang == "zh" else \
        f'<a href="{c.link(c.path, "zh")}" lang="zh-CN" hreflang="zh-CN">中文</a>'
    en_label = '<span aria-current="true">English</span>' if c.lang == "en" else \
        f'<a href="{c.link(c.path, "en")}" lang="en" hreflang="en">English</a>'
    return f"""<header class="gnav">
  <div class="gnav-in">
    {brand(c)}
    <span class="kind">{c.t("打工团子", "AI at work")}</span>
    <nav class="nav" aria-label="{c.t("主导航", "Main")}">{nav}</nav>
    <span class="lang">{zh_label} / {en_label}</span>
    <a class="btn btn-sm" href="{DOWNLOAD_URL}">{c.t("下载", "Download")}</a>
  </div>
</header>"""


def footer(c):
    return f"""<footer class="foot">
  <div class="foot-in">
  {brand(c)}
  <span>{c.t("全在本机算 · 不存代码和 prompt · 不上传", "Runs on your Mac · never stores code or prompts · nothing uploaded")}</span>
  <nav aria-label="{c.t("页脚", "Footer")}">
    <a href="{c.link("")}">{c.t("首页", "Home")}</a>
    <a href="{c.link("types/")}">{c.t("16 型", "16 types")}</a>
    <a href="{c.link("how/")}">{c.t("怎么算", "How it works")}</a>
    <a href="{DOWNLOAD_URL}">{c.t("下载 Mac 版", "Get it for Mac")}</a>
  </nav>
  </div>
</footer>"""


def page(c, title, desc, body, current=None, og_title=None, image=f"img/og/{HERO_TYPE}.png"):
    w, h = SIZES[image]
    og_title = og_title or title
    zh_url = f"{SITE_URL}/{c.path}"
    en_url = f"{SITE_URL}/en/{c.path}"
    return f"""<!doctype html>
<html lang="{c.t("zh-CN", "en")}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)}</title>
<meta name="description" content="{e(desc)}">
<meta name="theme-color" content="#FFFFFF">
<link rel="canonical" href="{c.url()}">
<link rel="alternate" hreflang="zh-CN" href="{zh_url}">
<link rel="alternate" hreflang="en" href="{en_url}">
<link rel="alternate" hreflang="x-default" href="{zh_url}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="DANGO">
<meta property="og:locale" content="{c.t("zh_CN", "en_US")}">
<meta property="og:title" content="{e(og_title)}">
<meta property="og:description" content="{e(desc)}">
<meta property="og:url" content="{c.url()}">
<meta property="og:image" content="{SITE_URL}/{image}">
<meta property="og:image:width" content="{w}">
<meta property="og:image:height" content="{h}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{e(og_title)}">
<meta name="twitter:description" content="{e(desc)}">
<meta name="twitter:image" content="{SITE_URL}/{image}">
<link rel="icon" type="image/png" href="{c.up}favicon.png">
<link rel="apple-touch-icon" href="{c.up}apple-touch-icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="{FONT_CSS}" media="print" onload="this.media='all'">
<noscript><link rel="stylesheet" href="{FONT_CSS}"></noscript>
<link rel="stylesheet" href="{c.up}{ver("assets/site.css")}">
</head>
<body>
{header(c, current)}
<main class="{"home" if current == "home" else "wrap"}">
{body}
</main>
{footer(c)}
</body>
</html>
"""


def write(c, text):
    out = DIST / ("en" if c.lang == "en" else "") / c.path / "index.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")


def cta_dark(c, title, button):
    parts = c.t(["支持 Claude Code、Codex、DeepSeek、WorkBuddy", "全在本机算", "不上传"],
                ["Works with Claude Code, Codex, DeepSeek and WorkBuddy", "runs on your Mac", "nothing uploaded"])
    sub = " · ".join(f'<span class="nw">{e(p)}</span>' for p in parts)
    return f"""<section class="cta-wrap">
  <div class="cta-dark">
    <div>
      <p class="t">{e(title)}</p>
      <p class="s">{sub}</p>
    </div>
    <a class="btn btn-light" href="{DOWNLOAD_URL}">{e(button)}</a>
  </div>
</section>"""


def letter_pair(c, key):
    d = DIMS[key]
    names = c.f(d, "name")
    a, b = d["letters"]
    return (f'<span><span class="mono">{a}</span>{e(names[0])}</span><span class="sep">/</span>'
            f'<span><span class="mono">{b}</span>{e(names[1])}</span>')


# ---------------------------------------------------------------- pages

APPLE = ('<svg class="apple" viewBox="0 0 17 20" aria-hidden="true"><path fill="currentColor" d="M14.1 10.6c0-2.6 2.1-3.8 2.2-3.9-1.2-1.8-3.1-2-3.7-2-1.6-.2-3.1.9-3.9.9-.8 0-2.1-.9-3.4-.9C3.6 4.7 2 5.7 1.1 7.3c-1.9 3.2-.5 8 1.3 10.6.9 1.3 1.9 2.7 3.3 2.6 1.3-.1 1.8-.8 3.4-.8 1.6 0 2 .8 3.4.8 1.4 0 2.3-1.3 3.2-2.6 1-1.5 1.4-2.9 1.4-3-.1 0-2.9-1.1-3-4.3zM11.5 3c.7-.9 1.2-2.1 1.1-3.3-1 0-2.3.7-3 1.6-.7.8-1.2 2-1.1 3.2 1.1.1 2.3-.6 3-1.5z"/></svg>')


def home(c):
    body = home_page.home(c, {"download": DOWNLOAD_URL, "check": CHECK, "apple": APPLE, "types": TYPES, "dims": DIMS,
                              "copy": COPY, "letter_pair": letter_pair, "repo": REPO,
                              "film": (HERE / "video" / f"promo-{c.lang}.mp4").exists(), "ver": ver})
    title = c.t("DANGO · 你的 AI，在替你打工", "DANGO · Your AI is working for you")
    desc = c.t(
        "DANGO 把 AI 做的每一步，按美国真实中位时薪算成一个真人要拿的工钱。支持 Claude Code、Codex、DeepSeek、WorkBuddy，全在你的 Mac 上算，什么都不上传。",
        "DANGO turns every step your AI takes into what a person would be paid at real U.S. median wages. Works with Claude Code, Codex, DeepSeek and WorkBuddy; runs on your Mac; nothing uploaded.",
    )
    return page(c, title, desc, body, current="home", image="img/og/home.png")


def type_tile(c, code):
    t = TYPES[code]
    return (f'<a class="type-tile" href="{c.link(f"t/{code}/")}">{c.img(f"img/icon/{code}.webp")}'
            f'<span class="tt-text"><span class="tt-head"><span class="code mono">{code}</span>'
            f'<span class="name">{e(c.f(t, "name"))}</span></span>'
            f'<span class="roast-s">{e(c.f(t, "roast"))}</span></span></a>')


def types_page(c):
    ho = DIMS["hands_off"]
    first, second = ho["letters"]
    lefts = [code for code in TYPES if code[0] == first]
    cells = "\n".join(type_tile(c, code) + "\n" + type_tile(c, TYPES[code]["match"]) for code in lefts)
    legend = " · ".join(
        '<span class="nw">{}</span>'.format(e(
            f'{DIMS[k]["letters"][0]} {c.f(DIMS[k], "name")[0]} / {DIMS[k]["letters"][1]} {c.f(DIMS[k], "name")[1]}'))
        for k in DIMS["order"][1:]
    )
    names = c.f(ho, "name")
    body = f"""<section class="page-head">
  <h1>{c.t("你是哪一种老板？", "Which boss are you?")}</h1>
  <p class="sub">{c.t(f"左边{names[0]}派，右边{names[1]}派。<b>同一行就是绝配</b>：前两个字母相反，后两个相同。",
                      f"{names[0]} on the left, {names[1]} on the right. <b>Each row is a perfect match</b>: first two letters flipped, last two the same.")}</p>
  <p class="legend">{legend}</p>
</section>
<section class="pairs">
  <div class="col-head">{first} · {e(c.t(names[0] + "派", names[0]))}</div>
  <div class="col-head">{second} · {e(c.t(names[1] + "派", names[1]))}</div>
{cells}
</section>
<p class="pairs-note">{c.t("每型一个招牌动作。四个字母怎么判，见", "Each type has its signature move. For how the letters are decided, see")} <a class="text-link" href="{c.link("how/")}">{c.t("怎么算", "How it works")}</a>{c.t("。", ".")}</p>
{cta_dark(c, c.t("看看你是哪型 →", "Find your type →"), c.t("下载 Mac 版", "Get it for Mac"))}"""
    title = c.t("16 种 AI 老板 · DANGO", "16 AI boss types · DANGO")
    desc = c.t("DANGO 老板人格的 16 型图鉴：左边放权派，右边微操派，同一行就是绝配。",
               "All 16 DANGO AI boss types: hands-off on the left, micromanagers on the right, perfect matches side by side.")
    return page(c, title, desc, body, current="types")


def type_page(c, code):
    t = TYPES[code]
    mcode = t["match"]
    mt = TYPES[mcode]
    name = c.f(t, "name")
    rows = []
    for i, key in enumerate(DIMS["order"]):
        d = DIMS[key]
        side = d["letters"].index(code[i])
        names = c.f(d, "name")
        rows.append(
            f'<li class="letter-row"><span class="letter-box" aria-hidden="true">{code[i]}</span><div>'
            f'<p class="lr-head"><b>{code[i]} · {e(names[side])}</b>'
            f'<span class="other">{c.t("另一边是", "Opposite:")} {d["letters"][1 - side]} {e(names[1 - side])}</span></p>'
            f'<p>{e(c.say(COPY[key]["side"][side]))}</p></div></li>'
        )
    letters = "\n".join(rows)
    body = f"""<a class="back" href="{c.link("types/")}">← {c.t("全部 16 型", "All 16 types")}</a>
<section class="type-hero">
  <div class="type-art">{c.img(f"img/scene/{code}.webp", c.t(f"{name}的场景插画", f"{name}, scene illustration"), lazy=False)}</div>
  <div class="type-id">
    <p class="kicker">{c.t("AI 老板人格", "AI Boss Type")}</p>
    <h1><span class="code">{code}</span><span class="name">{e(name)}</span></h1>
    <p class="roast"><span class="q" aria-hidden="true">“</span><span>{e(c.f(t, "roast"))}</span></p>
    <p class="portrait">{e(c.f(t, "portrait"))}</p>
    <div class="cta-row"><a class="btn" href="{DOWNLOAD_URL}">{c.t("看看你是哪型 → 下载 DANGO", "Find your type → Get DANGO")}</a></div>
  </div>
</section>

<section class="sec">
  <div class="sec-head"><h2>{c.t("四个字母", "The four letters")}</h2></div>
  <ol class="letters">
{letters}
  </ol>
</section>

<section class="sec">
  <div class="sec-head"><h2>{c.t("绝配", "Perfect match")}</h2></div>
  <a class="match" href="{c.link(f"t/{mcode}/")}">
    {c.img(f"img/icon/{mcode}.webp")}
    <span class="match-text"><span class="m1"><span class="mono">{mcode}</span>{e(c.f(mt, "name"))}</span><span class="m2">{e(c.f(t, "match_line"))}</span></span>
    <span class="arrow" aria-hidden="true">→</span>
  </a>
  <p class="match-note">{c.t("绝配：前两个字母反过来，后两个不变。", "Perfect match: first two letters flipped, last two the same.")}</p>
</section>

{cta_dark(c, c.t("看看你是哪型 →", "Find your type →"), c.t("下载 DANGO", "Get DANGO"))}"""
    title = f"{code} {name}"
    return page(c, f"{title} · DANGO", c.f(t, "roast"), body, og_title=title, image=f"img/og/{code}.png")


def how_page(c):
    rules = "\n".join(
        f'<div class="rule"><p class="rule-name">{letter_pair(c, key)}</p><p>{e(c.say(COPY[key]["rule"]))}</p></div>'
        for key in DIMS["order"]
    )
    tie, ho, bu, hr = DIMS["tie_band"], DIMS["hands_off"], DIMS["build"], DIMS["hours"]
    seconds = " / ".join(DIMS[k]["letters"][1] for k in ("hands_off", "build", "hours"))
    lo, hi = pct(tie["min"]), pct(tie["max"])
    notes = [
        c.t(f"{ho['name_zh'][0]}、{bu['name_zh'][0]}、{hr['name_zh'][1]}的比例落在 {lo}–{hi} 之间时，卡上的数字前会加「≈」：两边都沾，字母照常按上面的规则判。{DIMS['range']['name_zh'][0]} / {DIMS['range']['name_zh'][1]}不设这一档。",
            f"When the {ho['name_en'][0]}, {bu['name_en'][0]} or {hr['name_en'][1]} share lands between {lo} and {hi}, the card puts “≈” in front of the number: you're on the fence, and the letter still follows the rule above. {DIMS['range']['name_en'][0]} / {DIMS['range']['name_en'][1]} has no fence zone."),
        c.t(f"正好 {pct(ho['threshold'])} 时算第二个字母（{seconds}），因为规则是「超过」。",
            f"Exactly {pct(ho['threshold'])} goes to the second letter ({seconds}), because the rule says “more than.”"),
    ]
    notes_html = "".join(f"<li>{e(n)}</li>" for n in notes)

    tiers = sorted(CFG["scale_tiers"], key=lambda x: x["min_usd"])
    tier_rows = []
    for i, tier in enumerate(tiers):
        if i == len(tiers) - 1:
            rng = f"≥ ${usd(tier['min_usd'])}"
        elif i == 0:
            rng = f"< ${usd(tiers[1]['min_usd'])}"
        else:
            rng = f"${usd(tier['min_usd'])} – {usd(tiers[i + 1]['min_usd'])}"
        bars = "".join(
            '<span{} style="height:{:g}px"></span>'.format(' class="on"' if j <= i else "", 6 + j * 18 / (len(tiers) - 1))
            for j in range(len(tiers))
        )
        tier_rows.append(
            f'<div class="tier"><span class="bars" aria-hidden="true">{bars}</span>'
            f'<span class="tier-text"><b>{e(c.f(tier, "name"))}</b><span>{e(c.f(tier, "line"))}</span></span>'
            f'<span class="range mono">{e(rng)}</span></div>'
        )
    tier_html = "\n".join(tier_rows)

    margins = CFG["margin_tiers"]  # ordered from the top down; the last one (min null) is "below zero"
    mrows = []
    for i, tier in enumerate(margins):
        if tier["min"] is None:
            rng = f"< {margins[i - 1]['min'] * 100:g}"
        elif i == 0:
            rng = f"≥ {pct(tier['min'])}"
        else:
            rng = f"{tier['min'] * 100:g}–{pct(margins[i - 1]['min'])}"
        mrows.append(
            f'<div class="mrow"><span class="range mono">{e(rng)}</span><b>{e(c.f(tier, "name"))}</b>'
            f'<span class="l">{e(c.f(tier, "line"))}</span></div>'
        )
    margin_html = "\n".join(mrows)
    ruthless = margins[0]

    role_rows = []
    for role in CFG["roles"]:
        alts = "".join(c.img(f"img/roles/{a}.webp") for a in role["alt_art"])
        art = c.img("img/roles/{}.webp".format(role["art"]))
        role_rows.append(
            f'<div class="role">{art}<span class="role-text">'
            f'<span class="role-name"><span class="swatch" style="background:{role["color"]}"></span>{e(c.f(role, "name"))}</span>'
            f'<span class="c">{e(c.f(role, "covers"))}</span></span>'
            f'<span class="alts">{alts}</span></div>'
        )
    roles_html = "\n".join(role_rows)
    hidden_html = "\n".join(
        "<li>{}<span>{}</span></li>".format(c.img("img/hidden/{}.webp".format(h["id"])), e(c.f(h, "name")))
        for h in CFG["hidden_roles"]
    )
    share, m = pct(DIMS["range"]["role_share_min"]), DIMS["range"]["min_roles"]
    roles_n = len(CFG["roles"])

    toc = [("letters", c.t("四个字母", "The four letters")), ("scale", c.t("公司规模", "Company size")),
           ("margin", c.t("压榨率", "Margin")), ("crew", c.t("团子构成", "Your crew"))]
    toc_html = "".join(f'<a href="#{k}">{e(v)}</a>' for k, v in toc)

    body = f"""<section class="page-head">
  <h1>{c.t("怎么算", "How it works")}</h1>
  <p class="sub">{c.t("所有门槛都是 DANGO 自己定的固定标准，不和别人比。用到的只有本机记下的数字：回合数、时长、改了几行、模型花了多少钱。",
                      "Every threshold is a fixed DANGO standard, not a ranking against anyone else. The only inputs are numbers logged on your Mac: turns, minutes, lines changed, and what the models cost.")}</p>
  <nav class="toc" aria-label="{c.t("本页目录", "On this page")}">{toc_html}</nav>
</section>

<section class="sec" id="letters">
  <div class="sec-head"><h2>{c.t("四个字母怎么判", "How the four letters are decided")}</h2></div>
  <div class="rules">
{rules}
  </div>
  <ul class="notes">{notes_html}</ul>
</section>

<section class="sec" id="scale">
  <div class="sec-head">
    <h2>{c.t("你的公司多大", "How big is your company?")}</h2>
    <span class="note">{c.t("按团子替你打的工，固定门槛，不和别人比", "By the value of the work your dangos did. Fixed thresholds, not a ranking.")}</span>
  </div>
  <div class="tiers">
{tier_html}
  </div>
  <ul class="notes">
    <li>{c.t("「团子替你打的工」= 每种活的时长 × 干这一行的人在美国的时薪中位数（美国劳工统计局的数据）。",
             "“Value of the work” = minutes of each kind of work × the US median hourly wage for that job (BLS data).")}</li>
    <li>{c.t("按扫描到的累计金额定档，不年化。", "Tiers use the running total from the scan. Nothing is annualized.")}</li>
  </ul>
</section>

<section class="sec" id="margin">
  <div class="sec-head">
    <h2>{c.t("你有多黑心", "How ruthless are you?")}</h2>
    <span class="note formula">{c.t("压榨率 = 1 − 模型花费 ÷ 团子打的工", "margin = 1 − model cost ÷ value of the work")}</span>
  </div>
  <div class="mrows">
{margin_html}
  </div>
  <ul class="notes">
    <li>{c.t(f"只看比例：花 $5 的个体户也能是{ruthless['name_zh']}。", f"Only the ratio counts: a solo stall spending $5 on models can still be a {ruthless['name_en']}.")}</li>
    <li>{c.t("卡上同时写的「杠杆」= 团子打的工 ÷ 模型花费，和压榨率是同一件事的两种说法。",
             "The card also shows leverage = value of the work ÷ model cost. Same thing, said the other way round.")}</li>
  </ul>
</section>

<section class="sec" id="crew">
  <div class="sec-head">
    <h2>{c.t(f"团子构成 · {roles_n} 个角色", f"Your crew · {roles_n} roles")}</h2>
  </div>
  <p class="intro">{c.t("写代码统称程序员。角色只看团子在干什么活，和老板类型无关；颜色跟角色走，不跟名次走。右边的小团子是同一角色的备用造型。",
                                                       "All coding work counts as Coder. Roles describe what the dangos are doing, not what kind of boss you are, and each role keeps its color wherever it ranks. The small dangos on the right are alternate looks for the same role.")}</p>
  <div class="roles">
{roles_html}
  </div>
  <div class="hidden">
    <p class="hidden-head"><b>{c.t("隐藏款", "Hidden roles")}</b>{c.t(f"占到 {share} 以上才单独出现，算一个角色；不到就并进「其他」。金色闪光是隐藏款标记。",
                                                                       f"They only show up on their own at {share} or more, and then count as a role. Below that they go into “Other.” The gold sparkle marks a hidden role.")}</p>
    <ul class="hidden-grid">
{hidden_html}
    </ul>
  </div>
  <ul class="notes">
    <li>{c.t(f"跨界 = 有 {m} 个或更多角色各占 {share} 以上。算钱仍按每个职业各自的时薪。",
             f"Generalist = {m} or more roles at {share}+ each. Pay is still worked out per job, at that job's own BLS wage.")}</li>
  </ul>
</section>

{cta_dark(c, c.t("看看你是哪型 →", "Find your type →"), c.t("下载 Mac 版", "Get it for Mac"))}"""
    title = c.t("怎么算 · DANGO", "How it works · DANGO")
    desc = c.t("DANGO 老板人格的四个字母、公司规模、压榨率和团子构成都怎么算。",
               "How DANGO decides your four letters, your company size, your margin and your crew.")
    return page(c, title, desc, body, current="how")


# ---------------------------------------------------------------- main

def main():
    if DIST.exists():
        shutil.rmtree(DIST)
    (DIST / "assets").mkdir(parents=True)
    shutil.copyfile(HERE / "site.css", DIST / "assets" / "site.css")
    build_images()
    save_og(MEDIA / "office.png", "img/og/home.png")
    # The launch film (site/video, from ~/dango-promo-video): promo-<lang>.mp4,
    # its captions and poster; a language without one gets no film section.
    if (HERE / "video").exists():
        shutil.copytree(HERE / "video", DIST / "video")
    # The installer goes up only when asked (DANGO_SHIP_DMG=1); until then the
    # download links point at where it will be (user, 2026-11-07: not yet).
    dmg = REPO / "target" / "dist" / f"Dango-{VERSION}.dmg"
    if os.environ.get("DANGO_SHIP_DMG") != "1":
        print(f"note: {DOWNLOAD_URL} not included; set DANGO_SHIP_DMG=1 to ship it")
    elif dmg.exists():
        (DIST / "download").mkdir()
        shutil.copyfile(dmg, DIST / "download" / dmg.name)
    else:
        print(f"note: no {dmg.relative_to(REPO)}; run apps/widget/package.sh so the download link works")
    for lang in ("zh", "en"):
        write(Ctx(lang, ""), home(Ctx(lang, "")))
        write(Ctx(lang, "types/"), types_page(Ctx(lang, "types/")))
        write(Ctx(lang, "how/"), how_page(Ctx(lang, "how/")))
        for code in TYPES:
            c = Ctx(lang, f"t/{code}/")
            write(c, type_page(c, code))
    files = [p for p in DIST.rglob("*") if p.is_file()]
    size = sum(p.stat().st_size for p in files)
    pages = sum(1 for p in files if p.name == "index.html")
    print(f"wrote {pages} pages, {len(files)} files, {size / 1_048_576:.2f} MB to {DIST}")


if __name__ == "__main__":
    main()
