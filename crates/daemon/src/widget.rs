//! ~/.shadowcorp/widget.json: the state the desktop widget shows — the
//! headline dollars and rank for the collapsed panel, the character's live
//! mood and line, and the history the expanded dashboard draws. Rewritten
//! by the daemon after new activity.

use std::collections::{BTreeMap, HashMap};
use std::fs;

use chrono::{Datelike, Duration, Timelike};
use rusqlite::{Connection, OptionalExtension};
use serde_json::{json, Value};
use shadowcorp_core::occupation::{self, Table};
use shadowcorp_core::rank::RANKS;
use shadowcorp_core::render::{fmt_hours, fmt_usd};
use shadowcorp_core::scoring::ScoringConstants;

use crate::config::Config;
use crate::ingest::{day_key, Result, Tz};
use crate::paths::{write_private, Paths};
use crate::snapshot::{self, Output};

const MIN_MS: i64 = 60_000;
const DAY_MS: i64 = 86_400_000;
pub const HISTORY_DAYS: i64 = 30;

/// A turn's credited minutes per occupation (turns.work).
pub fn work_of(json: &str) -> BTreeMap<String, f64> {
    serde_json::from_str(json).unwrap_or_default()
}

/// Display name and colour of an agent (sessions.source).
pub fn tool_label(source: &str) -> (&'static str, &'static str) {
    match source {
        "codex" => ("Codex", "#5b6b7a"),
        _ => ("Claude Code", "#d97757"),
    }
}

/// Claude Code and Codex side by side for turns that ended in [from, to):
/// dollars, hours, turns and share of the dollars, biggest first.
pub fn tools(conn: &Connection, from: i64, to: i64) -> Result<Vec<Value>> {
    let k = ScoringConstants::builtin();
    let mut st = conn.prepare(
        "SELECT s.source, SUM(t.usd), SUM(t.credited_pd), COUNT(*) FROM turns t JOIN sessions s ON s.id = t.session_id
         WHERE t.ended_at >= ?1 AND t.ended_at < ?2 GROUP BY s.source ORDER BY SUM(t.usd) DESC",
    )?;
    let rows: Vec<(String, f64, f64, i64)> =
        st.query_map([from, to], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?.flatten().collect();
    let total: f64 = rows.iter().map(|r| r.1).sum();
    Ok(rows
        .into_iter()
        .map(|(src, usd, pd, n)| {
            let (name, color) = tool_label(&src);
            json!({ "id": src, "name": name, "color": color, "usd": usd, "hours": pd * k.caps.minutes_per_day / 60.0, "turns": n,
                    "share": if total > 0.0 { usd / total } else { 0.0 } })
        })
        .collect())
}

/// Dollars per day from the `usd` counters, for days on or after `from`.
pub fn usd_by_day(conn: &Connection, from: chrono::NaiveDate) -> Result<HashMap<String, f64>> {
    let mut st = conn.prepare("SELECT substr(scope, 5), value FROM counters WHERE metric = 'usd' AND scope LIKE 'day:%' AND scope >= ?1")?;
    let rows = st.query_map([format!("day:{}", day_key(from))], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))?;
    Ok(rows.flatten().collect())
}

/// Who did the work of turns that ended in [from, to): one entry per
/// occupation with hours, dollars and share of the dollars, biggest first.
pub fn jobs(conn: &Connection, from: i64, to: i64) -> Result<Vec<Value>> {
    let t = Table::builtin();
    let mut st = conn.prepare(
        "SELECT j.key, SUM(j.value) FROM turns, json_each(turns.work) j
         WHERE turns.ended_at >= ?1 AND turns.ended_at < ?2 GROUP BY j.key",
    )?;
    let mut rows: Vec<(String, f64, f64)> = st
        .query_map([from, to], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))?
        .flatten()
        .filter(|(_, m)| *m > 0.0)
        .map(|(o, m)| {
            let usd = m / 60.0 * t.rate(&o);
            (o, m, usd)
        })
        .collect();
    rows.sort_by(|a, b| b.2.total_cmp(&a.2));
    let total: f64 = rows.iter().map(|r| r.2).sum();
    Ok(rows
        .into_iter()
        .map(|(o, m, usd)| {
            let job = t.get(&o);
            json!({
                "id": o, "name": t.name(&o), "name_en": job.map(|j| j.name_en.as_str()), "color": job.map(|j| j.color.as_str()),
                "rate": t.rate(&o), "hours": m / 60.0, "usd": usd, "share": if total > 0.0 { usd / total } else { 0.0 },
            })
        })
        .collect())
}

/// The character's mood and line right now (DESIGN.md §2), from what the
/// agent is doing, how long it has been quiet and what just happened.
pub fn character(conn: &Connection, tz: Tz, cfg: &Config, o: &Output, now: i64, working: i64, subagents: i64, last_event: Option<i64>) -> Result<Value> {
    let since = last_event.map(|t| now - t).unwrap_or(i64::MAX);
    let rank_up: Option<String> = conn
        .query_row(
            "SELECT ref FROM ceremonies WHERE kind = 'rank_up' AND created_at >= ?1 ORDER BY created_at DESC LIMIT 1",
            [now - 10 * MIN_MS],
            |r| r.get(0),
        )
        .optional()?;
    let last: Option<(String, f64, i64, i64, Option<i64>, f64)> = conn
        .query_row(
            "SELECT work, credited_pd, ended_at, test_run, test_passed, usd FROM turns WHERE ended_at IS NOT NULL ORDER BY ended_at DESC LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
        )
        .optional()?;
    let k = ScoringConstants::builtin();
    let hour = tz.local(now).hour();
    let (mood, line) = if let Some(label) = rank_up {
        ("proud", format!("晋级了，{label}。"))
    } else if working > 0 && since < 20 * MIN_MS {
        if hour < 5 {
            ("sleepy", "这么晚了，还在干。".to_string())
        } else if subagents > 0 {
            ("focused", format!("带着 {subagents} 个帮手在干。"))
        } else {
            ("focused", "在做了，别催。".to_string())
        }
    } else if since > 14 * DAY_MS && last_event.is_some() {
        ("missing", "欢迎回来，灯一直亮着。".to_string())
    } else if since > 60 * MIN_MS {
        ("waiting", "我在，随时开工。".to_string())
    } else if o.today_hours >= 16.0 {
        ("proud", "今天顶一个人干两天。".to_string())
    } else if let Some((work, pd, _, test_run, passed, usd)) = last.filter(|l| now - l.2 < 30 * MIN_MS) {
        if test_run == 1 && passed == Some(1) {
            ("happy", "这把测试全绿。".to_string())
        } else {
            let job = occupation::main(&work_of(&work)).map(|o| Table::builtin().name(&o).to_string()).unwrap_or_default();
            ("happy", format!("刚干了 {} 的{}活，值 {}。", fmt_hours(pd * k.caps.minutes_per_day / 60.0), job, fmt_usd(usd)))
        }
    } else if o.today_usd > 0.0 {
        ("happy", format!("今天干了 {} 的活。", fmt_usd(o.today_usd)))
    } else {
        ("waiting", "我在，随时开工。".to_string())
    };
    Ok(json!({ "name": cfg.character.name, "mood": mood, "line": line }))
}

pub fn data(conn: &Connection, tz: Tz, cfg: &Config, now: i64) -> Result<Value> {
    let o = snapshot::output(conn, tz, now);
    let (working, subagents, last_event) = snapshot::activity(conn, now)?;
    let k = ScoringConstants::builtin();
    let t = Table::builtin();
    let hours = |pd: f64| pd * k.caps.minutes_per_day / 60.0;
    let today = tz.date(now);

    let month_start = today.with_day(1).unwrap_or(today);
    let month_pd: f64 = conn.query_row(
        "SELECT COALESCE(SUM(person_days), 0) FROM daily WHERE day >= ?1",
        [day_key(month_start)],
        |r| r.get(0),
    )?;
    let month_usd: f64 = usd_by_day(conn, month_start)?.values().sum();

    let from = today - Duration::days(HISTORY_DAYS - 1);
    let usd_days = usd_by_day(conn, from)?;
    let mut by_day: HashMap<String, (f64, i64)> = HashMap::new();
    let mut st = conn.prepare("SELECT day, person_days, turns FROM daily WHERE day >= ?1")?;
    for (d, pd, t) in st.query_map([day_key(from)], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?, r.get::<_, i64>(2)?)))?.flatten() {
        by_day.insert(d, (pd, t));
    }
    let days: Vec<Value> = (0..HISTORY_DAYS)
        .map(|i| {
            let key = day_key(from + Duration::days(i));
            let (pd, turns) = by_day.get(&key).copied().unwrap_or((0.0, 0));
            let usd = usd_days.get(&key).copied().unwrap_or(0.0);
            json!({ "day": key, "hours": hours(pd), "usd": usd, "person_days": pd, "turns": turns })
        })
        .collect();

    let mut st = conn.prepare(
        "SELECT t.ended_at, t.work, t.credited_pd, t.files_touched, t.test_run, t.test_passed, t.usd, s.source FROM turns t
         JOIN sessions s ON s.id = t.session_id WHERE t.ended_at IS NOT NULL ORDER BY t.ended_at DESC LIMIT 10",
    )?;
    let turns: Vec<Value> = st
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, f64>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, i64>(4)?,
                r.get::<_, Option<i64>>(5)?,
                r.get::<_, f64>(6)?,
                r.get::<_, String>(7)?,
            ))
        })?
        .flatten()
        .map(|(at, work, pd, files, test_run, passed, usd, src)| {
            let job = occupation::main(&work_of(&work)).unwrap_or_default();
            json!({
                "at": at, "tool": tool_label(&src).0, "job": job, "name": t.name(&job), "color": t.get(&job).map(|j| j.color.as_str()), "hours": hours(pd),
                "usd": usd, "person_days": pd, "files": files, "test_passed": (test_run == 1).then(|| passed == Some(1)),
            })
        })
        .collect();

    let r = &o.rank;
    Ok(json!({
        "generated_at": now,
        "rates": { "source": t.source, "label": t.label, "as_of": t.as_of },
        "character": character(conn, tz, cfg, &o, now, working, subagents, last_event)?,
        "total": { "hours": o.total_hours, "usd": o.total_usd, "person_days": o.total_pd, "xp": r.xp },
        "today": { "hours": o.today_hours, "usd": o.today_usd, "person_days": o.today_pd },
        "week": { "hours": o.week_hours, "usd": o.week_usd, "person_days": o.week_pd, "leverage": o.week_leverage },
        "month": { "hours": hours(month_pd), "usd": month_usd, "person_days": month_pd },
        "rank": {
            "index": r.index,
            "name": r.rank().name,
            "name_en": r.rank().name_en,
            "division": r.division,
            "label": r.label(),
            "label_en": r.label_en(),
            "color": r.rank().color,
            "progress": r.progress,
            "xp_to_next": r.xp_to_next(),
            "next_label": r.next_label(),
        },
        "ranks": RANKS.iter().map(|x| json!({ "name": x.name, "name_en": x.name_en, "xp": x.xp, "color": x.color })).collect::<Vec<_>>(),
        "days": days,
        "jobs": jobs(conn, now - HISTORY_DAYS * DAY_MS, i64::MAX)?,
        "tools": tools(conn, now - HISTORY_DAYS * DAY_MS, i64::MAX)?,
        "tools_all": tools(conn, 0, i64::MAX)?,
        "turns": turns,
        "activity": { "working": working, "subagents": subagents, "last_event": last_event },
    }))
}

/// Writes widget.json through a temp file and a rename so the widget never
/// reads half a file.
pub fn write(paths: &Paths, conn: &Connection, tz: Tz, cfg: &Config, now: i64) -> Result<()> {
    let body = serde_json::to_string(&data(conn, tz, cfg, now)?)?;
    let tmp = paths.home.join("widget.json.tmp");
    write_private(&tmp, body.as_bytes())?;
    fs::rename(&tmp, paths.home.join("widget.json"))?;
    Ok(())
}
