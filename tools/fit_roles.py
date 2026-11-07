#!/usr/bin/env python3
"""Measures where each role's eyes and accessory sit on the designer's own
role sheet (DONGO_Developer_Pack_v2 reference/original_design_pack/02_roles/
12_roles.png) and prints them in the app's 512 x 512 layout, for the
`measured` table in tools/dango_pack.swift. The pack's manifest rects put
the hats and headphones on a flatter body than the sheet draws (user,
2026-11-07: 「团子的耳机和帽子都是不符合逻辑的」), so the app follows the sheet.

  python3 tools/fit_roles.py ~/Downloads/DONGO_Developer_Pack_v2 apps/widget/assets/dango

Per role on the sheet: the body (its width fitted to the lowest rows, which
no accessory reaches; the sheet's bodies are 0.76 as high as wide, B01 is
0.68, so the app draws B01 that much taller), the eye whites (light regions
the background can't reach), and the accessory (its saturated fill, or for
the black hair the black above or around the body). Each part is then
placed so that its own whites / fill land on the sheet's, keeping its shape.

The hats and headphones are not the atlas's: drawn on their own they can't
be worn (a hat's underside showed over the forehead, the beanie sat on top
instead of wrapping the head; user, 2026-11-07: 「帽子的底部不应该露在外面，
而且紫色帽子应该包头」). They were redrawn as worn on this body with Codex's
built-in image generation (the tool the pack was made with); the originals
are in apps/widget/assets/dango-src/worn, and this cuts the accessory out of
each into the parts folder, over the atlas part. A beanie or cap is then
sized to cover the head above its lower edge, which rests on the eyes.
Needs numpy and Pillow.
"""
import json, os, sys
from collections import deque

import numpy as np
from PIL import Image, ImageFilter

PACK, PARTS = sys.argv[1], sys.argv[2]
sheet = np.asarray(Image.open(os.path.join(PACK, "reference/original_design_pack/02_roles/12_roles.png")).convert("RGB")).astype(float)
LUMA = 0.299 * sheet[..., 0] + 0.587 * sheet[..., 1] + 0.114 * sheet[..., 2]
SAT = np.where(sheet.max(2) > 0, (sheet.max(2) - sheet.min(2)) / np.maximum(sheet.max(2), 1), 0)
# The sheet's 4 x 3 cells, above each name.
ROWS = [(185, 436), (480, 739), (782, 1049), (1090, 1329)]
COLS = [(8, 368), (370, 722), (724, 1080)]
manifest = json.load(open(os.path.join(PACK, "data/manifest.json")))
ROLES = {r["id"]: r for r in manifest["roles"]}


def cell(rid):
    i = int(rid[1:]) - 1
    (y0, y1), (x0, x1) = ROWS[i // 3], COLS[i % 3]
    return LUMA[y0:y1, x0:x1], SAT[y0:y1, x0:x1]


def black(l, s):
    return (l < 75) & (s < 0.45)


def box(m):
    ys, xs = np.where(m)
    return [xs.min(), ys.min(), xs.max() - xs.min() + 1, ys.max() - ys.min() + 1]


def bottom_rows(b, n=80):
    bot = np.where(b.sum(1) > 3)[0][-1]
    out = {}
    for d in range(1, n):
        xs = np.where(b[bot - d])[0]
        if len(xs):
            out[d] = (xs[0], xs[-1])
    return bot, out


# The body's shape near its bottom, from the two plain-topped roles.
REF = []
for rid in ["R02", "R08"]:
    b = black(*cell(rid))
    bot, rows = bottom_rows(b)
    top = np.where(b.sum(1) > 3)[0][0]
    w = max(r[1] - r[0] + 1 for r in rows.values())
    REF.append(((bot - top + 1) / w, w, {d: (c - a + 1) / w for d, (a, c) in rows.items()}))
ASPECT = float(np.mean([r[0] for r in REF]))
BODY = [80.0, 400 - 352 * ASPECT, 352.0, 352 * ASPECT]  # bottom on the pack's ground line


def ref_width(f):
    vals = []
    for _, w, p in REF:
        d = f * w
        i = int(d)
        if i in p and i + 1 in p:
            vals.append(p[i] + (p[i + 1] - p[i]) * (d - i))
    return np.mean(vals) if vals else None


def body(rid):
    b = black(*cell(rid))
    bot, rows = bottom_rows(b)
    best = None
    for w in np.arange(200, 360, 0.25):
        err = [(c - a + 1 - w * ref_width(d / w)) ** 2 for d, (a, c) in rows.items() if 0.03 <= d / w <= 0.10 and ref_width(d / w)]
        e = float(np.mean(err))
        if best is None or e < best[0]:
            best = (e, w)
    w = best[1]
    cx = np.mean([(a + c) / 2 for d, (a, c) in rows.items() if 0.03 <= d / w <= 0.10])
    return [cx - w / 2, bot + 1 - ASPECT * w, w, ASPECT * w]


def to_layout(bb, r):
    k = BODY[2] / bb[2]
    return [BODY[0] + (r[0] - bb[0]) * k, BODY[1] + (r[1] - bb[1]) * k, r[2] * k, r[3] * k]


def components(mask):
    h, w = mask.shape
    seen = np.zeros_like(mask)
    for y0, x0 in zip(*np.where(mask)):
        if seen[y0, x0]:
            continue
        q, pts = deque([(y0, x0)]), []
        seen[y0, x0] = True
        while q:
            y, x = q.popleft()
            pts.append((y, x))
            for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    q.append((ny, nx))
        yield np.array(pts)


def eye_whites(l, bb):
    found = []
    for p in components(l > 200):
        ys, xs = p[:, 0], p[:, 1]
        if ys.min() == 0 or xs.min() == 0 or ys.max() == l.shape[0] - 1 or xs.max() == l.shape[1] - 1:
            continue  # the background
        h, w = np.ptp(ys) + 1, np.ptp(xs) + 1
        if len(p) > 0.004 * bb[2] ** 2 and 0.55 < h / w < 1.8 and ys.mean() > bb[1] + 0.2 * bb[3]:
            found.append((len(p), [xs.min(), ys.min(), xs.max() + 1, ys.max() + 1]))
    two = [r for _, r in sorted(found, key=lambda t: -t[0])[:2]]
    x0, y0 = min(r[0] for r in two), min(r[1] for r in two)
    return [x0, y0, max(r[2] for r in two) - x0, max(r[3] for r in two) - y0]


def part(pid):
    a = np.asarray(Image.open(os.path.join(PARTS, pid + ".png")).convert("RGBA")).astype(float)
    rgb, alpha = a[..., :3], a[..., 3] > 128
    l = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    s = np.where(rgb.max(2) > 0, (rgb.max(2) - rgb.min(2)) / np.maximum(rgb.max(2), 1), 0)
    return a.shape[1], a.shape[0], l, s, alpha


def place(target, inner, size, anchor):
    """The part's whole image (`size`), scaled so that its `inner` box fits in
    `target` keeping its shape, at `anchor`: 'center', 'bottom' (centred,
    bottoms level) or 'top' (centred, tops level)."""
    k = min(target[2] / inner[2], target[3] / inner[3])
    x = target[0] + target[2] / 2 - (inner[0] + inner[2] / 2) * k
    if anchor == "bottom":
        y = target[1] + target[3] - (inner[1] + inner[3]) * k
    elif anchor == "top":
        y = target[1] - inner[1] * k
    else:
        y = target[1] + target[3] / 2 - (inner[1] + inner[3] / 2) * k
    return [x, y, size[0] * k, size[1] * k]


def cut_worn(rid, acc):
    """The accessory out of a 'worn' picture: its colored fill, the dark
    outline round it, and what the fill encloses; written over the part."""
    a = np.asarray(Image.open(os.path.join(WORN_DIR, rid + ".png")).convert("RGBA")).astype(float)
    rgb, al = a[..., :3], a[..., 3]
    l = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    s = np.where(rgb.max(2) > 0, (rgb.max(2) - rgb.min(2)) / np.maximum(rgb.max(2), 1), 0)
    # Colored, however dark (a green hat's shade), or light; never the black body.
    fill = (al > 128) & (((s > 0.35) & (l > 20)) | ((s > 0.25) & (l > 50)) | (l > 170))
    # The outline is about 12 px wide in these pictures.
    grown = np.asarray(Image.fromarray((fill * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(25))) > 0
    mask = grown & (al > 8)
    outside = np.zeros_like(mask)
    q = deque((y, x) for y in range(mask.shape[0]) for x in (0, mask.shape[1] - 1) if not mask[y, x])
    q.extend((y, x) for x in range(mask.shape[1]) for y in (0, mask.shape[0] - 1) if not mask[y, x])
    for y, x in q:
        outside[y, x] = True
    while q:
        y, x = q.popleft()
        for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and not mask[ny, nx] and not outside[ny, nx]:
                outside[ny, nx] = True
                q.append((ny, nx))
    a[..., 3] = np.where(outside, 0, al)
    ys, xs = np.where(a[..., 3] > 8)
    Image.fromarray(a.astype(np.uint8)).crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)).save(os.path.join(PARTS, acc + ".png"))


WORN_DIR = os.path.join(os.path.dirname(os.path.abspath(PARTS)), "dango-src", "worn")
WORN = ["R03", "R05", "R06", "R07", "R12"]
for rid in WORN:
    cut_worn(rid, ROLES[rid]["accessory"])

HATS = {"R05", "R06", "R07", "R12"}
w, h, l, s, a = part("E01")
E_WHITES, E_SIZE, E_WHITE_MASK = box((l > 200) & a), (w, h), (l > 200) & a
B01 = np.asarray(Image.open(os.path.join(PARTS, "B01.png")).convert("RGBA"))[..., 3] > 128


def head_width(y):
    """The body's left and right edge (layout) at layout height `y`."""
    row = B01[min(B01.shape[0] - 1, max(0, int((y - BODY[1]) / BODY[3] * B01.shape[0])))]
    xs = np.where(row)[0]
    return BODY[0] + xs[0] / B01.shape[1] * BODY[2], BODY[0] + (xs[-1] + 1) / B01.shape[1] * BODY[2]


def columns(mask, r, lowest):
    """Per layout column x: the lowest (or highest) opaque layout y of `mask`
    drawn in rect `r`."""
    out = {}
    for x in range(int(r[0]), int(r[0] + r[2]) + 1):
        c = int((x - r[0]) / r[2] * mask.shape[1])
        if 0 <= c < mask.shape[1]:
            ys = np.where(mask[:, c])[0]
            if len(ys):
                out[x] = r[1] + ((ys[-1] + 1) if lowest else ys[0]) / mask.shape[0] * r[3]
    return out


def body_top(x):
    """The body's top (layout y) at layout column `x`, or None."""
    c = int((x - BODY[0]) / BODY[2] * B01.shape[1])
    if not 0 <= c < B01.shape[1] or not B01[:, c].any():
        return None
    return BODY[1] + np.where(B01[:, c])[0][0] / B01.shape[0] * BODY[3]


def fit_cover(pa, eyes_r):
    """A beanie or cap pulled on: the smallest size, anywhere across the head,
    at which it covers the head above its lower edge (no dome showing beside
    or above it), the lower edge resting on the eye whites' top."""
    ph, pw = pa.shape
    has = pa.any(0)
    low = np.where(has, ph - 1 - np.argmax(pa[::-1], 0), -1) + 1
    high = np.where(has, np.argmax(pa, 0), -1)
    whites = columns(E_WHITE_MASK, eyes_r, False)
    tops = {x: t for x in range(int(BODY[0]), int(BODY[0] + BODY[2]) + 1) if (t := body_top(x)) is not None}
    for w in np.arange(200, 480, 1.0):
        h = w * ph / pw
        for xo in sorted(range(-60, 61, 2), key=abs):
            x0 = 256 + xo - w / 2
            col = lambda x: int((x - x0) / w * pw)
            def edge(arr, x):
                c = col(x)
                return arr[c] / ph * h if 0 <= c < pw and has[c] else None
            y0 = min([whites[x] - edge(low, x) for x in whites if edge(low, x) is not None] + [np.inf])
            if y0 == np.inf:
                continue
            line = y0 + low[col(256)] / ph * h
            ok = all(edge(high, x) is not None and y0 + edge(high, x) <= t + 1.5 and y0 + edge(low, x) >= t
                     for x, t in tops.items() if t < line - 1)
            if ok:
                return [x0, y0, w, h]
    raise SystemExit("fit_cover: no size covers the head")


def touch(acc_r, pa, share=0.25):
    """Slides a small accessory toward the body's middle until `share` of it
    overlaps the body: the pencil rests on the head, not beside it (user,
    2026-11-07: 「笔和团子有间隙」)."""
    k = 2
    def mask(r):
        m = np.zeros((700 * k, 700 * k), bool)
        a = np.asarray(Image.fromarray((pa * 255).astype(np.uint8)).resize((max(1, round(r[2] * k)), max(1, round(r[3] * k))))) > 127
        x, y = round((r[0] + 100) * k), round((r[1] + 100) * k)
        m[y:y + a.shape[0], x:x + a.shape[1]] = a
        return m
    body = np.zeros((700 * k, 700 * k), bool)
    b = np.asarray(Image.fromarray(B01).resize((round(BODY[2] * k), round(BODY[3] * k)))) > 0
    x, y = round((BODY[0] + 100) * k), round((BODY[1] + 100) * k)
    body[y:y + b.shape[0], x:x + b.shape[1]] = b
    cx, cy = BODY[0] + BODY[2] / 2, BODY[1] + BODY[3] / 2
    ax, ay = acc_r[0] + acc_r[2] / 2, acc_r[1] + acc_r[3] / 2
    d = np.hypot(cx - ax, cy - ay)
    for step in range(0, int(d)):
        r = [acc_r[0] + (cx - ax) / d * step, acc_r[1] + (cy - ay) / d * step, acc_r[2], acc_r[3]]
        m = mask(r)
        if (m & body).sum() >= share * m.sum():
            return r
    return acc_r


def clear_eyes(acc_r, pa, eyes_r):
    """Lifts a hat until its lower edge clears the eye whites (the sheet's
    hats rest on the eyes' top, never over the whites)."""
    hat, whites = columns(pa, acc_r, True), columns(E_WHITE_MASK, eyes_r, False)
    lift = max([hat[x] - whites[x] for x in whites if x in hat] + [0])
    return [acc_r[0], acc_r[1] - lift, acc_r[2], acc_r[3]]


out = {"bodyRect": BODY}
for rid in sorted(ROLES):
    acc = ROLES[rid]["accessory"]
    l, s = cell(rid)
    pw, ph, pl, ps, pa = part(acc)
    if rid == "R10":
        # Braids reach the body's bottom, so the body can't be measured: the
        # pack's rects, lifted with the taller body.
        k = BODY[3] / 240
        lift = lambda r: [r[0], 400 - (400 - r[1]) * k, r[2], r[3] * k]
        out[rid] = {"eyeRect": lift(ROLES[rid]["eyeRect"]), "accessoryRect": lift(ROLES[rid]["accessoryRect"])}
        continue
    bb = body(rid)
    eyes = place(eye_whites(l, bb), E_WHITES, E_SIZE, "center")
    fill = (s > 0.30) & (l > 40) & (l < 252)
    if fill.sum() > 60:
        acc_r = place(box(fill), box((ps > 0.30) & (pl > 40) & (pl < 252) & pa), (pw, ph), "bottom" if rid in HATS else "center")
    else:
        # Black hair: what's black above the body (the tuft) or anywhere
        # above the eyes (the afro), matched by width and top.
        b = black(l, s)
        top_part = b[: int(bb[1] + (0.02 if rid == "R09" else 0.45) * bb[3])]
        hair = box(top_part)
        inner = box(pa)
        k = hair[2] / inner[2]
        acc_r = [hair[0] - inner[0] * k, hair[1] - inner[1] * k, pw * k, ph * k]
    eyes, acc_r = to_layout(bb, eyes), to_layout(bb, acc_r)
    if rid == "R12":
        # The headband goes all the way round: as wide as the head where it sits.
        cy = acc_r[1] + acc_r[3] / 2
        l0, l1 = head_width(cy)
        k = (l1 - l0) * 1.04 / acc_r[2]
        acc_r = [(l0 + l1) / 2 - acc_r[2] * k / 2, cy - acc_r[3] * k / 2, acc_r[2] * k, acc_r[3] * k]
    if rid == "R03":
        # The band sits on the head: its inside edge on the body's top.
        mid = pa[:, pa.shape[1] // 2]
        inside = np.where(~mid[np.where(mid)[0][0]:])[0][0] + np.where(mid)[0][0]
        top = BODY[1] + np.where(B01[:, B01.shape[1] // 2])[0][0] / B01.shape[0] * BODY[3]
        acc_r[1] = top - inside / pa.shape[0] * acc_r[3]
        # The eyes between the ear cups, as on the sheet, just clear of them
        # (the pack's cups are thicker than the sheet's, so the eyes shrink a little).
        wx0 = eyes[0] + E_WHITES[0] / E_SIZE[0] * eyes[2]
        wx1 = eyes[0] + (E_WHITES[0] + E_WHITES[2]) / E_SIZE[0] * eyes[2]
        wy = eyes[1] + (E_WHITES[1] + E_WHITES[3] / 2) / E_SIZE[1] * eyes[3]
        row = pa[min(pa.shape[0] - 1, int((wy - acc_r[1]) / acc_r[3] * pa.shape[0]))]
        gap = np.where(row[: pa.shape[1] // 2])[0][-1] + 1, pa.shape[1] // 2 + np.where(row[pa.shape[1] // 2:])[0][0]
        lin, rin = (acc_r[0] + g / pa.shape[1] * acc_r[2] for g in gap)
        lin, rin = lin + 0.01 * BODY[2], rin - 0.01 * BODY[2]
        k = min(1, (rin - lin) / (wx1 - wx0))
        cx, cy = (lin + rin) / 2 - ((wx0 + wx1) / 2 - eyes[0]) * k, eyes[1] + eyes[3] * (1 - k) / 2
        eyes = [cx, cy, eyes[2] * k, eyes[3] * k]
    if rid in ("R06", "R07"):
        acc_r = fit_cover(pa, eyes)
    if rid == "R11":
        acc_r = touch(acc_r, pa)
    if rid in HATS | {"R01"}:
        acc_r = clear_eyes(acc_r, pa, eyes)
    out[rid] = {"eyeRect": eyes, "accessoryRect": acc_r}

# Roles the pack doesn't have, drawn worn the same way (user, 2026-11-07:
# 「可以把他们的装饰都放到他们的团子上吗」): how each is worn decides its place.
EXTRA = {
    "R13": "neck",   # doctor: a stethoscope (a head mirror read as a miner's lamp, user 2026-11-07)
    "R14": "wig",    # lawyer: curled wig
    "R15": "cover",  # architect: hard hat
    "R16": "cover",  # chef: toque
    "R17": "neck",   # counselor: scarf
    "R18": "rest",   # financial analyst: top hat
    "R19": "cover",  # front-end engineer: propeller beanie
    "R20": "band",   # data entry clerk: eyeshade visor
    "R21": "band",   # scientist: goggles pushed up
}
PLAIN_EYES = list(np.mean([out[r]["eyeRect"] for r in ("R02", "R08")], 0))


def whites_box(eyes):
    """The eye whites' box (layout) in an eyes rect."""
    return [eyes[0] + E_WHITES[0] / E_SIZE[0] * eyes[2], eyes[1] + E_WHITES[1] / E_SIZE[1] * eyes[3],
            E_WHITES[2] / E_SIZE[0] * eyes[2], E_WHITES[3] / E_SIZE[1] * eyes[3]]


def fit_band(pa):
    """A band round the head: as wide as the head where it sits, resting on
    the eye whites."""
    ph, pw = pa.shape
    w = BODY[2]
    y = whites_box(PLAIN_EYES)[1] - w * ph / pw * 0.5
    for _ in range(4):
        h = w * ph / pw
        l0, l1 = head_width(y + h / 2)
        w = (l1 - l0) * 1.03
        h = w * ph / pw
        r = clear_eyes([(l0 + l1) / 2 - w / 2, whites_box(PLAIN_EYES)[1] - h * 0.5, w, h], pa, PLAIN_EYES)
        y = r[1]
    return r


def fit_rest(pa, share=0.5):
    """A small hat resting on top: `share` of the head's width, its brim's
    middle a little into the dome so it sits on it."""
    ph, pw = pa.shape
    w = BODY[2] * share
    h = w * ph / pw
    cx = BODY[0] + BODY[2] / 2
    bottom = columns(pa, [cx - w / 2, 0, w, h], True)
    mid = bottom[min(bottom, key=lambda x: abs(x - cx))]
    return [cx - w / 2, body_top(cx) + 0.06 * h - mid, w, h]


def fit_wig(pa):
    """A wig: wider than the head so its side curls hang beside it, the
    front hairline resting on the eye whites."""
    ph, pw = pa.shape
    w = BODY[2] * 1.12
    h = w * ph / pw
    return clear_eyes([BODY[0] + BODY[2] / 2 - w / 2, whites_box(PLAIN_EYES)[1] - h * 0.3, w, h], pa, PLAIN_EYES)


def fit_neck(pa, drop=30):
    """Something round the body's lower part (a scarf, a stethoscope), as
    wide as the body there, its bottom `drop` past the body's; the eyes
    move up to clear it."""
    ph, pw = pa.shape
    w = BODY[2]
    for _ in range(4):
        h = w * ph / pw
        l0, l1 = head_width(BODY[1] + BODY[3] + drop - h / 2)
        w = (l1 - l0) * 1.04
    h = w * ph / pw
    r = [BODY[0] + BODY[2] / 2 - w / 2, BODY[1] + BODY[3] + drop - h, w, h]
    eyes = list(PLAIN_EYES)
    wb = whites_box(eyes)
    tops = columns(pa, r, False)
    top = min([tops[x] for x in tops if wb[0] <= x <= wb[0] + wb[2]] + [np.inf])
    eyes[1] -= max(0, wb[1] + wb[3] - (top - 2))
    return r, eyes


for rid, how in EXTRA.items():
    if not os.path.exists(os.path.join(WORN_DIR, rid + ".png")):
        continue
    acc = "P" + rid[1:]
    cut_worn(rid, acc)
    pw, ph, pl, ps, pa = part(acc)
    eyes = list(PLAIN_EYES)
    if how == "cover":
        acc_r = fit_cover(pa, eyes)
    elif how == "band":
        acc_r = fit_band(pa)
    elif how == "rest":
        acc_r = fit_rest(pa)
    elif how == "wig":
        acc_r = fit_wig(pa)
    else:
        # The scarf's end hangs past the body; the stethoscope rests on it.
        acc_r, eyes = fit_neck(pa, drop=30 if rid == "R17" else -12)
    out[rid] = {"eyeRect": eyes, "accessoryRect": acc_r}

fmt = lambda r: "[" + ", ".join(f"{v:.1f}" for v in r) + "]"
print(f'let measuredBody: [CGFloat] = {fmt(out["bodyRect"])}')
# The plain 团子's eyes: the two plain-topped roles'.
print(f'let measuredPlainEyes: [CGFloat] = {fmt(PLAIN_EYES)}')
print("let measured: [String: [String: [CGFloat]]] = [")
for rid in sorted(set(ROLES) | (set(out) & set(EXTRA))):
    print(f'    "{rid}": ["eyeRect": {fmt(out[rid]["eyeRect"])}, "accessoryRect": {fmt(out[rid]["accessoryRect"])}],')
print("]")
