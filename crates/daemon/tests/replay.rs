//! Replay guarantees (SPEC 17.2): the fixtures ingest cleanly, a processor
//! killed mid-batch loses nothing, and duplicate event ids count once.

use std::fs;
use std::path::PathBuf;

use chrono::{DateTime, FixedOffset};
use daemon::capture::{from_claude_hook, CaptureEnv};
use daemon::config::Config;
use daemon::db;
use daemon::ingest::{Mode, Processor, Tz};
use daemon::paths::Paths;
use daemon::spool;
use rusqlite::Connection;
use serde_json::Value;
use shadowcorp_core::event::Event;

fn fixtures() -> Vec<Value> {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/hooks/claude_code");
    let mut files: Vec<PathBuf> = fs::read_dir(dir).unwrap().flatten().map(|e| e.path()).collect();
    files.sort();
    files
        .iter()
        .flat_map(|f| fs::read_to_string(f).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect::<Vec<Value>>())
        .collect()
}

fn home(tag: &str) -> Paths {
    let p = Paths::at(std::env::temp_dir().join(format!("sc-replay-{tag}-{}", std::process::id())));
    let _ = fs::remove_dir_all(&p.home);
    p.ensure().unwrap();
    p
}

fn events(paths: &Paths) -> Vec<Event> {
    fixtures()
        .into_iter()
        .filter_map(|mut v| {
            let ts = DateTime::parse_from_rfc3339(v["_ts"].as_str().unwrap()).unwrap().timestamp_millis();
            v.as_object_mut().unwrap().remove("_ts");
            let raw = serde_json::to_vec(&v).unwrap();
            let env = CaptureEnv { paths, now_ms: ts, nonce: String::new(), git_lookup: false };
            from_claude_hook(&v, &raw, &env)
        })
        .collect()
}

fn processor(paths: &Paths) -> Processor {
    let tz = Tz::Fixed(FixedOffset::east_opt(8 * 3600).unwrap());
    Processor::new(db::open(&paths.db).unwrap(), Mode::Live, tz, Config::default())
}

/// Everything derived, in a comparable form.
fn state(conn: &Connection) -> Vec<String> {
    let mut out = Vec::new();
    for q in [
        "SELECT metric || '|' || scope || '|' || printf('%.6f', value) FROM counters ORDER BY metric, scope",
        "SELECT achievement_id || ':' || tier FROM unlocks ORDER BY 1",
        "SELECT day || '|' || printf('%.6f', person_days) || '|' || turns FROM daily ORDER BY day",
        "SELECT coins || '|' || freeze_tokens FROM wallet",
        "SELECT id || '|' || printf('%.4f', human_minutes) || '|' || ended_at FROM turns ORDER BY id",
        "SELECT COUNT(*) FROM events",
    ] {
        let mut st = conn.prepare(q).unwrap();
        out.extend(st.query_map([], |r| r.get::<_, String>(0)).unwrap().flatten().map(|s| s.to_string()));
    }
    out
}

#[test]
fn fixtures_ingest_and_score() {
    let paths = home("plain");
    let evs = events(&paths);
    assert!(evs.len() >= 45, "fixture events: {}", evs.len());
    for e in &evs {
        spool::append(&paths, e).unwrap();
    }
    let mut p = processor(&paths);
    assert_eq!(p.ingest_spool(&paths).unwrap(), evs.len());
    let turns: i64 = p.conn.query_row("SELECT COUNT(*) FROM turns WHERE ended_at IS NOT NULL", [], |r| r.get(0)).unwrap();
    assert_eq!(turns, 9);
    let pd = p.ctr("person_days", "all");
    assert!(pd > 0.4 && pd < 1.5, "fixture total {pd}");
    // Spool consumed: a second pass is a no-op.
    assert_eq!(p.ingest_spool(&paths).unwrap(), 0);
}

#[test]
fn crash_mid_batch_and_duplicates_change_nothing() {
    let clean = home("clean");
    let evs = events(&clean);
    for e in &evs {
        spool::append(&clean, e).unwrap();
    }
    let mut p = processor(&clean);
    p.ingest_spool(&clean).unwrap();
    let want = state(&p.conn);

    let crashy = home("crashy");
    let half = evs.len() / 2;
    for e in &evs[..half] {
        spool::append(&crashy, e).unwrap();
    }
    processor(&crashy).ingest_spool(&crashy).unwrap();
    {
        // A processor dies inside a transaction (like kill -9): nothing it
        // did may persist, including the spool offset.
        for e in &evs[half..] {
            spool::append(&crashy, e).unwrap();
        }
        let mut doomed = processor(&crashy);
        doomed.begin().unwrap();
        for e in &evs[half..half + 5] {
            doomed.handle(e).unwrap();
        }
        drop(doomed);
    }
    // Duplicates in the spool (a hook retried, a file replayed).
    for e in &evs[..10] {
        spool::append(&crashy, e).unwrap();
    }
    let mut p2 = processor(&crashy);
    p2.ingest_spool(&crashy).unwrap();
    assert_eq!(state(&p2.conn), want);
}

#[test]
fn panel_data_hides_secrets_and_writes_files() {
    let paths = home("panel");
    for e in &events(&paths) {
        spool::append(&paths, e).unwrap();
    }
    let mut p = processor(&paths);
    p.ingest_spool(&paths).unwrap();
    let tz = Tz::Fixed(FixedOffset::east_opt(8 * 3600).unwrap());
    let d = daemon::panel::data(&p.conn, tz, 0.0, 1_793_200_000_000).unwrap();
    let ach = d["achievements"].as_array().unwrap();
    assert_eq!(ach.len(), shadowcorp_core::achievements::Catalog::builtin().achievements.len());
    for a in ach {
        if a["hidden"] == true {
            assert!(a["name"].is_null() && a["unlock_line"].is_null(), "{} leaks a hidden name", a["id"]);
        }
    }
    assert_eq!(d["weeks"].as_array().unwrap().len(), 8);
    assert_eq!(d["roles"].as_array().unwrap().len(), 12);
    let page = daemon::panel::write(&paths, &p.conn, tz, 0.0, 1_793_200_000_000).unwrap();
    let html = fs::read_to_string(&page).unwrap();
    assert!(html.contains("window.SHADOWCORP_DATA = {") && !html.contains("/*INLINE_DATA*/"), "data is inlined");
    let js = fs::read_to_string(paths.home.join("panel-data.js")).unwrap();
    assert!(js.starts_with("window.SHADOWCORP_DATA = {"));
    assert!(!js.contains("/Users") && !js.contains("/w/repo"), "no paths in panel data");
}

#[test]
fn widget_data_carries_history_without_paths() {
    let paths = home("widget");
    for e in &events(&paths) {
        spool::append(&paths, e).unwrap();
    }
    let mut p = processor(&paths);
    p.ingest_spool(&paths).unwrap();
    let tz = Tz::Fixed(FixedOffset::east_opt(8 * 3600).unwrap());
    let now = 1_793_200_000_000; // 2026-10-28, local
    let d = daemon::widget::data(&p.conn, tz, &Config::default(), now).unwrap();
    assert_eq!(d["days"].as_array().unwrap().len(), 30);
    assert_eq!(d["ranks"].as_array().unwrap().len(), 7);
    assert_eq!(d["days"][29]["day"], "2026-10-28");
    assert!(d["today"]["person_days"].as_f64().unwrap() > 0.0, "{}", d["today"]);
    assert!(d["month"]["person_days"].as_f64().unwrap() >= d["today"]["person_days"].as_f64().unwrap());
    assert_eq!(d["today"]["usd"], 0.0, "no rate configured, no dollars");
    assert!(!d["classes"].as_array().unwrap().is_empty());
    let turns = d["turns"].as_array().unwrap();
    assert!(turns.len() <= 10 && !turns.is_empty());
    assert!(turns[0]["usd"].as_f64().unwrap() >= 0.0);
    assert_eq!(d["rank"]["label"], "青铜 III");
    let js = d.to_string();
    assert!(!js.contains("/Users") && !js.contains("/w/repo") && !js.contains("acme"), "no paths or repo names");
}

#[test]
fn day_report_from_fixtures() {
    let paths = home("report");
    for e in &events(&paths) {
        spool::append(&paths, e).unwrap();
    }
    let mut p = processor(&paths);
    p.ingest_spool(&paths).unwrap();
    let tz = Tz::Fixed(FixedOffset::east_opt(8 * 3600).unwrap());
    let claude = paths.home.join("no-claude-dir");
    let date = chrono::NaiveDate::from_ymd_opt(2026, 10, 27).unwrap();
    let r = daemon::report::day(&p.conn, tz, &Config::default(), &claude, date, 1_793_200_000_000, true).unwrap();
    assert_eq!(r["turns"], 3, "{r}");
    assert_eq!(r["sessions"].as_array().unwrap().len(), 1);
    let s = &r["sessions"][0];
    assert_eq!((s["from"].as_str(), s["to"].as_str()), (Some("10:01"), Some("10:22")));
    assert_eq!(s["title"], "会话 1", "no transcript → numbered");
    assert!(r["human_hours"].as_f64().unwrap() > 0.0);
    let cats: f64 = r["categories"].as_array().unwrap().iter().map(|c| c["share"].as_f64().unwrap()).sum();
    assert!((cats - 1.0).abs() < 1e-6);
    assert_eq!(r["blocks"].as_array().unwrap().len(), 3);
    assert!(r["usd"].is_null());
    assert_eq!(r["character"]["mood"], "happy");
    let empty = daemon::report::day(&p.conn, tz, &Config::default(), &claude, date.succ_opt().unwrap().succ_opt().unwrap(), 1_793_200_000_000, false).unwrap();
    assert_eq!(empty["turns"], 0);
    assert_eq!(empty["character"]["mood"], "waiting");
    assert!(daemon::report::day_text(&r).contains("会话 1"));
}
