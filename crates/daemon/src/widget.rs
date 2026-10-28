//! ~/.shadowcorp/widget.json: the state the desktop widget shows — the
//! headline hours and rank for the collapsed panel, the character's live
//! mood and line, and the history the expanded dashboard draws. Rewritten
//! by the daemon after new activity.

use std::collections::HashMap;
use std::fs;

use chrono::{Datelike, Duration, Timelike};
use rusqlite::{Connection, OptionalExtension};
use serde_json::{json, Value};
use shadowcorp_core::event::TaskClass;
use shadowcorp_core::rank::RANKS;
use shadowcorp_core::render::fmt_hours;
use shadowcorp_core::scoring::{value_usd, ScoringConstants};
use shadowcorp_core::value::Category;

use crate::config::Config;
use crate::ingest::{day_key, Result, Tz};
use crate::paths::{write_private, Paths};
use crate::snapshot::{self, Output};

const MIN_MS: i64 = 60_000;
const DAY_MS: i64 = 86_400_000;
pub const HISTORY_DAYS: i64 = 30;

fn class_name(c: &str) -> &'static str {
    TaskClass::parse(c).map(|c| c.name_zh()).unwrap_or("杂项")
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
    let last: Option<(String, f64, i64, i64, Option<i64>)> = conn
        .query_row(
            "SELECT task_class, credited_pd, ended_at, test_run, test_passed FROM turns WHERE ended_at IS NOT NULL ORDER BY ended_at DESC LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
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
    } else if let Some((class, pd, at, test_run, passed)) = last.filter(|l| now - l.2 < 30 * MIN_MS) {
        let _ = at;
        if test_run == 1 && passed == Some(1) {
            ("happy", "这把测试全绿。".to_string())
        } else {
            ("happy", format!("刚干完一段{}，{}。", class_name(&class), fmt_hours(pd * k.caps.minutes_per_day / 60.0)))
        }
    } else if o.today_hours > 0.0 {
        ("happy", format!("今天 {} 了。", fmt_hours(o.today_hours)))
    } else {
        ("waiting", "我在，随时开工。".to_string())
    };
    Ok(json!({ "name": cfg.character.name, "mood": mood, "line": line }))
}

pub fn data(conn: &Connection, tz: Tz, cfg: &Config, now: i64) -> Result<Value> {
    let o = snapshot::output(conn, tz, cfg, now);
    let (working, subagents, last_event) = snapshot::activity(conn, now)?;
    let k = ScoringConstants::builtin();
    let rate = o.hourly_rate;
    let hours = |pd: f64| pd * k.caps.minutes_per_day / 60.0;
    let usd = |pd: f64| (rate > 0.0).then(|| value_usd(k, pd, rate));
    let today = tz.date(now);

    let month_start = today.with_day(1).unwrap_or(today);
    let month_pd: f64 = conn.query_row(
        "SELECT COALESCE(SUM(person_days), 0) FROM daily WHERE day >= ?1",
        [day_key(month_start)],
        |r| r.get(0),
    )?;

    let from = today - Duration::days(HISTORY_DAYS - 1);
    let mut by_day: HashMap<String, (f64, i64)> = HashMap::new();
    let mut st = conn.prepare("SELECT day, person_days, turns FROM daily WHERE day >= ?1")?;
    for (d, pd, t) in st.query_map([day_key(from)], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?, r.get::<_, i64>(2)?)))?.flatten() {
        by_day.insert(d, (pd, t));
    }
    let days: Vec<Value> = (0..HISTORY_DAYS)
        .map(|i| {
            let key = day_key(from + Duration::days(i));
            let (pd, turns) = by_day.get(&key).copied().unwrap_or((0.0, 0));
            json!({ "day": key, "hours": hours(pd), "usd": usd(pd), "person_days": pd, "turns": turns })
        })
        .collect();

    // Hours per kind of work over the same window.
    let mut by_cat: HashMap<Category, (f64, i64)> = HashMap::new();
    let mut st = conn.prepare("SELECT task_class, SUM(credited_pd), COUNT(*) FROM turns WHERE ended_at >= ?1 GROUP BY task_class")?;
    for (c, pd, n) in st.query_map([now - HISTORY_DAYS * DAY_MS], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?, r.get::<_, i64>(2)?)))?.flatten() {
        let e = by_cat.entry(Category::of(TaskClass::parse(&c).unwrap_or(TaskClass::Other))).or_default();
        e.0 += pd;
        e.1 += n;
    }
    let total_cat: f64 = by_cat.values().map(|v| v.0).sum();
    let categories: Vec<Value> = Category::ALL
        .iter()
        .map(|c| {
            let (pd, n) = by_cat.get(c).copied().unwrap_or((0.0, 0));
            json!({ "category": c.as_str(), "name": c.name_zh(), "color": c.color(), "hours": hours(pd),
                    "share": if total_cat > 0.0 { pd / total_cat } else { 0.0 }, "turns": n })
        })
        .collect();

    let mut st = conn.prepare(
        "SELECT ended_at, task_class, credited_pd, files_touched, test_run, test_passed FROM turns
         WHERE ended_at IS NOT NULL ORDER BY ended_at DESC LIMIT 10",
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
            ))
        })?
        .flatten()
        .map(|(at, c, pd, files, test_run, passed)| {
            let cat = Category::of(TaskClass::parse(&c).unwrap_or(TaskClass::Other));
            json!({
                "at": at, "class": c, "name": class_name(&c), "color": cat.color(), "hours": hours(pd), "usd": usd(pd),
                "person_days": pd, "files": files, "test_passed": (test_run == 1).then(|| passed == Some(1)),
            })
        })
        .collect();

    let r = &o.rank;
    Ok(json!({
        "generated_at": now,
        "hourly_rate_usd": rate,
        "character": character(conn, tz, cfg, &o, now, working, subagents, last_event)?,
        "total": { "hours": o.total_hours, "usd": usd(o.total_pd), "person_days": o.total_pd, "xp": r.xp },
        "today": { "hours": o.today_hours, "usd": usd(o.today_pd), "person_days": o.today_pd },
        "week": { "hours": o.week_hours, "usd": usd(o.week_pd), "person_days": o.week_pd, "leverage": o.week_leverage },
        "month": { "hours": hours(month_pd), "usd": usd(month_pd), "person_days": month_pd },
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
        "categories": categories,
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
