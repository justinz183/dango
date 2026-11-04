//! ABTI 老板人格 and the report window (the 2026-10-31 handoff; thresholds
//! and words in assets/abti.json): the four dimensions and the type, the
//! money with its scale and margin tiers, the 团子 crew by role, the
//! check-up, the story's moments, and each report's numbers. All of it
//! comes from what Dango already keeps — minutes per job, $, tokens, model
//! cost, lines, tests, sub-agents, times; no prompt, code or path.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::OnceLock;

use chrono::{Datelike, Duration, NaiveDate, Timelike};
use rusqlite::Connection;
use serde_json::{json, Value};
use dango_core::occupation::Table;

use crate::config::Config;
use crate::ingest::{Result, Tz};
use crate::titles;
use crate::widget::work_of;

pub const CONFIG: &str = include_str!("../../../assets/abti.json");

pub fn config() -> &'static Value {
    static C: OnceLock<Value> = OnceLock::new();
    C.get_or_init(|| serde_json::from_str(CONFIG).expect("assets/abti.json"))
}

/// A finished turn, as ABTI needs it.
struct Turn {
    start: i64,
    end: i64,
    minutes: f64,
    work: BTreeMap<String, f64>,
    tokens: f64,
    lines_added: f64,
    lines_removed: f64,
    test_run: bool,
    test_first: Option<bool>,
    subagents: i64,
    /// Tool calls the AI made in the turn, and lines it wrote into new files.
    tools: i64,
    new_lines: f64,
    /// How long the AI kept at it: the gaps between the turn's events,
    /// leaving out any over ten minutes (a wait for the person, not work).
    active_ms: i64,
}

impl Turn {
    fn usd(&self) -> f64 {
        let t = Table::builtin();
        self.work.iter().map(|(o, m)| m / 60.0 * t.rate(o)).sum()
    }
}

fn turns(conn: &Connection, from: i64, to: i64) -> Result<Vec<Turn>> {
    let mut st = conn.prepare(
        "SELECT t.started_at, t.ended_at, t.human_minutes, t.work, t.tokens, t.lines_added, t.lines_removed, t.test_run,
                json_extract(t.agg, '$.test_first'), t.subagents,
                (SELECT COUNT(*) FROM events e WHERE e.session_id = t.session_id AND e.kind = 'tool' AND e.ts BETWEEN t.started_at AND t.ended_at),
                (SELECT COALESCE(SUM(json_extract(e.payload, '$.lines_added')), 0) FROM events e
                  WHERE e.session_id = t.session_id AND e.kind = 'tool' AND json_extract(e.payload, '$.tool') = 'write'
                    AND e.ts BETWEEN t.started_at AND t.ended_at),
                (SELECT COALESCE(SUM(CASE WHEN g <= 600000 THEN g ELSE 0 END), 0) FROM
                  (SELECT e.ts - LAG(e.ts) OVER (ORDER BY e.ts) AS g FROM events e
                    WHERE e.session_id = t.session_id AND e.ts BETWEEN t.started_at AND t.ended_at))
         FROM turns t WHERE t.ended_at IS NOT NULL AND t.ended_at >= ?1 AND t.ended_at < ?2 ORDER BY t.ended_at",
    )?;
    let rows = st.query_map([from, to], |r| {
        let tokens: String = r.get(4)?;
        Ok(Turn {
            start: r.get(0)?,
            end: r.get(1)?,
            minutes: r.get(2)?,
            work: work_of(&r.get::<_, String>(3)?),
            tokens: token_sum(&serde_json::from_str(&tokens).unwrap_or(Value::Null)),
            lines_added: r.get::<_, i64>(5)? as f64,
            lines_removed: r.get::<_, i64>(6)? as f64,
            test_run: r.get::<_, i64>(7)? != 0,
            test_first: r.get::<_, Option<i64>>(8)?.map(|v| v != 0),
            subagents: r.get(9)?,
            tools: r.get(10)?,
            new_lines: r.get::<_, f64>(11)?,
            active_ms: r.get(12)?,
        })
    })?;
    Ok(rows.flatten().collect())
}

/// Every count in a turn's tokens (caches included).
fn token_sum(v: &Value) -> f64 {
    match v {
        Value::Number(n) => n.as_f64().unwrap_or(0.0),
        Value::Object(m) => m.values().map(token_sum).sum(),
        _ => 0.0,
    }
}

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v[k].as_str().unwrap_or("")
}

/// A config entry's text in the language: `name_zh` / `name_en`.
fn txt(v: &Value, k: &str, en: bool) -> String {
    let want = format!("{k}_{}", if en { "en" } else { "zh" });
    v[&want].as_str().or_else(|| v[format!("{k}_zh")].as_str()).unwrap_or("").to_string()
}

/// Dollars per day ("YYYY-MM-DD" → $) from the day counters.
fn day_usd(conn: &Connection, metric: &str) -> Result<BTreeMap<String, f64>> {
    let mut st = conn.prepare("SELECT substr(scope, 5), value FROM counters WHERE metric = ?1 AND scope LIKE 'day:%'")?;
    let rows = st.query_map([metric], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))?;
    Ok(rows.flatten().collect())
}

fn counter(conn: &Connection, metric: &str, scope: &str) -> f64 {
    conn.query_row("SELECT value FROM counters WHERE metric = ?1 AND scope = ?2", [metric, scope], |r| r.get(0)).unwrap_or(0.0)
}

fn day_key(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

/// The longest run of days with output, and where it starts and ends.
fn streak(days: &BTreeMap<String, f64>, from: NaiveDate, to: NaiveDate) -> (i64, Option<NaiveDate>, Option<NaiveDate>) {
    let (mut best, mut run) = ((0i64, None, None), (0i64, None::<NaiveDate>));
    let mut d = from;
    while d <= to {
        if days.get(&day_key(d)).copied().unwrap_or(0.0) > 0.0 {
            run = (run.0 + 1, run.1.or(Some(d)));
            if run.0 > best.0 {
                best = (run.0, run.1, Some(d));
            }
        } else {
            run = (0, None);
        }
        d += Duration::days(1);
    }
    best
}

/// Heat levels for each day from `from` to `to` (today and earlier): 0 for
/// no output, else 1–4 by this person's own quartiles of their output days;
/// days after `today` are null.
fn heat(days: &BTreeMap<String, f64>, from: NaiveDate, to: NaiveDate, today: NaiveDate) -> Vec<Value> {
    let mut pos: Vec<f64> = days.values().copied().filter(|v| *v > 0.0).collect();
    pos.sort_by(|a, b| a.total_cmp(b));
    // The quarter of one's own output days this day falls in, by rank.
    let level = |v: f64| 1 + (4 * pos.partition_point(|x| *x < v) / pos.len().max(1)).min(3);
    let mut out = Vec::new();
    let mut d = from;
    while d <= to {
        let v = days.get(&day_key(d)).copied().unwrap_or(0.0);
        out.push(if d > today {
            Value::Null
        } else {
            json!(if v <= 0.0 { 0 } else { level(v) })
        });
        d += Duration::days(1);
    }
    out
}

/// The crew: each role's dollars, share and hours over `turns`, biggest
/// first. Hidden roles stand on their own only at 10% or more, else they
/// go into "other".
fn crew(turns: &[Turn], en: bool) -> Vec<Value> {
    let c = config();
    let t = Table::builtin();
    let mut usd: BTreeMap<String, f64> = BTreeMap::new();
    let mut mins: BTreeMap<String, f64> = BTreeMap::new();
    for tr in turns {
        for (o, m) in &tr.work {
            *usd.entry(o.clone()).or_default() += m / 60.0 * t.rate(o);
            *mins.entry(o.clone()).or_default() += m;
        }
    }
    let total: f64 = usd.values().sum();
    if total <= 0.0 {
        return Vec::new();
    }
    let sum = |occs: &Value| -> (f64, f64) {
        occs.as_array().into_iter().flatten().filter_map(Value::as_str).fold((0.0, 0.0), |a, o| {
            (a.0 + usd.get(o).copied().unwrap_or(0.0), a.1 + mins.get(o).copied().unwrap_or(0.0))
        })
    };
    let mut out: Vec<(f64, Value)> = Vec::new();
    let mut other = (0.0, 0.0);
    for r in c["roles"].as_array().into_iter().flatten() {
        let (u, m) = sum(&r["occupations"]);
        if u > 0.0 {
            out.push((u, json!({ "id": s(r, "id"), "name": txt(r, "name", en), "color": s(r, "color"), "text_on_color": s(r, "text_on_color"),
                                  "art": s(r, "art"), "usd": u, "share": u / total, "hours": m / 60.0, "hidden": false })));
        }
    }
    for r in c["hidden_roles"].as_array().into_iter().flatten() {
        let (u, m) = sum(&r["occupations"]);
        if u <= 0.0 {
            continue;
        }
        if u / total >= c["dimensions"]["range"]["role_share_min"].as_f64().unwrap_or(0.1) {
            let art = s(r, "art").rsplit('/').next().unwrap_or("").trim_end_matches(".png").to_string();
            out.push((u, json!({ "id": s(r, "id"), "name": txt(r, "name", en), "color": "#B5B5BA", "text_on_color": "#1C1C1C",
                                  "art": art, "usd": u, "share": u / total, "hours": m / 60.0, "hidden": true })));
        } else {
            other = (other.0 + u, other.1 + m);
        }
    }
    // Jobs in no role at all (none today) count as "other" too.
    let named: f64 = out.iter().map(|o| o.0).sum::<f64>() + other.0;
    if total - named > 0.005 {
        other.0 += total - named;
    }
    out.sort_by(|a, b| b.0.total_cmp(&a.0));
    let mut list: Vec<Value> = out.into_iter().map(|o| o.1).collect();
    if other.0 > 0.0 {
        list.push(json!({ "id": "other", "name": if en { "Other" } else { "其他" }, "color": "#B5B5BA", "text_on_color": "#1C1C1C",
                          "art": "", "usd": other.0, "share": other.0 / total, "hours": other.1 / 60.0, "hidden": true }));
    }
    list
}

fn tier<'a>(tiers: &'a Value, v: f64) -> Option<&'a Value> {
    tiers.as_array()?.iter().rev().find(|t| t[0].as_f64().is_some_and(|m| v >= m))
}

/// The local time of day as minutes after midnight, counting the small
/// hours as the end of the day before (for "latest").
fn lateness(tz: Tz, ms: i64) -> i64 {
    let t = tz.local(ms);
    let m = (t.hour() * 60 + t.minute()) as i64;
    if t.hour() < 6 { m + 24 * 60 } else { m }
}

fn hhmm(tz: Tz, ms: i64) -> String {
    tz.local(ms).format("%H:%M").to_string()
}

/// The boss type and everything on the card and in the story.
pub fn result(conn: &Connection, tz: Tz, cfg: &Config, now: i64) -> Result<Value> {
    let c = config();
    let en = cfg.lang().en();
    let all = turns(conn, 0, i64::MAX)?;
    let today = tz.date(now);
    let days = day_usd(conn, "usd")?;
    let first = all.first().map(|t| tz.date(t.start)).unwrap_or(today);
    let scan_days = (today - first).num_days() + 1;
    let sessions: i64 = conn.query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get(0)).unwrap_or(0);
    let d = &c["dimensions"];
    let n = all.len().max(1) as f64;

    // H / M: hands-off turns (≥ min_tool_calls tool calls, or sub-agents).
    let min_tools = d["hands_off"]["min_tool_calls"].as_i64().unwrap_or(8);
    let hands = all.iter().filter(|t| t.tools >= min_tools || t.subagents > 0).count() as f64 / n;
    // B / F: lines written into new files of all lines changed.
    let changed: f64 = all.iter().map(|t| t.lines_added + t.lines_removed).sum();
    let build = if changed > 0.0 { (all.iter().map(|t| t.new_lines).sum::<f64>() / changed).min(1.0) } else { 0.0 };
    // S / G: roles at 10% or more.
    let crew_all = crew(&all, en);
    let share_min = d["range"]["role_share_min"].as_f64().unwrap_or(0.1);
    let wide = crew_all.iter().filter(|r| r["id"] != "other" && r["share"].as_f64().unwrap_or(0.0) >= share_min).count() as i64;
    let min_roles = d["range"]["min_roles"].as_i64().unwrap_or(3);
    // L / O: minutes worked from night_start to night_end, local time.
    let (ns, ne) = (d["hours"]["night_start"].as_u64().unwrap_or(20) as u32, d["hours"]["night_end"].as_u64().unwrap_or(8) as u32);
    let mins: f64 = all.iter().map(|t| t.minutes).sum();
    let night_m: f64 = all.iter().filter(|t| { let h = tz.local(t.start).hour(); h >= ns || h < ne }).map(|t| t.minutes).sum();
    let night = if mins > 0.0 { night_m / mins } else { 0.0 };

    let (lo, hi) = (d["tie_band"]["min"].as_f64().unwrap_or(0.45), d["tie_band"]["max"].as_f64().unwrap_or(0.55));
    let dim = |id: &str, ratio: f64| -> (String, Value) {
        let x = &d[id];
        let first = ratio > x["threshold"].as_f64().unwrap_or(0.5);
        let letter = x["letters"][if first { 0 } else { 1 }].as_str().unwrap_or("").to_string();
        let pct = if first { ratio } else { 1.0 - ratio };
        let names: Vec<String> = (0..2).map(|i| x[if en { "name_en" } else { "name_zh" }][i].as_str().unwrap_or("").to_string()).collect();
        (letter.clone(), json!({ "id": id, "letters": x["letters"], "names": names, "letter": letter, "winner": if first { 0 } else { 1 },
                                 "pct": pct, "tie": pct >= lo && pct <= hi }))
    };
    let (h, dh) = dim("hands_off", hands);
    let (b, db) = dim("build", build);
    let (o, dho) = dim("hours", night);
    let g = wide >= min_roles;
    let r_letter = d["range"]["letters"][if g { 1 } else { 0 }].as_str().unwrap_or("S").to_string();
    let dr = json!({ "id": "range", "letters": d["range"]["letters"], "names": (0..2).map(|i| d["range"][if en { "name_en" } else { "name_zh" }][i].clone()).collect::<Vec<_>>(),
                     "letter": r_letter, "winner": if g { 1 } else { 0 }, "roles": wide, "min_roles": min_roles, "cells": 8 });
    let code = format!("{h}{b}{r_letter}{o}");
    let ty = &c["types"][&code];
    let mcode = s(ty, "match").to_string();
    let mt = &c["types"][&mcode];

    // Money, scale, margin.
    let usd = counter(conn, "usd", "all");
    let cost = counter(conn, "cost", "all");
    let margin = if usd > 0.0 { 1.0 - cost / usd } else { 0.0 };
    let scales = c["scale_tiers"].as_array().cloned().unwrap_or_default();
    let si = scales.iter().rposition(|t| t["min_usd"].as_f64().is_some_and(|m| usd >= m)).unwrap_or(0);
    let next = scales.get(si + 1);
    let margins = c["margin_tiers"].as_array().cloned().unwrap_or_default();
    let mi = margins.iter().position(|t| t["min"].as_f64().is_some_and(|m| margin >= m)).unwrap_or(margins.len().saturating_sub(1));

    // The check-up.
    let ck = &c["checkup"];
    let runs: Vec<&Turn> = all.iter().filter(|t| t.test_run).collect();
    let first_pass = if runs.is_empty() { 0.0 } else { runs.iter().filter(|t| t.test_first == Some(true)).count() as f64 / runs.len() as f64 };
    let small_hours = all.iter().filter(|t| tz.local(t.start).hour() < 5).count() as f64 / n;
    let (streak_days, streak_from, streak_to) = streak(&days, first, today);
    let tokens: f64 = all.iter().map(|t| t.tokens).sum();
    let lines: f64 = all.iter().map(|t| t.lines_added).sum();
    let max_sub = all.iter().map(|t| t.subagents).max().unwrap_or(0);
    let item = |id: &str, v: f64, shown: String| -> Value {
        let x = &ck[id];
        let too_few = id == "first_try_pass" && (runs.len() as i64) < x["min_runs"].as_i64().unwrap_or(20);
        let (label, color) = if too_few {
            (txt(x, "too_few", en), Value::Null)
        } else {
            tier(&x["tiers"], v).map(|t| (t[if en { 2 } else { 1 }].as_str().unwrap_or("").to_string(), t.get(3).cloned().unwrap_or(Value::Null))).unwrap_or_default()
        };
        json!({ "id": id, "label": txt(x, "label", en), "value": v, "shown": shown, "tier": label, "tier_color": color, "too_few": too_few })
    };
    let tokens = tidy(tokens);
    let checkup = vec![
        item("tokens_total", tokens, compact(tokens, en)),
        item("lines_added", lines, compact(lines, en)),
        item("first_try_pass", first_pass, format!("{:.0}%", first_pass * 100.0)),
        item("night_shift", small_hours, format!("{:.0}%", small_hours * 100.0)),
        item("longest_streak", streak_days as f64, if en { format!("{streak_days} days") } else { format!("{streak_days} 天") }),
        item("max_subagents", max_sub as f64, if en { format!("{max_sub}") } else { format!("{max_sub} 个") }),
    ];

    // The story's moments.
    let latest = all.iter().filter(|t| tz.local(t.end).hour() < 6).max_by_key(|t| lateness(tz, t.end)).or_else(|| all.iter().max_by_key(|t| lateness(tz, t.end)));
    let best = days.iter().max_by(|a, b| a.1.total_cmp(b.1)).map(|(k, v)| (k.clone(), *v));
    let best_hours: f64 = best.as_ref().map(|(k, _)| all.iter().filter(|t| day_key(tz.date(t.end)) == *k).map(|t| t.minutes).sum::<f64>() / 60.0).unwrap_or(0.0);
    let longest = all.iter().filter(|t| t.active_ms > 0).max_by_key(|t| t.active_ms);

    // The story's words.
    let st = &c["story"];
    let advice: Vec<String> = {
        let pct = |v: f64| format!("{:.0}", v * 100.0);
        let mut out = Vec::new();
        for a in st["advice"]["items"].as_array().into_iter().flatten() {
            let w = s(a, "when");
            let hit = match w {
                _ if w.starts_with("night_shift") => small_hours > 0.15,
                _ if w.starts_with("first_try_pass < 0.6") => runs.len() >= 20 && first_pass < 0.6,
                _ if w.starts_with("max_subagents") => max_sub >= 5,
                _ if w.starts_with("longest_streak") => streak_days >= 30,
                _ if w.starts_with("margin") => margin >= 0.95,
                _ if w.starts_with("first_try_pass >= 0.8") => runs.len() >= 20 && first_pass >= 0.8,
                _ => false,
            };
            if hit && out.len() < 3 {
                out.push(s(a, if en { "en" } else { "zh" }).replace("{night_shift}", &pct(small_hours)).replace("{first_try_pass}", &pct(first_pass))
                    .replace("{max_subagents}", &max_sub.to_string()).replace("{longest_streak}", &streak_days.to_string()).replace("{margin}", &format!("{:.1}", margin * 100.0)));
            }
        }
        if out.is_empty() {
            out.push(s(&st["advice"], if en { "fallback_en" } else { "fallback" }).to_string());
        }
        out
    };
    let verdict = if small_hours > 0.15 { "night" } else if runs.len() >= 20 && first_pass < 0.6 { "tests" } else { "fine" };
    let rel = &st[if en { "relations_en" } else { "relations" }];
    let relations = vec![
        s(rel, "H<>M").to_string(),
        s(rel, "B<>F").to_string(),
        s(rel, if g { "G=G" } else { "S=S" }).to_string(),
        s(rel, if o == "O" { "O=O" } else { "L=L" }).to_string(),
    ];

    Ok(json!({
        "lang": cfg.lang().code(),
        "date": day_key(today),
        "since": day_key(first),
        "scan_days": scan_days,
        "sessions": sessions,
        "turns": all.len(),
        "code": code,
        "type": { "code": code, "name": txt(ty, "name", en), "roast": txt(ty, "roast", en), "portrait": txt(ty, "portrait", en) },
        "dims": [dh, db, dr, dho],
        "usd": usd, "cost": cost, "leverage": if cost > 0.0 { Some(usd / cost) } else { None }, "margin": margin,
        "scale": { "id": s(&scales[si], "id"), "index": si, "name": txt(&scales[si], "name", en), "line": txt(&scales[si], "line", en),
                   "next": next.map(|x| txt(x, "name", en)), "next_need": next.and_then(|x| x["min_usd"].as_f64()).map(|m| m - usd) },
        "margin_tier": { "index": mi, "name": margins.get(mi).map(|x| txt(x, "name", en)), "line": margins.get(mi).map(|x| txt(x, "line", en)) },
        "crew": crew_all,
        "checkup": checkup,
        "cost_row": cost,
        "match": { "code": mcode, "name": txt(mt, "name", en), "line": txt(ty, "match_line", en) },
        "moments": {
            "latest_night": latest.map(|t| json!({ "time": hhmm(tz, t.end), "date": day_key(tz.date(t.end)) })),
            "best_day": best.clone().map(|(k, v)| json!({ "date": k, "usd": v, "hours": best_hours })),
            "longest_streak": { "days": streak_days, "from": streak_from.map(day_key), "to": streak_to.map(day_key) },
            "longest_turn": longest.map(|t| json!({ "minutes": t.active_ms as f64 / 60_000.0, "date": day_key(tz.date(t.end)) })),
        },
        "heat": heat(&days, first, today, today),
        "best_day": best.as_ref().map(|b| b.0.clone()),
        "story": {
            "advice": advice,
            "verdict": s(&st[if en { "verdict_en" } else { "verdict" }], verdict),
            "relations": relations,
            "guess_lines": st[if en { "guess_lines_en" } else { "guess_lines" }],
            // Only the numbers: the config's notes beside them are for people.
            "timing": st["timing"].as_object().map(|m| m.iter().filter(|(_, v)| v.is_number()).map(|(k, v)| (k.clone(), v.clone())).collect::<serde_json::Map<_, _>>()),
        },
    }))
}

/// 12,840,000,000 → 128.4 亿 / 12.8B; 216,000 → 21.6 万 / 216K.
fn compact(v: f64, en: bool) -> String {
    if en {
        match v {
            _ if v >= 1e9 => format!("{:.1}B", v / 1e9),
            _ if v >= 1e6 => format!("{:.1}M", v / 1e6),
            _ if v >= 1e3 => format!("{:.0}K", v / 1e3),
            _ => format!("{v:.0}"),
        }
    } else {
        match v {
            _ if v >= 1e8 => format!("{:.1} 亿", v / 1e8),
            _ if v >= 1e4 => format!("{:.1} 万", v / 1e4),
            _ => format!("{v:.0}"),
        }
    }
}

fn midnight(tz: Tz, d: NaiveDate) -> i64 {
    tz.ms(d.and_hms_opt(0, 0, 0).unwrap())
}

fn sum_days(days: &BTreeMap<String, f64>, from: NaiveDate, to: NaiveDate) -> f64 {
    let (a, b) = (day_key(from), day_key(to));
    days.range(a..=b).map(|(_, v)| *v).sum()
}

/// A sum of day values as shown: a counter's float dust (−0.0, 1e-13)
/// reads as zero.
fn tidy(x: f64) -> f64 {
    if x.abs() < 0.005 { 0.0 } else { x }
}

/// What got done in a period, for the report window only (never on share
/// images): the top sessions by $, with the title and folder the session
/// has on this Mac, and the same $ summed by project.
fn named_work(conn: &Connection, claude_dir: &Path, from: i64, to: i64, en: bool) -> Result<(Vec<Value>, Vec<Value>)> {
    let mut st = conn.prepare(
        "SELECT t.session_id, s.source, s.ended_at, SUM(t.usd), SUM(t.human_minutes), COUNT(*), MAX(t.ended_at)
         FROM turns t JOIN sessions s ON s.id = t.session_id
         WHERE t.ended_at IS NOT NULL AND t.ended_at >= ?1 AND t.ended_at < ?2
         GROUP BY t.session_id HAVING SUM(t.usd) > 0 ORDER BY SUM(t.usd) DESC",
    )?;
    let rows: Vec<(String, String, Option<i64>, f64, f64, i64, i64)> =
        st.query_map([from, to], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)))?.flatten().collect();
    let tool = |src: &str| if src == "codex" { "Codex" } else { "Claude Code" };
    let mut sessions = Vec::new();
    let mut projects: Vec<(String, f64, f64, usize)> = Vec::new();
    for (k, (sid, src, ended, usd, minutes, turns, last)) in rows.iter().enumerate() {
        let meta = titles::cached(conn, claude_dir, sid, ended.is_some())?;
        if k < 5 {
            sessions.push(json!({ "title": meta.title, "project": meta.project, "tool": tool(src), "usd": usd, "minutes": minutes,
                                  "turns": turns, "last": last }));
        }
        let name = meta.project.clone().unwrap_or_else(|| if en { "No project folder".into() } else { "不在项目文件夹里".into() });
        match projects.iter_mut().find(|p| p.0 == name) {
            Some(p) => { p.1 += usd; p.2 += minutes; p.3 += 1; }
            None => projects.push((name, *usd, *minutes, 1)),
        }
    }
    projects.sort_by(|a, b| b.1.total_cmp(&a.1));
    let projects = projects.into_iter().take(5).map(|(n, u, m, c)| json!({ "project": n, "usd": u, "minutes": m, "sessions": c })).collect();
    Ok((sessions, projects))
}

/// One report (日报 / 周报 / 月报 / 年报 / 总计) for the period holding `date`.
pub fn report(conn: &Connection, tz: Tz, cfg: &Config, claude_dir: &Path, kind: &str, date: NaiveDate, now: i64) -> Result<Value> {
    let en = cfg.lang().en();
    let today = tz.date(now);
    let usd_days = day_usd(conn, "usd")?;
    let cost_days = day_usd(conn, "cost")?;
    let (from, to) = match kind {
        "week" => {
            let mon = date - Duration::days(date.weekday().num_days_from_monday() as i64);
            (mon, mon + Duration::days(6))
        }
        "month" => {
            let first = date.with_day(1).unwrap();
            let next = if first.month() == 12 { NaiveDate::from_ymd_opt(first.year() + 1, 1, 1) } else { NaiveDate::from_ymd_opt(first.year(), first.month() + 1, 1) }.unwrap();
            (first, next - Duration::days(1))
        }
        "year" => (NaiveDate::from_ymd_opt(date.year(), 1, 1).unwrap(), NaiveDate::from_ymd_opt(date.year(), 12, 31).unwrap()),
        "total" => {
            let first: Option<i64> = conn.query_row("SELECT MIN(started_at) FROM turns", [], |r| r.get(0)).unwrap_or(None);
            (first.map(|f| tz.date(f)).unwrap_or(today), today)
        }
        _ => (date, date),
    };
    let ts = turns(conn, midnight(tz, from), midnight(tz, to + Duration::days(1)))?;
    let usd = tidy(sum_days(&usd_days, from, to));
    let cost = tidy(sum_days(&cost_days, from, to));
    let span = (to - from).num_days() + 1;
    let prev_from = match kind {
        "month" => from - Duration::days(from.pred_opt().unwrap().day() as i64),
        "year" => NaiveDate::from_ymd_opt(from.year() - 1, 1, 1).unwrap(),
        _ => from - Duration::days(span),
    };
    let prev = tidy(sum_days(&usd_days, prev_from, from - Duration::days(1)));
    let (sessions, projects) = named_work(conn, claude_dir, midnight(tz, from), midnight(tz, to + Duration::days(1)), en)?;
    let best_any = usd_days.values().copied().fold(0.0, f64::max);
    let daily = |a: NaiveDate, b: NaiveDate| -> Vec<Value> {
        let mut out = Vec::new();
        let mut d = a;
        while d <= b {
            out.push(if d > today { Value::Null } else { json!(tidy(usd_days.get(&day_key(d)).copied().unwrap_or(0.0))) });
            d += Duration::days(1);
        }
        out
    };
    let best_in = |a: NaiveDate, b: NaiveDate| -> Option<(String, f64)> {
        usd_days.range(day_key(a)..=day_key(b)).filter(|(_, v)| **v > 0.0).max_by(|x, y| x.1.total_cmp(y.1)).map(|(k, v)| (k.clone(), *v))
    };
    let active = usd_days.range(day_key(from)..=day_key(to)).filter(|(_, v)| **v > 0.0).count();
    let latest_end = ts.iter().max_by_key(|t| lateness(tz, t.end)).map(|t| hhmm(tz, t.end));
    let mut out = json!({
        "lang": cfg.lang().code(),
        "kind": kind,
        "date": day_key(date),
        "from": day_key(from),
        "to": day_key(to),
        "today": day_key(today),
        "usd": usd,
        "cost": cost,
        "leverage": if cost > 0.0 { Some(usd / cost) } else { None },
        "vs_prev": if prev > 0.0 { Some(usd / prev - 1.0) } else { None },
        "crew": crew(&ts, en),
        "sessions": sessions,
        "projects": projects,
    });
    match kind {
        "day" => {
            let mut hours = [0.0f64; 24];
            for t in &ts {
                hours[tz.local(t.end).hour() as usize] += t.usd();
            }
            let busiest = hours.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).filter(|h| *h.1 > 0.0).map(|h| h.0);
            out["hourly"] = json!(hours);
            out["is_record"] = json!(usd > 0.0 && usd + 1e-9 >= best_any);
            out["highlights"] = json!({
                "longest_turn_min": ts.iter().map(|t| t.active_ms as f64 / 60_000.0).fold(0.0, f64::max),
                "busiest_hour": busiest,
                "last_end": ts.iter().map(|t| t.end).max().map(|e| hhmm(tz, e)),
            });
        }
        "week" => {
            out["daily"] = json!(daily(from, to));
            out["elapsed"] = json!(if today >= from && today <= to { (today - from).num_days() + 1 } else { 7 });
            out["highlights"] = json!({ "best_day": best_in(from, to).map(|b| b.0), "active_days": active, "latest_end": latest_end });
        }
        "month" => {
            out["daily"] = json!(daily(from, to));
            out["first_weekday"] = json!(from.weekday().num_days_from_monday());
            out["elapsed"] = json!(if today >= from && today <= to { (today - from).num_days() + 1 } else { span });
            out["highlights"] = json!({ "best_day": best_in(from, to).map(|b| b.0), "active_days": active, "longest_streak": streak(&usd_days, from, to.min(today)).0 });
        }
        "year" => {
            let mut months = [0.0f64; 12];
            for (k, v) in usd_days.range(day_key(from)..=day_key(to)) {
                months[k[5..7].parse::<usize>().unwrap_or(1) - 1] += v;
            }
            let monthly: Vec<Value> = (0..12)
                .map(|m| if from.year() > today.year() || (from.year() == today.year() && m + 1 > today.month() as usize) { Value::Null } else { json!(tidy(months[m])) })
                .collect();
            let best_month = (0..12).filter(|m| months[*m] > 0.005).max_by(|a, b| months[*a].total_cmp(&months[*b]))
                .map(|m| json!({ "month": format!("{}-{:02}", from.year(), m + 1), "usd": months[m] }));
            out["monthly"] = json!(monthly);
            out["elapsed"] = json!(if from.year() == today.year() { today.month() as i64 } else { 12 });
            out["highlights"] = json!({ "best_month": best_month, "active_days": active, "longest_streak": streak(&usd_days, from, to.min(today)).0 });
        }
        _ => {
            let mut months: BTreeMap<String, f64> = BTreeMap::new();
            for (k, v) in usd_days.range(day_key(from)..=day_key(to)) {
                *months.entry(k[..7].to_string()).or_default() += v;
            }
            let r = result(conn, tz, cfg, now)?;
            let (st, _, _) = streak(&usd_days, from, to);
            out["since"] = json!(day_key(from));
            out["days"] = json!(span);
            out["active_days"] = json!(active);
            out["longest_streak"] = json!(st);
            out["best_day"] = json!(best_in(from, to).map(|b| json!({ "date": b.0, "usd": b.1 })));
            out["monthly"] = json!(months.into_iter().map(|(k, v)| json!([k, v])).collect::<Vec<_>>());
            out["heat"] = json!(heat(&usd_days, from, to, today));
            out["first_weekday"] = json!(from.weekday().num_days_from_monday());
            out["boss"] = json!({ "code": r["code"], "name": r["type"]["name"], "roast": r["type"]["roast"], "scale": r["scale"]["name"],
                                  "margin": r["margin"], "margin_tier": r["margin_tier"]["name"] });
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_has_every_type_and_its_match() {
        let c = config();
        let types = c["types"].as_object().unwrap();
        assert_eq!(types.len(), 16);
        for (code, t) in types {
            let m = t["match"].as_str().unwrap();
            // The match flips the first two letters and keeps the last two.
            let flip = |x: char| match x { 'H' => 'M', 'M' => 'H', 'B' => 'F', 'F' => 'B', o => o };
            let want: String = code.chars().enumerate().map(|(i, x)| if i < 2 { flip(x) } else { x }).collect();
            assert_eq!(m, want, "{code}");
            assert_eq!(types[m]["match"].as_str().unwrap(), code.as_str());
        }
        let jobs: Vec<&str> = c["roles"].as_array().unwrap().iter().chain(c["hidden_roles"].as_array().unwrap())
            .flat_map(|r| r["occupations"].as_array().unwrap().iter().map(|o| o.as_str().unwrap())).collect();
        let t = Table::builtin();
        for o in &t.occupation {
            assert!(jobs.contains(&o.id.as_str()), "{} has no role", o.id);
        }
    }

    #[test]
    fn heat_uses_ones_own_quartiles() {
        let d = |s: &str| NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
        let days: BTreeMap<String, f64> = [("2026-10-01", 1.0), ("2026-10-02", 2.0), ("2026-10-04", 3.0), ("2026-10-05", 40.0)].iter().map(|(k, v)| (k.to_string(), *v)).collect();
        let h = heat(&days, d("2026-10-01"), d("2026-10-07"), d("2026-10-05"));
        assert_eq!(h, vec![json!(1), json!(2), json!(0), json!(3), json!(4), Value::Null, Value::Null]);
        assert_eq!(streak(&days, d("2026-10-01"), d("2026-10-07")).0, 2);
    }
}
