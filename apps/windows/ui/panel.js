// The panel (theme.swift layoutV3): the word mark and the day, the
// illustrated office, today's dollars with the model cost and leverage, the
// week / month / total, the boss type, 1 / 7 / 30 days, the staff, the
// tools, the bars, and sharing today's report.
"use strict";

const content = document.getElementById("content");
const preview = !TAURI;
if (preview) document.body.classList.add("page");

let model = null;
let range = (() => {
  const q = Number(QUERY.get("range"));
  if ([1, 7, 30].includes(q)) return q;
  try {
    const r = Number(localStorage.getItem("range"));
    return [1, 7, 30].includes(r) ? r : 30;
  } catch (_) {
    return 30;
  }
})();
let jobsOpen = QUERY.get("open") === "1";

const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const el = (html) => {
  const t = document.createElement("template");
  t.innerHTML = html.trim();
  return t.content.firstElementChild;
};
const num = (o, k) => (o && typeof o[k] === "number" ? o[k] : 0);

function applyTheme() {
  document.documentElement.classList.toggle("dark", isDark());
}

// --- The office (V3OfficeView) ---------------------------------------------

const OFFICE = { w: 392, h: 178 };
/// The two desk places' left edges (50 wide), behind the laptops of the
/// designer's office (tools/office_art.py); the same as theme.swift.
const DESK_X = [209.2, 272.6];
let officeCtx = null;
let dimCanvas = null;
const walks = new Map();

const feet = (x, bottom, w) => ({ x, y: bottom - (w * 110) / 120, w, h: (w * 110) / 120 });

/// Two desks for working / happy / fuming, a place to stand for waiting,
/// the sofa's three seats for idle and sleeping; off is outside.
function arrangement(m) {
  const all = (m.office || []).map((o) => [o, officeStatus(o, m)]);
  const desk = all.filter(([, s]) => ["working", "happy", "fuming"].includes(s)).slice(0, 2);
  const stand = all.filter(([, s]) => s === "waiting").slice(0, 1);
  const lounge = all.filter(([, s]) => ["idle", "sleeping"].includes(s)).slice(0, 3);
  const out = [];
  for (const [o, s] of stand) out.push([o, s, feet(7, 166, 46)]);
  desk.forEach(([o, s], i) => out.push([o, s, feet(DESK_X[i], 131, 50)]));
  const seats = [86.2, 122.4, 158.2].map((x) => feet(x - 23, 146.7, 46));
  lounge.forEach(([o, s], i) => out.push([o, s, seats[i]]));
  return out;
}

/// The place now, walking there in 0.9 s (ease in and out) when it changed.
function walkTo(id, to, t) {
  if (QUERY.has("t")) return to;
  let w = walks.get(id) || { from: { x: -90, y: to.y, w: to.w, h: to.h }, to, start: t };
  const same = (a, b) => a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;
  if (!same(w.to, to)) w = { from: walkAt(w, t), to, start: t };
  walks.set(id, w);
  return walkAt(w, t);
}
function walkAt(w, t) {
  const p = Math.min(1, Math.max(0, (t - w.start) / 0.9)), k = p * p * (3 - 2 * p);
  const mix = (a, b) => a + (b - a) * k;
  return { x: mix(w.from.x, w.to.x), y: mix(w.from.y, w.to.y), w: mix(w.from.w, w.to.w), h: mix(w.from.h, w.to.h) };
}

function rrectFill(ctx, x, y, w, h, r, c) {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, r);
  ctx.fillStyle = c;
  ctx.fill();
}

function drawOffice() {
  if (!officeCtx || !model) return;
  const ctx = officeCtx, t = clock(), dark = isDark(), { w: W, h: H } = OFFICE;
  ctx.clearRect(0, 0, W, H);
  ctx.save();
  ctx.beginPath();
  ctx.roundRect(0, 0, W, H, 24);
  ctx.clip();
  const [dusk, night] = sky();
  // The dark theme's 团子 are white and the picture is a light room, so there
  // the room goes darker, less at night when it already is (theme.swift
  // `drawRoom`; user, 2026-11-09: 「暗色背景这个办公室和白团子的对比不够明显」).
  const dim = dark ? 0.45 - 0.2 * night : 0;
  const layer = (c, name, alpha) => {
    const i = art(name);
    if (alpha > 0 && ready(i)) {
      c.globalAlpha = alpha;
      c.drawImage(i, 0, 0, W, H);
      c.globalAlpha = 1;
    }
  };
  // Draws the layers on their own canvas, darkens only what they cover, and
  // puts that on the office.
  const dimmed = (names) => {
    if (!dim) return names.forEach(([name, alpha]) => layer(ctx, name, alpha));
    const k = ctx.getTransform().a;
    const off = (dimCanvas ||= document.createElement("canvas"));
    off.width = Math.round(W * k);
    off.height = Math.round(H * k);
    const c = off.getContext("2d");
    c.setTransform(k, 0, 0, k, 0, 0);
    names.forEach(([name, alpha]) => layer(c, name, alpha));
    c.globalCompositeOperation = "source-atop";
    c.fillStyle = `rgba(15,20,36,${dim})`;
    c.fillRect(0, 0, W, H);
    ctx.drawImage(off, 0, 0, W, H);
  };
  if (ready(art("room"))) {
    dimmed([["room", 1], ["room-dusk", dusk], ["room-night", night]]);
  } else {
    ctx.fillStyle = "#FBF3E4";
    ctx.fillRect(0, 0, W, H);
  }
  const people = arrangement(model);
  for (const id of [...walks.keys()]) if (!people.some(([o]) => o.id === id)) walks.delete(id);
  officeSpots = [];
  const b = packLayout(null).body;
  people.forEach(([o, s, place], i) => {
    // The body a little narrower than the place, standing on its floor.
    const w = place.w * 0.86, h = (w * b.h) / b.w;
    const at = walkTo(o.id, { x: place.x + place.w / 2 - w / 2, y: place.y + place.h - h, w, h }, t);
    const phase = i * 0.41, role = PACK_ROLES[o.id];
    const eyes = blinking(s, t + phase * 7) ? "sleeping" : s;
    moving(ctx, s, t + phase, at, () => drawPackDango(ctx, at, role, eyes, dark, { pose: s, atDesk: ["working", "happy", "fuming"].includes(s), t: t + phase }));
    stateExtras(ctx, s, t + phase, packExtent(at, role));
    officeSpots.push({ r: packExtent(at, role), job: o.name || o.id, s });
  });
  dimmed([["room-front", 1], ["room-front-dusk", dusk], ["room-front-night", night]]);
  drawHoverLabel(ctx, W);
  ctx.restore();
}

/// Hovering a 团子 shows its job and state, as theme.swift `drawHoverLabel`
/// (?hover=N pins it over the N'th in a browser).
let officeSpots = [];
let officePointer = null;
function drawHoverLabel(ctx, W) {
  const pin = QUERY.has("hover") ? officeSpots[Number(QUERY.get("hover"))] : null;
  const p = officePointer;
  const spot = pin || (p && [...officeSpots].reverse().find(({ r }) => p.x >= r.x - 2 && p.x <= r.x + r.w + 2 && p.y >= r.y - 2 && p.y <= r.y + r.h + 2));
  if (!spot) return;
  const job = spot.job + " · ", state = statusName(spot.s);
  ctx.save();
  ctx.font = `500 11px ${SANS}`;
  const wJob = ctx.measureText(job).width;
  ctx.font = `600 11px ${SANS}`;
  const w = wJob + ctx.measureText(state).width + 18, h = 20;
  const x = Math.min(Math.max(4, spot.r.x + spot.r.w / 2 - w / 2), W - 4 - w), y = Math.max(4, spot.r.y - h - 4);
  rrectFill(ctx, x, y, w, h, h / 2, "rgba(26,26,26,0.88)");
  ctx.textBaseline = "middle";
  ctx.font = `500 11px ${SANS}`;
  ctx.fillStyle = "rgba(255,255,255,0.75)";
  ctx.fillText(job, x + 9, y + h / 2 + 0.5);
  ctx.font = `600 11px ${SANS}`;
  ctx.fillStyle = "#FFFFFF";
  ctx.fillText(state, x + 9 + wJob, y + h / 2 + 0.5);
  ctx.restore();
}

// --- The rest of the panel ---------------------------------------------------

const WORDMARK = `<span class="wordmark">D<img src="art/theme-b/logo-dango.png" alt="">NGO</span>`;
const CHEVRON = `<svg width="12" height="7" viewBox="0 0 12 7"><path d="M1 1l5 5 5-5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

/// "2026-10-29" → "10/29".
const shortDay = (d) => {
  const p = String(d).split("-");
  return p.length === 3 ? `${Number(p[1])}/${Number(p[2])}` : d;
};

function dangoCanvas(w, h, job, status) {
  const c = document.createElement("canvas");
  themeDango(sharpCanvas(c, w, h), { x: 0, y: 0, w, h }, job, status, isDark());
  return c;
}

const DOT = { working: "#16A34A", happy: "#16A34A", waiting: "#D97706", fuming: "#DC2626", off: "#E6E6E8" };

function render() {
  const m = model;
  applyTheme();
  content.textContent = "";
  if (!m) {
    content.append(el(`<div class="sec" style="font:500 13px var(--sans)">${L("等待数据…", "Waiting for data…")}</div>`));
    return fitWindow();
  }
  const today = m.today || {}, week = m.week || {}, month = m.month || {}, total = m.total || {};
  const days = (m.character && m.character.days_together) || 0;

  // 1. Top bar: the word mark, the day, a round button that closes.
  const top = el(`<div class="row top">${WORDMARK}<span class="day">${L(`第 ${days} 天`, `day ${days}`)}</span>
    <button class="round-btn" style="margin-left:auto" title="${L("收起", "Close")}">${CHEVRON}</button></div>`);
  top.querySelector("button").onclick = () => invoke("close_panel");
  content.append(top);

  // 2. The office.
  const office = document.createElement("canvas");
  office.id = "office";
  officeCtx = sharpCanvas(office, OFFICE.w, OFFICE.h);
  office.addEventListener("mousemove", (e) => {
    const r = office.getBoundingClientRect();
    officePointer = { x: ((e.clientX - r.left) * OFFICE.w) / r.width, y: ((e.clientY - r.top) * OFFICE.h) / r.height };
  });
  office.addEventListener("mouseleave", () => { officePointer = null; });
  content.append(office);

  // 3. Today, its model cost and leverage, whether it is the best day; the line.
  const record = (m.record && m.record.day_usd) || 0;
  const beating = record > 0 && num(today, "usd") + 1e-9 >= record && num(today, "usd") > 0;
  const lev = num(today, "cost") >= 0.01 ? ` · ${fmtUSD(today.cost)} · ${fmtLev(today.usd, today.cost)}` : "";
  content.append(el(`<div class="hero">${fmtUSD(num(today, "usd"))}</div>`));
  content.append(el(`<div class="hero-sub"><i></i><span>${esc(L("今天的产出", "Today's output") + lev + (beating ? L(" · 单日纪录", " · best day") : ""))}</span></div>`));
  const line = (m.character && m.character.line) || "";
  if (line) content.append(el(`<div class="line">${esc(line)}</div>`));
  const cells = [[L("本周", "This week"), week], [L("本月", "This month"), month], [L("总计", "Total"), total]];
  content.append(el(`<div class="strip">${cells.map(([k, c]) => `<div class="cell"><div class="k">${k}</div><div class="v">${fmtUSD(num(c, "usd"))}</div>
    <div class="s">${num(c, "cost") >= 0.01 ? fmtUSD(c.cost) + " · " + fmtLev(c.usd, c.cost) : fmtHours(num(c, "hours"))}</div></div>`).join("")}</div>`));

  // 3b. Who you are as a boss (the boss card window comes in a later version).
  const b = m.boss;
  if (b && b.code) {
    const margin = L("压榨率 ", "Margin ") + ((b.margin || 0) * 100).toFixed(1) + "%";
    const full = margin + (b.margin_tier ? " · " + b.margin_tier : "");
    const box = el(`<div class="boss"><img src="art/scene/T-${esc(b.code)}.png" alt="">
      <div class="body"><div class="name"><div><b>${esc(b.code)} </b><span>${esc(b.name)}</span></div><em>ABTI ›</em></div>
      <div class="pills"><span class="pill dark">${esc(L(b.scale + "级", b.scale + " tier"))}</span><span class="pill">${esc(full)}</span></div>
      <div class="roast">${esc(b.roast)}</div></div></div>`);
    content.append(box);
    // The margin's tier name only when it fits on the line.
    requestAnimationFrame(() => {
      const pills = box.querySelector(".pills");
      if (pills.scrollWidth > pills.clientWidth) pills.lastElementChild.textContent = margin;
    });
  }

  // 4. 1D · 7D · 30D: the window of what follows.
  const ranges = el(`<div class="ranges">${[[1, L("1 天", "1D")], [7, L("7 天", "7D")], [30, L("30 天", "30D")]]
    .map(([d, t]) => `<button data-d="${d}" class="${d === range ? "on" : ""}">${t}</button>`).join("")}</div>`);
  ranges.querySelectorAll("button").forEach((btn) => (btn.onclick = () => {
    const d = Number(btn.dataset.d);
    if (d === range) return;
    range = d;
    jobsOpen = false;
    try { localStorage.setItem("range", String(d)); } catch (_) {}
    render();
  }));
  content.append(ranges);

  // 6. The roster: each job of the window, styled by its state.
  const jobs = ((range === 1 ? m.jobs_1d : range === 7 ? m.jobs_7d : m.jobs) || []).filter((j) => j.usd > 0);
  const stateOf = (id) => {
    const o = (m.office || []).find((x) => x.id === id);
    return o ? officeStatus(o, m) : "off";
  };
  const states = jobs.map((j) => stateOf(j.id));
  const count = (set) => states.filter((s) => set.includes(s)).length;
  const counts = [[count(["working", "happy", "fuming"]), L("在干", "working")], [count(["waiting"]), L("等你批准", "need you")], [count(["idle", "sleeping"]), L("摸鱼", "slacking")]]
    .filter(([n]) => n > 0).map(([n, t]) => `${n} ${t}`).join(" · ");
  const head = el(`<div class="row roster-head"><span class="title">${L("员工名册", "Your staff")}</span><span class="count">${esc(counts)}</span>
    <div class="btns"><button class="round-btn" data-id="menu">…</button><button class="round-btn" data-id="expand">${jobsOpen ? "−" : "+"}</button></div></div>`);
  head.querySelector('[data-id="menu"]').onclick = () => invoke("pet_menu");
  head.querySelector('[data-id="expand"]').onclick = () => { jobsOpen = !jobsOpen; render(); };
  content.append(head);
  if (!jobs.length) {
    content.append(el(`<div class="empty">${L("这段时间还没有活", "No work in this window yet")}</div>`));
  } else {
    const shown = jobsOpen ? jobs.length : Math.min(6, jobs.length);
    const cards = el(`<div class="cards"></div>`);
    for (let i = 0; i < shown; i++) {
      const j = jobs[i], s = states[i];
      const busy = ["working", "happy", "fuming"].includes(s), off = s === "off";
      const card = el(`<div class="card ${busy ? "busy" : s === "waiting" ? "waiting" : off ? "off" : ""}"><div class="txt">
        <div class="t">${!off && s !== "idle" && s !== "sleeping" ? `<i style="background:${DOT[s] || "#B5B5BA"}"></i>` : ""}<span>${esc(j.name + " · " + statusName(s))}</span></div>
        <div class="s">${fmtHours(j.hours)} · ${fmtUSD(j.usd)}</div></div></div>`);
      card.prepend(dangoCanvas(36, 30, j.id, busy ? "working" : s === "sleeping" ? "sleeping" : "idle"));
      cards.append(card);
    }
    content.append(cards);
    if (!jobsOpen && jobs.length > 6) {
      const rest = jobs.slice(6), allOff = states.slice(6).every((s) => s === "off");
      const sum = fmtUSD(rest.reduce((a, j) => a + j.usd, 0));
      const more = el(`<div class="more"><span>${esc(L(`还有 ${rest.length} 种 · ${sum}`, `${rest.length} more · ${sum}`) + (allOff ? L(" · 都下班了", " · all off") : ""))}</span></div>`);
      const pics = document.createElement("canvas");
      const pctx = sharpCanvas(pics, 46, 26);
      rest.slice(0, 2).forEach((j, k) => themeDango(pctx, { x: k * 16, y: 0, w: 30, h: 26 }, j.id, "off", isDark()));
      more.prepend(pics);
      more.onclick = () => { jobsOpen = true; render(); };
      content.append(more);
    }
  }

  // 7. The agents side by side, biggest first.
  const tools = ((range === 1 ? m.tools_1d : range === 7 ? m.tools_7d : m.tools) || []).filter((t) => t.usd > 0).slice(0, 4);
  const shades = [colors().ink, "#636366", "#AEAEB2", "#D1D1D6"];
  if (tools.length) {
    const figures = (t) => ((t.share || 0) * 100).toFixed(0) + "%" + (num(t, "cost") >= 0.01 ? " · " + fmtLev(t.usd, t.cost) : "");
    let ends = [], x = 0;
    for (const t of tools) ends.push((x += (t.share || 0) * 100));
    const bar = tools.map((_, k) => k).reverse().map((k) => `<i style="width:max(6px, ${ends[k]}%);background:${shades[k]}"></i>`).join("");
    const legend = tools.length <= 2
      ? `<div class="row between">${tools.map((t) => `<span>${esc(t.name)} <span class="sec">${figures(t)}</span></span>`).join("")}</div>`
      : tools.map((t, k) => `<div class="row between"><span><i class="dot" style="background:${shades[k]}"></i>${esc(t.name)}</span><span class="sec">${figures(t)}</span></div>`).join("");
    content.append(el(`<div class="tools"><div class="row between head"><span class="title">${L("工具分布", "By tool")}</span>
      <span class="note">${L(`${range} 天 · 产出 ÷ 花费`, `${range}D · output ÷ cost`)}</span></div><div class="bar">${bar}</div><div class="legend">${legend}</div></div>`));
  }

  // 8. The last 30 (7) days, or today by hour.
  let bars = [], first = "", middle = "", last = "";
  if (range === 1) {
    bars = Array.from({ length: 24 }, (_, i) => (m.hours || [])[i] || 0);
    [first, middle, last] = ["0:00", "12:00", L("现在", "now")];
  } else {
    const ds = (m.days || []).slice(-range);
    bars = ds.map((d) => d.usd || 0);
    if (ds.length) [first, middle, last] = [shortDay(ds[0].day), shortDay(ds[Math.floor(ds.length / 2)].day), shortDay(ds[ds.length - 1].day)];
  }
  const sum = bars.reduce((a, x) => a + x, 0), maxU = Math.max(...bars, 0.01);
  const current = range === 1 ? new Date().getHours() : bars.length - 1;
  const right = range === 1 ? L("共 ", "total ") + fmtUSD(sum) : L("日均 ", "avg ") + fmtUSD(bars.length ? sum / bars.length : 0) + L("", "/d");
  const nowUSD = range === 1 ? bars[current] || 0 : bars[bars.length - 1] || 0;
  content.append(el(`<div class="chart"><div class="row between head"><span class="title">${range === 1 ? L("今天每小时", "Today by hour") : L(`最近 ${range} 天`, `Last ${range} days`)}</span>
    <span class="note">${right}</span></div>
    <div class="bars">${bars.map((u, i) => `<i class="${i === current ? "now" : u > 0 ? "" : "zero"}" style="height:${u > 0 ? Math.max(4, (90 * u) / maxU) : 2}px"></i>`).join("")}</div>
    <div class="axis"><span>${first}</span><span>${middle}</span><b>${esc(last)} · ${fmtUSD(nowUSD)}</b></div></div>`));

  // 9. Where the money comes from, and share today's report.
  const row = el(`<div class="row bottom"><span class="note">${L("按 BLS 中位时薪折算", "At BLS median wages")}</span>
    <button class="share">⇪&nbsp; ${L("分享日报", "Share today")}</button></div>`);
  const share = row.querySelector(".share");
  share.onclick = () => shareToday(share);
  content.append(row);

  drawOffice();
  fitWindow();
}

/// Today's report as text on the clipboard (the 4:5 share image comes in a
/// later version): no session titles or project names.
async function shareToday(btn) {
  const was = btn.innerHTML;
  try {
    const text = await invoke("daily_report");
    if (!text) throw new Error("no report");
    await copy(text);
    btn.textContent = L("日报已复制 ✓", "Copied ✓");
  } catch (_) {
    btn.textContent = L("没复制成功", "Couldn't copy");
  }
  setTimeout(() => (btn.innerHTML = was), 2000);
}

async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (_) {
    const t = document.createElement("textarea");
    t.value = text;
    document.body.append(t);
    t.select();
    document.execCommand("copy");
    t.remove();
  }
}

/// Tells the app how tall the panel is, so its window fits it (measured
/// now: a hidden window gets no animation frames).
function fitWindow() {
  if (TAURI) invoke("panel_height", { height: content.offsetHeight });
}

async function reload() {
  const m = await loadData().catch(() => null);
  if (!m) return;
  const changed = !model || m.generated_at !== model.generated_at || m.lang !== model.lang;
  await setLang(m.lang);
  model = m;
  if (changed) render();
}

let lastFrame = 0;
function frame(ts) {
  if (ts - lastFrame >= 1000 / 24 - 1) {
    lastFrame = ts;
    drawOffice();
  }
  requestAnimationFrame(frame);
}

window.addEventListener("keydown", (e) => {
  if (e.key === "Escape") invoke("close_panel");
});
onAppEvent("shown", () => {
  document.getElementById("scroll").scrollTop = 0;
  fitWindow();
  reload();
});
onAppEvent("reload", () => setTimeout(reload, 600));
onAppEvent("appearance", (a) => {
  appearanceChoice = a;
  render();
});
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => render());

(async () => {
  await loadAppearance();
  await loadArt(["room", "room-dusk", "room-night", "room-front", "room-front-dusk", "room-front-night"]);
  await reload();
  if (!model) render();
  setInterval(reload, 2000);
  requestAnimationFrame(frame);
})();
