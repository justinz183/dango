//! ~/.shadowcorp/widget.json: the state the desktop widget shows — the
//! headline numbers for the collapsed panel, plus the history the expanded
//! dashboard draws. Rewritten by the daemon after new activity.

use std::collections::HashMap;
use std::fs;

use chrono::{Datelike, Duration};
use rusqlite::{Connection, OptionalExtension};
use serde_json::{json, Value};
use shadowcorp_core::event::TaskClass;
use shadowcorp_core::rank::RANKS;
use shadowcorp_core::scoring::{value_usd, ScoringConstants};

use crate::config::Config;
use crate::ingest::{day_key, Result, Tz};
use crate::paths::{write_private, Paths};
use crate::snapshot;

const DAY_MS: i64 = 86_400_000;
pub const HISTORY_DAYS: i64 = 30;

fn class_name(c: &str) -> &'static str {
    TaskClass::parse(c).map(|c| c.name_zh()).unwrap_or("杂项")
}

pub fn data(conn: &Connection, tz: Tz, cfg: &Config, now: i64) -> Result<Value> {
    let o = snapshot::output(conn, tz, cfg, now);
    let (working, subagents, last_event) = snapshot::activity(conn, now)?;
    let k = ScoringConstants::builtin();
    let rate = o.hourly_rate;
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
            json!({ "day": key, "usd": value_usd(k, pd, rate), "person_days": pd, "turns": turns })
        })
        .collect();

    let mut st = conn.prepare(
        "SELECT task_class, SUM(credited_pd), COUNT(*) FROM turns WHERE ended_at >= ?1 GROUP BY task_class ORDER BY 2 DESC",
    )?;
    let classes: Vec<Value> = st
        .query_map([now - HISTORY_DAYS * DAY_MS], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?, r.get::<_, i64>(2)?)))?
        .flatten()
        .map(|(c, pd, n)| json!({ "class": c, "name": class_name(&c), "usd": value_usd(k, pd, rate), "person_days": pd, "turns": n }))
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
            json!({
                "at": at, "class": c, "name": class_name(&c), "usd": value_usd(k, pd, rate), "person_days": pd,
                "files": files, "test_passed": (test_run == 1).then(|| passed == Some(1)),
            })
        })
        .collect();
    let last_turn: Option<(f64, String, i64)> = conn
        .query_row(
            "SELECT credited_pd, task_class, ended_at FROM turns WHERE ended_at IS NOT NULL ORDER BY ended_at DESC LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;

    let r = &o.rank;
    Ok(json!({
        "generated_at": now,
        "hourly_rate_usd": rate,
        "total": { "usd": o.total_usd, "person_days": o.total_pd, "xp": r.xp },
        "today": { "usd": o.today_usd, "person_days": o.today_pd },
        "week": { "usd": o.week_usd, "person_days": o.week_pd, "leverage": o.week_leverage },
        "month": { "usd": value_usd(k, month_pd, rate), "person_days": month_pd },
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
        "classes": classes,
        "turns": turns,
        "activity": { "working": working, "subagents": subagents, "last_event": last_event },
        "last_turn": last_turn.map(|(pd, class, at)| json!({
            "usd": value_usd(k, pd, rate), "person_days": pd, "class": class_name(&class), "at": at,
        })),
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
