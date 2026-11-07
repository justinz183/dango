// The corner pet (main.swift PetView, theme.swift drawCard): just the 团子,
// in the job at hand and its state; a dark pill above it now and then —
// news, a settled turn, or today's total while the pointer is on it.
// Click: the panel. Drag: move it. Right-click: the menu.
"use strict";

const W = 230, H = 140;
/// theme.swift cardRect, y down.
const BOX = { x: (W - 84) / 2, y: H - 10 - 74, w: 84, h: 74 };

const canvas = document.getElementById("pet");
const ctx = sharpCanvas(canvas, W, H);
if (QUERY.get("backdrop") === "1") document.body.classList.add("backdrop");

let model = null;
let lastTurnAt = 0;
let receipts = [];
let flash = { text: QUERY.get("flash") || "", until: QUERY.has("flash") ? Infinity : -1 };
let hovering = QUERY.get("hover") === "1";

function showFlash(text) {
  flash = { text, until: clock() + 6 };
}

async function reload() {
  const m = await loadData().catch(() => null);
  if (!m) return;
  await setLang(m.lang);
  const first = (m.turns || [])[0];
  if (first) {
    if (lastTurnAt > 0 && first.at > lastTurnAt) receipts.push({ usd: first.usd, name: first.name || "", born: clock() });
    lastTurnAt = Math.max(lastTurnAt, first.at);
  }
  const old = model;
  const rec = (x) => (x && x.record && x.record.day_usd) || 0, today = (x) => (x && x.today && x.today.usd) || 0;
  if (old && rec(old) > 0 && today(old) < rec(old) && today(m) >= rec(m) && rec(m) > 0) showFlash(L("单日新高 ✦ ", "New best day ✦ ") + fmtUSD(today(m)));
  model = m;
  if (QUERY.get("receipt") === "1" && first && !receipts.length) receipts.push({ usd: first.usd, name: first.name || "", born: Infinity });
}

/// The current job's state in the office, else the pet's own mood.
function petStatus(m) {
  const job = m.activity && m.activity.job;
  const mine = job && (m.office || []).find((o) => o.id === job.id);
  const s = mine ? officeStatus(mine, m) : null;
  if (s && ["working", "waiting", "fuming", "happy"].includes(s)) return s;
  if ((m.activity && m.activity.working) > 0) return "working";
  const mood = m.character && m.character.mood;
  return ["happy", "proud"].includes(mood) ? "happy" : mood === "sleepy" ? "sleeping" : "idle";
}

function pillText() {
  const t = clock();
  if (t < flash.until) return [{ text: flash.text, font: `600 11.5px ${SANS}`, color: "#fff" }];
  receipts = receipts.filter((r) => r.born === Infinity || t - r.born <= 2.8);
  const rc = receipts[receipts.length - 1];
  if (rc) return [{ text: "+" + fmtUSD(rc.usd) + (rc.name ? " · " + rc.name : ""), font: `600 11.5px ${MONO}`, color: "#fff" }];
  if (hovering && model) {
    return [
      { text: L("今天 ", "Today "), font: `500 11.5px ${SANS}`, color: "rgba(255,255,255,0.7)" },
      { text: fmtUSD((model.today && model.today.usd) || 0), font: `600 11.5px ${MONO}`, color: "#fff" },
    ];
  }
  return null;
}

function draw() {
  ctx.clearRect(0, 0, W, H);
  if (!model) return;
  const t = clock(), dark = isDark();
  const status = petStatus(model);
  // A soft shadow on the ground, then the 团子 bobbing slowly over it.
  const bob = (3 * (1 - Math.cos((t / 3) * 2 * Math.PI))) / 2;
  const sh = { x: BOX.x + BOX.w / 2 - 34 + bob, y: H - 5 - 11, w: 68 - 2 * bob, h: 11 };
  ctx.save();
  ctx.translate(sh.x + sh.w / 2, sh.y + sh.h / 2);
  ctx.scale(sh.w / 2, sh.h / 2);
  const g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
  g.addColorStop(0, "rgba(0,0,0,0.22)");
  g.addColorStop(1, "rgba(0,0,0,0)");
  ctx.fillStyle = g;
  ctx.beginPath();
  ctx.arc(0, 0, 1, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
  const face = { x: BOX.x, y: BOX.y - bob, w: BOX.w, h: BOX.h };
  const job = (model.activity && model.activity.job && model.activity.job.id) || "";
  themeDango(ctx, face, job, blinking(status, t) ? "sleeping" : status, dark);
  stateExtras(ctx, status, t, face);

  const runs = pillText();
  if (!runs) return;
  let tw = 0;
  for (const r of runs) {
    ctx.font = r.font;
    r.w = ctx.measureText(r.text).width;
    tw += r.w;
  }
  const w = Math.min(W - 8, tw + 20), h = 22;
  const p = { x: (W - w) / 2, y: face.y - 12 - h };
  ctx.beginPath();
  ctx.roundRect(p.x, p.y, w, h, h / 2);
  ctx.fillStyle = "rgba(26,26,26,0.86)";
  ctx.fill();
  // A faint rim so it still reads on a dark wallpaper.
  ctx.beginPath();
  ctx.roundRect(p.x + 0.5, p.y + 0.5, w - 1, h - 1, (h - 1) / 2);
  ctx.strokeStyle = "rgba(255,255,255,0.16)";
  ctx.lineWidth = 1;
  ctx.stroke();
  ctx.save();
  ctx.beginPath();
  ctx.rect(p.x + 10, p.y, w - 20, h);
  ctx.clip();
  ctx.textBaseline = "middle";
  let x = p.x + 10;
  for (const r of runs) {
    ctx.font = r.font;
    ctx.fillStyle = r.color;
    ctx.fillText(r.text, x, p.y + h / 2 + 0.5);
    x += r.w;
  }
  ctx.restore();
}

// 24 frames a second, as on a Mac.
let lastFrame = 0;
function frame(ts) {
  if (ts - lastFrame >= 1000 / 24 - 1) {
    lastFrame = ts;
    draw();
  }
  requestAnimationFrame(frame);
}

// Click opens the panel; a drag of more than 2 px moves the pet.
let down = null;
canvas.addEventListener("mousedown", (e) => {
  if (e.button === 0) down = { x: e.screenX, y: e.screenY };
});
canvas.addEventListener("mousemove", (e) => {
  if (down && Math.abs(e.screenX - down.x) + Math.abs(e.screenY - down.y) > 2) {
    down = null;
    if (TAURI) TAURI.window.getCurrentWindow().startDragging();
  }
});
canvas.addEventListener("mouseup", (e) => {
  if (e.button === 0 && down) invoke("toggle_panel");
  down = null;
});
window.addEventListener("contextmenu", (e) => {
  e.preventDefault();
  invoke("pet_menu");
});

onAppEvent("hover", (on) => (hovering = on));
onAppEvent("flash", (text) => showFlash(text));
onAppEvent("reload", () => setTimeout(reload, 600));
onAppEvent("appearance", (a) => (appearanceChoice = a));

(async () => {
  await loadAppearance();
  await loadArt();
  await reload();
  setInterval(reload, 2000);
  requestAnimationFrame(frame);
})();
