//! ~/.shadowcorp/widget.json: the compact state the desktop widget shows.
//! Rewritten by the daemon after new activity; the widget polls it.

use std::fs;

use rusqlite::{Connection, OptionalExtension};
use serde_json::{json, Value};
use shadowcorp_core::event::TaskClass;
use shadowcorp_core::scoring::{value_usd, ScoringConstants};

use crate::config::Config;
use crate::ingest::{Result, Tz};
use crate::paths::{write_private, Paths};
use crate::snapshot;

pub fn data(conn: &Connection, tz: Tz, cfg: &Config, now: i64) -> Result<Value> {
    let o = snapshot::output(conn, tz, cfg, now);
    let (working, subagents, last_event) = snapshot::activity(conn, now)?;
    let last_turn: Option<(f64, String, i64)> = conn
        .query_row(
            "SELECT credited_pd, task_class, ended_at FROM turns WHERE ended_at IS NOT NULL ORDER BY ended_at DESC LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    let k = ScoringConstants::builtin();
    let r = &o.rank;
    Ok(json!({
        "generated_at": now,
        "hourly_rate_usd": o.hourly_rate,
        "total": { "usd": o.total_usd, "person_days": o.total_pd, "xp": r.xp },
        "today": { "usd": o.today_usd, "person_days": o.today_pd },
        "week": { "usd": o.week_usd, "person_days": o.week_pd, "leverage": o.week_leverage },
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
        "activity": { "working": working, "subagents": subagents, "last_event": last_event },
        "last_turn": last_turn.map(|(pd, class, at)| json!({
            "usd": value_usd(k, pd, o.hourly_rate),
            "person_days": pd,
            "class": TaskClass::parse(&class).map(|c| c.name_zh()).unwrap_or("杂项"),
            "at": at,
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
