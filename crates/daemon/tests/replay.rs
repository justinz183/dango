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
