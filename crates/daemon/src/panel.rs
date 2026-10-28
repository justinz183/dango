//! The local visual panel: a self-contained page (~/.shadowcorp/panel.html)
//! plus the data it shows (panel-data.js), rewritten by the daemon after new
//! activity so the office moves while an agent works. Both files stay on
//! disk; nothing is served or uploaded. Derived values only.

use std::fs;
use std::path::PathBuf;

use chrono::Duration;
use rusqlite::Connection;
use serde_json::{json, Value};
use shadowcorp_core::achievements::{self, display_name, Catalog, Store};
use shadowcorp_core::progress::record_label;

use crate::ingest::{week_key, Result, Tz};
use crate::paths::{write_private, Paths};
use crate::snapshot::{self, counter, DbStore};

pub const TEMPLATE: &str = include_str!("../../../assets/panel/panel.html");

/// Unlocks this recent get the celebration when the panel opens.
const RECENT_MS: i64 = 15 * 60_000;

pub fn html_path(paths: &Paths) -> PathBuf {
    paths.home.join("panel.html")
}

pub fn data(conn: &Connection, tz: Tz, cfg_target: f64, now: i64) -> Result<Value> {
    let cat = Catalog::builtin();
    let c = snapshot::company(conn, tz, cfg_target, now)?;
    let mut store = DbStore(conn);

    let mut ach = Vec::new();
    for a in &cat.achievements {
        let tier = store.unlocked_tier(&a.id);
        let unlocked_at: Option<i64> = conn
            .query_row(
                "SELECT MAX(unlocked_at) FROM unlocks WHERE achievement_id = ?1",
                [&a.id],
                |r| r.get(0),
            )
            .unwrap_or(None);
        let shown = if tier == 0 { 1 } else { tier };
        let secret = a.hidden && tier == 0;
        let next = a.next_tier(tier);
        ach.push(json!({
            "id": a.id,
            "category": a.category.name_zh(),
            "hidden": secret,
            "hint": a.hint,
            "name": if secret { Value::Null } else { json!(display_name(a, shown)) },
            "unlock_line": if secret { Value::Null } else { json!(a.unlock_line) },
            "codex_line": if secret { Value::Null } else { json!(a.codex_line) },
            "tier": tier,
            "tiers": a.tiers.len(),
            "rarity": a.tier(shown).map(|t| format!("{:?}", t.rarity).to_lowercase()),
            "next_threshold": next.map(|t| t.threshold),
            "progress": achievements::progress(a, &mut store).map(|(cur, th)| json!([cur, th])),
            "unit": a.unit,
            "global_pct": a.global_pct,
            "unlocked_at": unlocked_at,
        }));
    }

    let roles: Vec<Value> = c
        .roles
        .iter()
        .map(|(id, tier, turns)| {
            let r = cat.role_card(id);
            let next = cat.role_card_tiers.iter().find(|t| **t > *turns).copied();
            json!({ "id": id, "name": r.map(|r| r.name.clone()), "face": r.map(|r| r.face.clone()),
                    "tier": tier, "turns": turns, "next": next })
        })
        .collect();

    let today = tz.date(now);
    let weeks: Vec<Value> = (0..8)
        .rev()
        .map(|i| {
            let w = week_key(today - Duration::days(7 * i));
            json!({ "week": w, "pd": counter(conn, "person_days", &format!("week:{w}")) })
        })
        .collect();

    let (working, subagents, last_event) = snapshot::activity(conn, now)?;

    let mut recent = Vec::new();
    let mut st = conn.prepare(
        "SELECT achievement_id, tier, unlocked_at FROM unlocks WHERE backfilled = 0 AND unlocked_at >= ?1 ORDER BY unlocked_at DESC LIMIT 5",
    )?;
    for (id, tier, at) in st.query_map([now - RECENT_MS], |r| Ok((r.get::<_, String>(0)?, r.get::<_, u32>(1)?, r.get::<_, i64>(2)?)))?.flatten() {
        if let Some(a) = cat.get(&id) {
            let rarity = a.tier(tier).map(|t| format!("{:?}", t.rarity).to_lowercase());
            recent.push(json!({ "key": format!("{id}:{tier}"), "name": display_name(a, tier), "line": a.unlock_line, "rarity": rarity, "at": at }));
        }
    }

    Ok(json!({
        "generated_at": now,
        "company": {
            "total_pd": c.total_pd,
            "stage": { "level": c.stage.level, "name": c.stage.name, "employees": c.stage.employees },
            "next_stage": c.next.map(|n| json!({ "name": n.name, "threshold": n.threshold })),
            "title": c.title,
            "week_pd": c.week_pd,
            "week_target": c.week_target,
            "week_leverage": c.week_leverage,
            "streak": { "current": c.streak.current, "longest": c.streak.longest, "previous": c.streak.previous },
            "coins": c.coins,
            "freeze_tokens": c.freeze_tokens,
            "records": c.records.iter().map(|(k, v)| json!({ "key": k, "label": record_label(k), "value": v })).collect::<Vec<_>>(),
            "unlocked": c.unlocked,
            "achievements": c.achievements,
        },
        "items": c.items,
        "achievements": ach,
        "roles": roles,
        "weeks": weeks,
        "activity": { "working": working, "subagents": subagents, "last_event": last_event },
        "recent": recent,
    }))
}

/// Writes panel-data.js and panel.html (with the same data inlined, for
/// browsers that will not load a sibling file from a local page); returns
/// the page path. Each write goes through a temp file and a rename so the
/// page never reads half a file.
pub fn write(paths: &Paths, conn: &Connection, tz: Tz, cfg_target: f64, now: i64) -> Result<PathBuf> {
    let js = format!("window.SHADOWCORP_DATA = {};\n", data(conn, tz, cfg_target, now)?);
    let page = html_path(paths);
    let html = TEMPLATE.replace("/*INLINE_DATA*/", &js.replace("</", "<\\/"));
    for (name, body) in [("panel-data.js", js.as_str()), ("panel.html", html.as_str())] {
        let tmp = paths.home.join(format!("{name}.tmp"));
        write_private(&tmp, body.as_bytes())?;
        fs::rename(&tmp, paths.home.join(name))?;
    }
    Ok(page)
}
