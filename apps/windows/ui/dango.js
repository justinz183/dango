// Shared by the pet and the panel: the data, the words in two languages, the
// numbers, and the 团子 put together from the design pack's parts the way
// apps/widget/theme.swift does (drawPackDango, packRoles, motion, the
// office's states and sky). Canvas coordinates are y down, as the Swift
// views that draw these are flipped.
"use strict";

const TAURI = window.__TAURI__;
const QUERY = new URLSearchParams(location.search);

// --- The data -------------------------------------------------------------

/// widget.json: from the app, or (opening the page in a browser to look at
/// it) from ?data=URL, default ./widget.json.
async function loadData() {
  if (TAURI) {
    const s = await TAURI.core.invoke("widget");
    return s ? JSON.parse(s) : null;
  }
  const r = await fetch(QUERY.get("data") || "widget.json", { cache: "no-store" });
  return r.ok ? r.json() : null;
}

/// Each page's clock: seconds since it opened, or ?t= to hold a moment.
const T0 = performance.now();
const clock = () => (QUERY.has("t") ? Number(QUERY.get("t")) : (performance.now() - T0) / 1000);
/// Now in ms; ?now= (ms) for a browser look at old data.
const nowMs = () => (QUERY.has("now") ? Number(QUERY.get("now")) : Date.now());

// --- Words and numbers ----------------------------------------------------

/// The interface language, as widget.json carries it.
const LANGS = ["zh", "en", "ko", "ja", "fr", "es"];
let lang = "zh";
/// The text in the interface language (one language a screen): the
/// Chinese, the English, or the English looked up in the language's table
/// (assets/i18n, as crates/core i18n.rs and the macOS app do).
const L = (zh, en) => (lang === "zh" ? zh : lang === "en" ? en : tr(en));

/// assets/i18n/<code>.json: English → the language's. A line with numbers
/// or names in it is a template with {} holes ({0}, {1} to reorder them).
const TABLES = {};
async function setLang(code) {
  code = LANGS.includes(code) ? code : "zh";
  if (code !== "zh" && code !== "en" && !TABLES[code]) {
    try {
      const t = await (await fetch("i18n/" + code + ".json")).json();
      const templates = Object.keys(t)
        .filter((k) => k.includes("{}") && k.replaceAll("{}", "").length > 1)
        .sort((a, b) => b.length - a.length)
        .map((k) => [new RegExp("^" + k.split("{}").map((p) => p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("(.+?)") + "$", "s"), t[k]]);
      TABLES[code] = { t, templates, done: new Map() };
    } catch (_) {
      TABLES[code] = { t: {}, templates: [], done: new Map() };
    }
  }
  lang = code;
}

/// The English in the interface language: the table's line, or a
/// template's with the numbers and names put back; else the English.
function tr(en) {
  const tab = TABLES[lang];
  if (!tab) return en;
  if (en in tab.t) return tab.t[en];
  if (tab.done.has(en)) return tab.done.get(en);
  let out = en;
  for (const [re, tpl] of tab.templates) {
    const m = en.match(re);
    if (m) {
      out = fill(tpl, m.slice(1));
      break;
    }
  }
  if (tab.done.size > 4000) tab.done.clear();
  tab.done.set(en, out);
  return out;
}

/// Fills {} holes in order, or {0}, {1} holes by number.
function fill(tpl, args) {
  if (args.some((_, i) => tpl.includes("{" + i + "}"))) return args.reduce((s, a, i) => s.replaceAll("{" + i + "}", a), tpl);
  for (const a of args) {
    const i = tpl.indexOf("{}");
    if (i < 0) break;
    tpl = tpl.slice(0, i) + a + tpl.slice(i + 2);
  }
  return tpl;
}

const fmtInt = (n) => Math.round(n).toLocaleString("en-US");
/// "$7.5" under ten, "$1,234" above; float dust is $0.0.
function fmtUSD(x) {
  x = Math.abs(x) < 0.05 ? 0 : x;
  return Math.abs(x) < 10 ? "$" + x.toFixed(1) : "$" + fmtInt(x);
}
/// "25 分钟" under an hour, "3.4 小时" under a hundred, "123 小时" above.
function fmtHours(h) {
  if (h < 1) return Math.round(h * 60) + " " + L("分钟", "min");
  if (h < 100) return h.toFixed(1) + L(" 小时", "h");
  return fmtInt(h) + L(" 小时", "h");
}
const fmtLev = (usd, cost) => (usd / cost).toFixed(1) + "×";

// --- Light or dark --------------------------------------------------------

/// "system", "light" or "dark" (the tray menu's 外观); ?dark=1 / ?dark=0 in a browser.
let appearanceChoice = "system";
async function loadAppearance() {
  if (TAURI) appearanceChoice = await TAURI.core.invoke("appearance");
  else appearanceChoice = QUERY.get("dark") === "1" ? "dark" : QUERY.get("dark") === "0" ? "light" : "system";
}
const isDark = () => appearanceChoice === "dark" || (appearanceChoice === "system" && matchMedia("(prefers-color-scheme: dark)").matches);

/// theme.swift V3: the panel's colours, light and dark.
const PALETTE = {
  light: { ink: "#1C1C1C", surface: "#FFFFFF", tile: "#F6F6F6", control: "#F4F4F4", line: "#E6E6E8", secondary: "#6E6E73", bar: "#DADADA", barZero: "#EDEDED",
           today: "#16A34A", track: "#E9E9E9", brand: "#2F7BF5", workingText: "#15803D", waitingText: "#B45309", onInk: "#FFFFFF", raised: "#FFFFFF" },
  dark: { ink: "#F2F2F7", surface: "#1C1C1E", tile: "#2C2C2E", control: "#2C2C2E", line: "#3A3A3C", secondary: "#A1A1A6", bar: "#48484A", barZero: "#2C2C2E",
          today: "#30D158", track: "#3A3A3C", brand: "#4F8DFF", workingText: "#30D158", waitingText: "#FFB340", onInk: "#1C1C1E", raised: "#3A3A3C" },
};
const colors = () => PALETTE[isDark() ? "dark" : "light"];
const OUTLINE = "#111111";

const MONO = '"JetBrains Mono", "Cascadia Mono", Consolas, "SF Mono", Menlo, "Microsoft YaHei UI", monospace';
const SANS = '"Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI", "PingFang SC", system-ui, sans-serif';

/// The office's sky by this computer's clock (Appearance.sky): how much of
/// the sunset and of the night picture go over the day's. ?hour= to look.
function sky(date = new Date()) {
  const h = QUERY.has("hour") ? Number(QUERY.get("hour")) : date.getHours() + date.getMinutes() / 60;
  if (h >= 7 && h < 17) return [0, 0];
  if (h >= 17 && h < 18) return [h - 17, 0];
  if (h >= 18 && h < 18.5) return [1, 0];
  if (h >= 18.5 && h < 19.5) return [1, h - 18.5];
  if (h >= 5 && h < 6) return [1, 6 - h];
  if (h >= 6 && h < 7) return [7 - h, 0];
  return [1, 1];
}

// --- States ---------------------------------------------------------------

/// What a state is called on the roster.
function statusName(s) {
  switch (s) {
    case "working": return L("在干", "working");
    case "happy": return L("开心", "happy");
    case "fuming": return L("冒烟", "fuming");
    case "waiting": return L("等你批准", "needs you");
    case "sleeping": return L("睡了", "asleep");
    case "off": return L("下班", "off");
    default: return L("摸鱼", "slacking");
  }
}

const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();

/// A job's state in the office and the roster (theme.swift officeStatus).
function officeStatus(o, m, now = nowMs()) {
  if (o.status && (o.status !== "happy" || !o.status_since || now - o.status_since < 30 * 60000)) return o.status;
  if (o.working) return "working";
  if (!(o.since > 0) || !sameDay(new Date(o.since), new Date(now))) return "off";
  const quiet = (now - o.since) / 60000;
  const job = m && m.activity && m.activity.job;
  if (job && job.id === o.id && ["happy", "proud"].includes(m.character && m.character.mood) && quiet < 30) return "happy";
  return quiet > 60 ? "sleeping" : "idle";
}

/// Eyes shut for 0.12 s every 4.3 s in the states whose eyes are open.
const blinking = (s, t) => ["working", "idle", "waiting", "fuming", "off"].includes(s) && (((t % 4.3) + 4.3) % 4.3) < 0.12;

// --- The 团子 from the design pack -----------------------------------------

/// The design's role for each job it has drawn; every other job is the plain 团子.
const PACK_ROLES = { designer: "R02", video: "R03", data: "R04", writer: "R05", swe: "R06", ops: "R07", pm: "R08", qa: "R09", research: "R11",
  musician: "R01", trainer: "R12", doctor: "R13", lawyer: "R14", architect: "R15", chef: "R16", counselor: "R17",
  fin: "R18", web: "R19", entry: "R20", scientist: "R21" };

/// The eyes for a state, as the pack's taskVisuals pair them.
function packEyes(s) {
  return { working: "E02", waiting: "E04", happy: "E06", fuming: "E07", sleeping: "E09" }[s] || "E01";
}

const IMAGES = {};
function image(path) {
  if (!IMAGES[path]) {
    const i = new Image();
    i.src = path;
    IMAGES[path] = i;
  }
  return IMAGES[path];
}
const part = (id) => image("art/dango/" + id + ".png");
const art = (name) => image("art/theme-b/" + name + ".png");
const ready = (i) => i && i.complete && i.naturalWidth > 0;

/// dango.json: the pack's 512 × 512 layout (y down).
let LAYOUT = {};
async function loadArt(extra = []) {
  LAYOUT = await (await fetch("art/dango/dango.json")).json();
  const ids = ["B01", "B01W"];
  for (let i = 1; i <= 12; i++) ids.push("E" + String(i).padStart(2, "0"));
  for (let i = 1; i <= 21; i++) ids.push("P" + String(i).padStart(2, "0"));
  const all = ids.map(part).concat(extra.map(art));
  await Promise.all(all.map((i) => (i.complete ? 0 : new Promise((r) => { i.onload = i.onerror = r; }))));
}

const rect = (a) => (Array.isArray(a) && a.length === 4 ? { x: a[0], y: a[1], w: a[2], h: a[3] } : null);

function packLayout(role) {
  const r = role && LAYOUT.roles ? LAYOUT.roles[role] : null;
  return {
    body: rect(LAYOUT.bodyRect) || { x: 80, y: 160, w: 352, h: 240 },
    eyes: (r && rect(r.eyeRect)) || rect(LAYOUT.defaultEyeRect) || { x: 151, y: 238, w: 212, h: 124 },
    accessory: r ? r.accessory : null,
    acc: (r && rect(r.accessoryRect)) || { x: 0, y: 0, w: 0, h: 0 },
  };
}

/// What a 团子 covers: its body and its accessory.
function extentOf(l) {
  if (!l.accessory) return l.body;
  const a = l.acc, b = l.body;
  const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
}

/// `size` fitted into `r` keeping its shape, centred (xMidYMid meet).
function fit(w, h, r) {
  const s = Math.min(r.w / w, r.h / h);
  return { x: r.x + r.w / 2 - (w * s) / 2, y: r.y + r.h / 2 - (h * s) / 2, w: w * s, h: h * s };
}

/// A 团子 whose body fills `body`: the body (white when dark), a flush on
/// the forehead when fuming, the state's eyes (one in each lens of the
/// glasses), then the role's accessory.
/// `opts.pose`: the state the paws show while the eyes blink; `opts.atDesk`:
/// the picture's laptop is the prop; `opts.t`: the clock for waving.
function drawPackDango(ctx, body, role, status, dark, opts = {}) {
  const l = packLayout(role), k = body.w / l.body.w;
  const place = (r) => ({ x: body.x + (r.x - l.body.x) * k, y: body.y + (r.y - l.body.y) * k, w: r.w * k, h: r.h * k });
  const draw = (img, f, r) => {
    if (!ready(img)) return;
    const p = place(r), W = img.naturalWidth, H = img.naturalHeight;
    f = f || [0, 0, 1, 1];
    ctx.drawImage(img, f[0] * W, f[1] * H, f[2] * W, f[3] * H, p.x, p.y, p.w, p.h);
  };
  draw(part(dark ? "B01W" : "B01"), null, l.body);
  if (status === "fuming") {
    const f = place({ x: l.body.x + l.body.w / 2 - 80, y: l.body.y + 26, w: 160, h: 56 });
    ctx.save();
    ctx.translate(f.x + f.w / 2, f.y + f.h / 2);
    ctx.scale(f.w / 2, f.h / 2);
    const g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
    g.addColorStop(0, "rgba(255,90,95,0.42)");
    g.addColorStop(1, "rgba(255,90,95,0)");
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.arc(0, 0, 1, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }
  const acc = l.accessory ? part(l.accessory) : null;
  const accRect = ready(acc) ? fit(acc.naturalWidth, acc.naturalHeight, l.acc) : null;
  const eid = packEyes(status), eyes = part(eid);
  if (ready(eyes)) {
    const holes = LAYOUT.accessoryHoles && LAYOUT.accessoryHoles[l.accessory];
    const parts = LAYOUT.eyeParts && LAYOUT.eyeParts[eid];
    if (accRect && holes && parts && holes.length === 2 && parts.length === 2) {
      for (let i = 0; i < 2; i++) {
        const h = holes[i], p = parts[i];
        const lens = { x: accRect.x + h[0] * accRect.w, y: accRect.y + h[1] * accRect.h, w: h[2] * accRect.w, h: h[3] * accRect.h };
        const inset = { x: lens.x + lens.w * 0.07, y: lens.y + lens.h * 0.07, w: lens.w * 0.86, h: lens.h * 0.86 };
        draw(eyes, p, fit(p[2] * eyes.naturalWidth, p[3] * eyes.naturalHeight, inset));
      }
    } else {
      draw(eyes, null, fit(eyes.naturalWidth, eyes.naturalHeight, l.eyes));
    }
  }
  if (accRect) draw(acc, null, accRect);
  drawPose(ctx, opts.pose || status, role, l, body, dark, !!opts.atDesk, opts.t || 0);
}

/// Paws and props in a state, the way the website's 团子 have them; the same
/// shapes as theme.swift `drawPose` (in the layout's units, y down).
function drawPose(ctx, status, role, l, body, dark, atDesk, t) {
  const k = body.w / l.body.w, W = l.body.w, H = l.body.h;
  const pt = (fx, fy) => [l.body.x + fx * W, l.body.y + fy * H];
  const fur = dark ? "#ECECEE" : "#211F1D", rim = dark ? "#1D1D1E" : "#030303", gloss = dark ? "#FFFFFF" : "#5A5853";
  ctx.save();
  ctx.translate(body.x - l.body.x * k, body.y - l.body.y * k);
  ctx.scale(k, k);
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  const line = (pts, color, w, close) => {
    ctx.beginPath();
    pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
    if (close) ctx.closePath();
    ctx.lineWidth = w;
    ctx.strokeStyle = color;
    ctx.stroke();
  };
  const shape = (pts, fillColor, w) => {
    ctx.beginPath();
    pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)));
    ctx.closePath();
    ctx.fillStyle = fillColor;
    ctx.fill();
    ctx.lineWidth = w;
    ctx.strokeStyle = rim;
    ctx.stroke();
  };
  const roundRect = (x, y, w, h, r, fillColor, stroke) => {
    ctx.beginPath();
    ctx.roundRect(x, y, w, h, r);
    ctx.fillStyle = fillColor;
    ctx.fill();
    if (stroke) { ctx.lineWidth = stroke; ctx.strokeStyle = rim; ctx.stroke(); }
  };
  /// A paw centred at (fx, fy), `w` of the body wide, turned `deg` (0 = claws down).
  const paw = (fx, fy, w = 0.15, deg = 0) => {
    const [cx, cy] = pt(fx, fy), pw = w * W, ph = pw * 0.78;
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate((deg * Math.PI) / 180);
    const pts = [];
    for (let i = 0; i <= 28; i++) {
      const a = (i / 28) * 2 * Math.PI, ry = Math.sin(a) > 0 ? (ph / 2) * 0.9 : ph / 2;
      pts.push([Math.cos(a) * (pw / 2), Math.sin(a) * ry]);
    }
    shape(pts, fur, 7.5);
    ctx.beginPath();
    ctx.moveTo(-pw * 0.26, -ph * 0.12);
    ctx.bezierCurveTo(-pw * 0.24, -ph * 0.28, -pw * 0.14, -ph * 0.33, -pw * 0.02, -ph * 0.32);
    ctx.lineWidth = 4.5;
    ctx.strokeStyle = gloss;
    ctx.stroke();
    [-0.14, 0.14].forEach((x) => line([[x * pw, ph * 0.46], [x * pw, ph * 0.18]], rim, 4));
    ctx.restore();
  };
  if (status === "working" && !atDesk) {
    if (role === "R11" || role === "R21") {
      const top = 0.66, bottom = 0.99, mid = 0.5, half = 0.36;
      shape([pt(mid, top + 0.05), pt(mid - half, top), pt(mid - half, bottom - 0.03), pt(mid, bottom), pt(mid + half, bottom - 0.03), pt(mid + half, top)], "#1F5C5E", 7);
      shape([pt(mid, top + 0.05), pt(mid - half + 0.03, top + 0.005), pt(mid - half + 0.03, top + 0.04), pt(mid, top + 0.09), pt(mid + half - 0.03, top + 0.04), pt(mid + half - 0.03, top + 0.005)], "#F4EEDC", 4);
      line([pt(mid, top + 0.05), pt(mid, bottom)], rim, 5);
      [0.1, 0.17, 0.24].forEach((h, i) => {
        const x = mid - half + 0.08 + i * 0.07;
        line([pt(x, bottom - 0.07), pt(x, bottom - 0.07 - h * 0.7)], "#D9EFEC", 8);
      });
      line([pt(mid + 0.15, top + 0.12), pt(mid + 0.15, top + 0.17), pt(mid + 0.1, bottom - 0.07), pt(mid + 0.27, bottom - 0.07), pt(mid + 0.22, top + 0.17), pt(mid + 0.22, top + 0.12)], "#D9EFEC", 5);
      paw(0.12, 0.86, 0.15, 70);
      paw(0.88, 0.86, 0.15, -70);
    } else {
      const [x0, y0] = pt(0.07, 0.85);
      roundRect(x0, y0, 0.86 * W, 0.14 * H, 0.025 * W, dark ? "#9EA2A8" : "#8F9399", 7);
      for (let row = 0; row < 2; row++)
        for (let i = 0; i < 12; i++) {
          const [x, y] = pt(0.105 + i * 0.066, 0.872 + row * 0.052);
          roundRect(x, y, 0.05 * W, 0.034 * H, 0.008 * W, "#D6D9DE", 0);
        }
      paw(0.3, 0.84, 0.15);
      paw(0.7, 0.84, 0.15);
    }
  } else if (status === "happy") {
    const swing = 14 * Math.sin((t / 0.9) * 2 * Math.PI);
    paw(0.99, 0.46, 0.17, -145 + swing);
    const [cx, cy] = pt(0.99, 0.46);
    [0.12, 0.17].forEach((r, i) => {
      ctx.beginPath();
      ctx.arc(cx, cy, r * W, (-55 * Math.PI) / 180, (5 * Math.PI) / 180);
      ctx.lineWidth = 5;
      ctx.strokeStyle = (dark ? "rgba(169,174,182," : "rgba(123,128,137,") + (i === 0 ? 0.9 : 0.6) + ")";
      ctx.stroke();
    });
  } else if (status === "waiting") {
    paw(0.01, 0.46, 0.17, 145);
    const blink = 0.55 + 0.45 * Math.cos((t / 1.4) * 2 * Math.PI);
    const [cx, cy] = pt(-0.03, 0.27);
    [[-0.09, -0.01], [-0.03, -0.09], [0.05, -0.08]].forEach(([dx, dy]) =>
      line([[cx + dx * W * 0.45, cy + dy * W * 0.45], [cx + dx * W, cy + dy * W]], `rgba(245,184,0,${blink})`, 8));
  } else if (status === "idle") {
    paw(0.3, 0.9, 0.13);
    paw(0.7, 0.9, 0.13);
  }
  ctx.restore();
}

/// The rect a role's whole 团子 takes when its body is `body`.
function packExtent(body, role) {
  const l = packLayout(role), e = extentOf(l), k = body.w / l.body.w;
  return { x: body.x + (e.x - l.body.x) * k, y: body.y + (e.y - l.body.y) * k, w: e.w * k, h: e.h * k };
}

/// A role's 团子, accessory and all, fitted into `box` and centred.
function drawFittedDango(ctx, box, role, status, dark, opts = {}) {
  const l = packLayout(role), e = extentOf(l), k = Math.min(box.w / e.w, box.h / e.h);
  const ex = box.x + box.w / 2 - (e.w * k) / 2, ey = box.y + box.h / 2 - (e.h * k) / 2;
  drawPackDango(ctx, { x: ex + (l.body.x - e.x) * k, y: ey + (l.body.y - e.y) * k, w: l.body.w * k, h: l.body.h * k }, role, status, dark, opts);
}

/// A job's 团子 fitted into `box` (the corner pet, the roster).
const themeDango = (ctx, box, job, status, dark, opts) => drawFittedDango(ctx, box, PACK_ROLES[job], status, dark, opts);

// --- Motion and the little things around a 团子 (tokens.json motion) -------

/// An offset, a vertical squash about the feet, and a tilt (degrees).
function motion(status, t) {
  const phase = (p) => (t % p) / p;
  const ease = (x) => (1 - Math.cos(x * Math.PI)) / 2;
  switch (status) {
    case "working": return { dx: 0, dy: (-3 * (1 - Math.cos(phase(1.1) * 2 * Math.PI))) / 2, sy: 1, rot: 0 };
    case "happy": {
      const p = phase(1.4);
      if (p < 0.3) { const k = ease(p / 0.3); return { dx: 0, dy: -8 * k, sy: 1 + 0.06 * k, rot: 0 }; }
      if (p < 0.6) { const k = ease((p - 0.3) / 0.3); return { dx: 0, dy: -8 * (1 - k), sy: 1.06 - 0.12 * k, rot: 0 }; }
      return { dx: 0, dy: 0, sy: 0.94 + 0.06 * ease((p - 0.6) / 0.4), rot: 0 };
    }
    case "fuming": {
      const p = phase(0.5) * 5, n = Math.floor(p), k = p - n, a = [0, -2, 2, -2, 2, 0];
      return { dx: a[n] + (a[Math.min(n + 1, 5)] - a[n]) * k, dy: 0, sy: 1, rot: 0 };
    }
    case "waiting": return { dx: 0, dy: 0, sy: 1, rot: -4 * Math.cos(phase(1.6) * 2 * Math.PI) };
    case "sleeping": return { dx: 0, dy: 0, sy: 1 + (0.03 * (1 - Math.cos(phase(3.2) * 2 * Math.PI))) / 2, rot: 0 };
    default: return { dx: 0, dy: 0, sy: 1, rot: 0 };
  }
}

/// Draws `body` with a state's motion applied to `box`.
function moving(ctx, status, t, box, body) {
  const m = motion(status, t);
  const fx = box.x + box.w / 2, fy = box.y + box.h, py = box.y + box.h * 0.9;
  ctx.save();
  ctx.translate(m.dx, m.dy);
  ctx.translate(fx, fy);
  ctx.scale(1, m.sy);
  ctx.translate(-fx, -fy);
  if (m.rot) {
    ctx.translate(fx, py);
    ctx.rotate((m.rot * Math.PI) / 180);
    ctx.translate(-fx, -py);
  }
  body();
  ctx.restore();
}

/// z z when asleep, steam when fuming (needing you is a raised paw, `drawPose`).
function stateExtras(ctx, status, t, box) {
  const above = (dx, dy) => ({ x: box.x + dx, y: box.y - dy });
  const s = box.w / 52;
  const wrap = (v, p) => ((v % p) + p) % p;
  ctx.save();
  if (status === "sleeping") {
    [[box.w - 4 * s, 4 * s, 12 * s], [box.w + 4 * s, 14 * s, 15 * s]].forEach(([dx, dy, size], k) => {
      const p = wrap(t - k * 0.7, 2.2) / 2.2;
      const alpha = p < 0.3 ? p / 0.3 : 1 - (p - 0.3) / 0.7;
      const pt = above(dx, dy + (-3 + 11 * p) * s);
      ctx.font = `${size}px ${MONO}`;
      ctx.textBaseline = "top";
      ctx.fillStyle = `rgba(138,130,120,${alpha})`;
      ctx.fillText("z", pt.x, pt.y - size);
    });
  } else if (status === "fuming") {
    [[0.3, 6, 8], [0.5, 10, 10], [0.66, 4, 7]].forEach(([fx, dy, d], k) => {
      const p = wrap(t - k * 0.4, 1.3) / 1.3;
      const alpha = p < 0.4 ? (p / 0.4) * 0.9 : 0.9 * (1 - (p - 0.4) / 0.6);
      const size = d * (0.6 + 0.6 * p) * s;
      const c = above(box.w * fx + (d / 2) * s, dy * s + 16 * p * s);
      ctx.beginPath();
      ctx.arc(c.x, c.y, size / 2, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(184,178,168,${alpha})`;
      ctx.fill();
    });
  }
  ctx.restore();
}

/// A canvas `w` × `h` CSS pixels, sharp on this screen; its context is in CSS pixels.
function sharpCanvas(canvas, w, h) {
  const k = window.devicePixelRatio || 1;
  canvas.width = Math.round(w * k);
  canvas.height = Math.round(h * k);
  canvas.style.width = w + "px";
  canvas.style.height = h + "px";
  const ctx = canvas.getContext("2d");
  ctx.setTransform(k, 0, 0, k, 0, 0);
  ctx.imageSmoothingQuality = "high";
  return ctx;
}

/// Calls `f(event payload)` on an app event (nothing in a browser).
function onAppEvent(name, f) {
  if (TAURI) TAURI.event.listen(name, (e) => f(e.payload));
}
const invoke = (cmd, args) => (TAURI ? TAURI.core.invoke(cmd, args) : Promise.resolve(null));
