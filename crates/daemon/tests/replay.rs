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
    assert!(pd > 0.2 && pd < 1.5, "fixture total {pd}");
    // Every credited minute belongs to an occupation, and the dollars are
    // exactly those minutes at each occupation's wage.
    let rates = shadowcorp_core::occupation::Table::builtin();
    let mut st = p.conn.prepare("SELECT substr(metric, 6), value FROM counters WHERE metric LIKE 'work:%' AND scope = 'all'").unwrap();
    let work: Vec<(String, f64)> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().flatten().collect();
    drop(st);
    let minutes: f64 = work.iter().map(|w| w.1).sum();
    assert!((minutes - pd * 480.0).abs() < 1e-6, "{minutes} min vs {pd} pd");
    let usd: f64 = work.iter().map(|(o, m)| m / 60.0 * rates.rate(o)).sum();
    assert!((p.ctr("usd", "all") - usd).abs() < 1e-6 && usd > 0.0, "{usd}");
    let turn_usd: f64 = p.conn.query_row("SELECT SUM(usd) FROM turns", [], |r| r.get(0)).unwrap();
    assert!((turn_usd - usd).abs() < 1e-6);
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
    assert_eq!(d["days"][29]["day"], "2026-10-28");
    assert!(d["today"]["hours"].as_f64().unwrap() > 0.0, "{}", d["today"]);
    assert!(d["month"]["hours"].as_f64().unwrap() >= d["today"]["hours"].as_f64().unwrap());
    assert!(d["today"]["usd"].as_f64().unwrap() > 0.0, "{}", d["today"]);
    assert!(d["total"]["usd"].as_f64().unwrap() >= d["month"]["usd"].as_f64().unwrap() - 1e-9);
    assert!(!d["rates"]["label"].as_str().unwrap().is_empty());
    let jobs = d["jobs"].as_array().unwrap();
    assert!(!jobs.is_empty());
    let share: f64 = jobs.iter().map(|c| c["share"].as_f64().unwrap()).sum();
    assert!((share - 1.0).abs() < 1e-6, "{share}");
    assert!(jobs.windows(2).all(|w| w[0]["usd"].as_f64() >= w[1]["usd"].as_f64()), "most dollars first");
    let turns = d["turns"].as_array().unwrap();
    assert!(turns.len() <= 10 && !turns.is_empty());
    assert!(turns[0]["usd"].as_f64().unwrap() > 0.0 && turns[0]["color"].is_string(), "{}", turns[0]);
    let ch = &d["character"];
    assert_eq!(ch["name"], "Claude");
    assert!(["waiting", "focused", "happy", "proud", "sleepy", "missing"].contains(&ch["mood"].as_str().unwrap()), "{ch}");
    assert!(ch["line"].as_str().unwrap().chars().count() <= 18, "{ch}");
    assert!(d["rank"].is_null() && d["total"]["xp"].is_null(), "ranks are gone");
    assert!(d["record"]["day_usd"].as_f64().unwrap() > 0.0, "{}", d["record"]);
    assert!(d["activity"]["job"]["name"].is_string(), "{}", d["activity"]);
    assert!(d["character"]["days_together"].as_i64().unwrap() >= 1);
    assert!(d["office"].is_array(), "{}", d["office"]);
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
    let r = daemon::report::day(&p.conn, tz, &Config::default(), &claude, date, 1_793_200_000_000, true, None).unwrap();
    assert_eq!(r["turns"], 3, "{r}");
    assert_eq!(r["sessions"].as_array().unwrap().len(), 1);
    let s = &r["sessions"][0];
    assert_eq!((s["from"].as_str(), s["to"].as_str()), (Some("10:01"), Some("10:22")));
    assert_eq!(s["title"], "会话 1", "no transcript → numbered");
    assert!(r["human_hours"].as_f64().unwrap() > 0.0);
    let jobs = r["jobs"].as_array().unwrap();
    let share: f64 = jobs.iter().map(|c| c["share"].as_f64().unwrap()).sum();
    assert!((share - 1.0).abs() < 1e-6);
    let job_usd: f64 = jobs.iter().map(|c| c["usd"].as_f64().unwrap()).sum();
    assert!((job_usd - r["usd"].as_f64().unwrap()).abs() < 1e-6 && job_usd > 0.0);
    assert_eq!(r["blocks"].as_array().unwrap().len(), 3);
    assert!(r["blocks"].as_array().unwrap().iter().all(|b| b["color"].is_string()));
    assert!(r["character"]["number"].as_str().unwrap().starts_with('$'));
    assert_eq!(r["character"]["mood"], "happy");
    let empty = daemon::report::day(&p.conn, tz, &Config::default(), &claude, date.succ_opt().unwrap().succ_opt().unwrap(), 1_793_200_000_000, false, None).unwrap();
    assert_eq!(empty["turns"], 0);
    assert_eq!(empty["character"]["mood"], "waiting");
    assert!(daemon::report::day_text(&r).contains("会话 1"));
}

#[test]
fn week_and_month_reports_from_fixtures() {
    let paths = home("weekmonth");
    for e in &events(&paths) {
        spool::append(&paths, e).unwrap();
    }
    let mut p = processor(&paths);
    p.ingest_spool(&paths).unwrap();
    let tz = Tz::Fixed(FixedOffset::east_opt(8 * 3600).unwrap());
    let claude = paths.home.join("no-claude-dir");
    let now = 1_793_200_000_000; // 2026-10-28 local
    let any = chrono::NaiveDate::from_ymd_opt(2026, 10, 28).unwrap();
    let w = daemon::report::week(&p.conn, tz, &Config::default(), &claude, any, now, false, None).unwrap();
    assert_eq!(w["kind"], "week");
    assert_eq!(w["date"], "2026-W44");
    let days = w["days"].as_array().unwrap();
    assert_eq!(days.len(), 7);
    assert_eq!(days[0]["date"], "2026-10-26", "weeks start on Monday");
    assert_eq!(w["active_days"], 3, "fixtures span Mon, Tue, Wed");
    assert_eq!(w["turns"], 9);
    let sum: f64 = days.iter().map(|d| d["hours"].as_f64().unwrap()).sum();
    assert!((sum - w["human_hours"].as_f64().unwrap()).abs() < 0.3, "days add up: {sum} vs {}", w["human_hours"]);
    let usd: f64 = days.iter().map(|d| d["usd"].as_f64().unwrap()).sum();
    assert!((usd - w["usd"].as_f64().unwrap()).abs() < 1e-6, "dollars add up");
    assert_eq!(w["prev"]["label"], "上周");
    assert!(w["prev"]["usd"].as_f64().unwrap() >= 0.0 && w["record_day_usd"].as_f64().unwrap() > 0.0);
    assert!(w["sessions"].as_array().unwrap().len() <= 3);

    let m = daemon::report::month(&p.conn, tz, &Config::default(), &claude, any, now, false, None).unwrap();
    assert_eq!(m["date"], "2026-10");
    assert_eq!(m["days"].as_array().unwrap().len(), 31);
    assert_eq!(m["first_weekday"], 3, "2026-10-01 is a Thursday");
    assert_eq!(m["active_days"], 3);
    assert_eq!(m["longest_run"], 3);
    assert_eq!(m["by_hour"].as_array().unwrap().len(), 24);
    let window = m["peak_window"].as_str().unwrap();
    let hours: Vec<u32> = window.trim_end_matches(" 点").split('–').map(|x| x.parse().unwrap()).collect();
    assert!(hours.iter().all(|h| *h < 24), "a real clock window: {window}");
    assert_eq!(m["turns"], w["turns"]);
    let text = daemon::report::text(&m);
    assert!(text.contains("活跃 3 天"), "{text}");

    let y = daemon::report::year(&p.conn, tz, &Config::default(), &claude, any, now, false, None).unwrap();
    assert_eq!(y["kind"], "year");
    assert_eq!(y["date"], "2026");
    assert_eq!(y["label"], "2026 年 · 截至 10月28日");
    let months = y["months"].as_array().unwrap();
    assert_eq!(months.len(), 12);
    assert_eq!(months[9]["current"], true);
    assert_eq!(months[10]["future"], true);
    let usd: f64 = months.iter().map(|m| m["usd"].as_f64().unwrap()).sum();
    assert!((usd - y["usd"].as_f64().unwrap()).abs() < 1e-6, "months add up");
    assert!((months[9]["usd"].as_f64().unwrap() - m["usd"].as_f64().unwrap()).abs() < 1e-6, "October is the month report");
    let heat = y["heat"].as_array().unwrap();
    assert_eq!(heat.len(), 365);
    assert_eq!(y["first_weekday"], 3, "2026-01-01 is a Thursday");
    assert_eq!(y["today_index"], 300);
    assert_eq!(heat.iter().filter(|d| d.as_f64().unwrap() > 0.0).count(), 3);
    assert_eq!(y["active_days"], 3);
    assert_eq!(y["best_month"], 9);
    assert!(y["best_day"]["usd"].as_f64().unwrap() > 0.0);
    assert_eq!(y["prev"]["label"], "去年");
    assert_eq!(y["turns"], m["turns"]);
    assert!(daemon::report::text(&y).contains("10月 $"), "{}", daemon::report::text(&y));

    let empty = daemon::report::week(&p.conn, tz, &Config::default(), &claude, any + chrono::Duration::days(14), now, false, None).unwrap();
    assert_eq!(empty["turns"], 0);
    assert_eq!(empty["character"]["mood"], "waiting");
    let past = daemon::report::year(&p.conn, tz, &Config::default(), &claude, any - chrono::Duration::days(365), now, false, None).unwrap();
    assert_eq!(past["label"], "2025 年");
    assert_eq!((past["prev"]["label"].as_str(), past["now_label"].as_str()), (Some("2024 年"), Some("2025 年")));
    assert_eq!((w["prev"]["label"].as_str(), w["now_label"].as_str()), (Some("上周"), Some("本周")));
    let last = daemon::report::week(&p.conn, tz, &Config::default(), &claude, any - chrono::Duration::days(7), now, false, None).unwrap();
    assert_eq!((last["prev"]["label"].as_str(), last["now_label"].as_str()), (Some("第 42 周"), Some("第 43 周")));
    let sept = daemon::report::month(&p.conn, tz, &Config::default(), &claude, any - chrono::Duration::days(30), now, false, None).unwrap();
    assert_eq!((sept["prev"]["label"].as_str(), sept["now_label"].as_str()), (Some("8 月"), Some("9 月")));
    assert_eq!(past["character"]["mood"], "waiting");
    assert!(past["today_index"].is_null());
}

#[test]
fn codex_history_backfills_and_splits_by_tool() {
    let paths = home("codex");
    for e in &events(&paths) {
        spool::append(&paths, e).unwrap();
    }
    let tz = Tz::Fixed(FixedOffset::east_opt(8 * 3600).unwrap());
    processor(&paths).ingest_spool(&paths).unwrap();
    let mut p = Processor::new(db::open(&paths.db).unwrap(), Mode::Backfill, tz, Config::default());
    let codex = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/codex");
    let none = paths.home.join("no-claude-dir");
    let r = daemon::backfill::run(&mut p, &paths, &none, i64::MAX, Some((&codex, i64::MAX))).unwrap();
    assert_eq!(r.files, 3);
    assert!(r.new_events > 10, "{r:?}");

    let q = |sql: &str| -> String { p.conn.query_row(sql, [], |r| r.get::<_, String>(0)).unwrap() };
    assert_eq!(q("SELECT source FROM sessions WHERE id = 'th-main'"), "codex");
    assert_eq!(q("SELECT COUNT(*) || '' FROM sessions WHERE id IN ('th-sub', 'th-g')"), "0", "sub-agents count toward the parent");
    assert_eq!(q("SELECT COUNT(*) || '' FROM turns WHERE session_id = 'th-main' AND ended_at IS NOT NULL"), "2");
    let work: std::collections::BTreeMap<String, f64> = serde_json::from_str(&q("SELECT work FROM turns WHERE id = 't1'")).unwrap();
    assert_eq!(shadowcorp_core::occupation::main(&work).as_deref(), Some("video"), "{work:?}");
    for job in ["swe", "writer", "data"] {
        assert!(work.contains_key(job), "{job} missing from {work:?}");
    }
    // ffmpeg 15 + whisper 20 + turn base 5 + one sub-agent 12, plus the web
    // search (5): in a turn about a video, research is the editor's work.
    assert!(!work.contains_key("research") && (work["video"] - 57.0).abs() < 1e-9, "{work:?}");
    let failed: String = q("SELECT test_passed || '' FROM turns WHERE id = 't2'");
    assert_eq!(failed, "0", "cargo test exited 101");

    let codex_usd = p.ctr("usd:codex", "all");
    let sum: f64 = p.conn.query_row("SELECT SUM(t.usd) FROM turns t JOIN sessions s ON s.id = t.session_id WHERE s.source = 'codex'", [], |r| r.get(0)).unwrap();
    assert!(codex_usd > 0.0 && (codex_usd - sum).abs() < 1e-6, "{codex_usd} vs {sum}");
    assert!(p.ctr("usd:claude_code", "all") > 0.0);
    assert!((p.ctr("usd:claude_code", "all") + codex_usd - p.ctr("usd", "all")).abs() < 1e-6, "tools add up");
    let mins: f64 = p.conn.query_row("SELECT SUM(t.credited_pd) * 480 FROM turns t JOIN sessions s ON s.id = t.session_id WHERE s.source = 'codex'", [], |r| r.get(0)).unwrap();
    assert!((p.ctr("minutes:codex", "all") - mins).abs() < 1e-6);
    let dump: String = p.conn.query_row("SELECT group_concat(payload) FROM events", [], |r| r.get(0)).unwrap();
    assert!(!dump.contains("视频") && !dump.contains("secret") && !dump.contains("/w/vid"), "no prompts, queries or paths");

    let claude = paths.home.join("no-claude-dir");
    let day = daemon::report::day(&p.conn, tz, &Config::default(), &claude, chrono::NaiveDate::from_ymd_opt(2026, 10, 27).unwrap(), 1_793_200_000_000, false, None).unwrap();
    let tools = day["tools"].as_array().unwrap();
    let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert!(names.contains(&"Codex") && names.contains(&"Claude Code"), "{names:?}");
    let share: f64 = tools.iter().map(|t| t["share"].as_f64().unwrap()).sum();
    assert!((share - 1.0).abs() < 1e-6);
    assert!(daemon::report::text(&day).contains("Codex $"));
    let w = daemon::widget::data(&p.conn, tz, &Config::default(), 1_793_200_000_000).unwrap();
    assert_eq!(w["tools_all"].as_array().unwrap().len(), 2);

    // Every dashboard block, per agent: the two views add up to the whole.
    let views = &w["views"];
    let total = |v: &Value| v["total"]["usd"].as_f64().unwrap();
    assert!((total(&views["codex"]) - codex_usd).abs() < 1e-6);
    assert!((total(&views["codex"]) + total(&views["claude_code"]) - w["total"]["usd"].as_f64().unwrap()).abs() < 1e-6);
    let codex_jobs: f64 = views["codex"]["jobs"].as_array().unwrap().iter().map(|j| j["usd"].as_f64().unwrap()).sum();
    let all_jobs: f64 = w["jobs"].as_array().unwrap().iter().map(|j| j["usd"].as_f64().unwrap()).sum();
    assert!(codex_jobs > 0.0 && codex_jobs < all_jobs, "{codex_jobs} of {all_jobs}");
    assert!(views["codex"]["jobs"].as_array().unwrap().iter().any(|j| j["id"] == "video"));
    assert!(!views["claude_code"]["jobs"].as_array().unwrap().iter().any(|j| j["id"] == "video"), "the video job was Codex's");
    assert!(views["codex"]["turns"].as_array().unwrap().iter().all(|t| t["tool"] == "Codex"));
    assert_eq!(views["codex"]["days"].as_array().unwrap().len(), 30);
    let codex_hours = views["codex"]["total"]["hours"].as_f64().unwrap();
    assert!((codex_hours - mins / 60.0).abs() < 1e-6);
    // Shorter windows never show more than the 30-day one; today has 24 hours.
    assert_eq!(views["codex"]["hours"].as_array().unwrap().len(), 24);
    let sum = |v: &Value| v.as_array().unwrap().iter().map(|j| j["usd"].as_f64().unwrap()).sum::<f64>();
    let (j1, j7) = (sum(&views["codex"]["jobs_1d"]), sum(&views["codex"]["jobs_7d"]));
    assert!(j1 <= j7 + 1e-9 && j7 <= codex_jobs + 1e-9, "{j1} {j7} {codex_jobs}");
    assert!(w["tools_7d"].is_array() && w["tools_1d"].is_array());

    // Reports for one agent.
    let only = daemon::report::day(&p.conn, tz, &Config::default(), &claude, chrono::NaiveDate::from_ymd_opt(2026, 10, 27).unwrap(), 1_793_200_000_000, false, Some("codex")).unwrap();
    let both_codex = tools.iter().find(|t| t["name"] == "Codex").unwrap()["usd"].as_f64().unwrap();
    assert!((only["usd"].as_f64().unwrap() - both_codex).abs() < 1e-6);
    assert_eq!(only["tool"], "codex");
    // 10/27 seen on 10/28: an earlier day is "那天".
    assert!(only["character"]["headline"].as_str().unwrap().starts_with("Codex 那天"), "{}", only["character"]);
    assert_eq!(only["tools"].as_array().unwrap().len(), 1);

    // Running it again changes nothing.
    let again = daemon::backfill::run(&mut p, &paths, &none, i64::MAX, Some((&codex, i64::MAX))).unwrap();
    assert_eq!(again.new_events, 0);
}

#[test]
fn each_tool_has_its_own_live_cutoff() {
    let paths = home("cutoff");
    let mut p = processor(&paths);
    let env = CaptureEnv { paths: &paths, now_ms: 1_793_000_000_000, nonce: String::new(), git_lookup: false };
    let hook = serde_json::json!({ "hook_event_name": "UserPromptSubmit", "session_id": "cx", "turn_id": "t", "prompt": "hi" });
    for ev in daemon::capture::from_codex_hook(&hook, b"x", &env) {
        p.begin().unwrap();
        p.handle(&ev).unwrap();
        p.commit().unwrap();
    }
    assert_eq!(db::get_meta(&p.conn, "live_since:codex").unwrap().as_deref(), Some("1793000000000"));
    assert_eq!(db::get_meta(&p.conn, "live_since").unwrap(), None, "Claude Code history is still open for backfill");
}

#[test]
fn model_usage_prices_turns_once() {
    let paths = home("usage");
    let tz = Tz::Fixed(FixedOffset::east_opt(8 * 3600).unwrap());
    let mut p = Processor::new(db::open(&paths.db).unwrap(), Mode::Backfill, tz, Config::default());
    let fx = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let (claude, codex) = (fx.join("claude"), fx.join("codex"));
    daemon::backfill::run(&mut p, &paths, &claude, i64::MAX, Some((&codex, i64::MAX))).unwrap();
    let priced = daemon::usage::fill(&mut p, &claude, &codex, i64::MAX, usize::MAX).unwrap();
    assert!(priced >= 4, "{priced}");
    let cost = |tid: &str| -> f64 { p.conn.query_row("SELECT cost_usd FROM turns WHERE id = ?1", [tid], |r| r.get(0)).unwrap() };
    // Opus 5.5: 10 in·$4 + 1000 5m·$5 + 2000 1h·$8 + 100k read·$0.20 + 500 out·$20, counted once
    // though written on two lines; then 200k read + 1000 out; the sub-agent's Fable 5.1:
    // 50k read·$0.25 + 2000 out·$50.
    let want = (40.0 + 5_000.0 + 16_000.0 + 20_000.0 + 10_000.0 + 40_000.0 + 20_000.0 + 12_500.0 + 100_000.0) / 1e6;
    assert!((cost("pd1") - want).abs() < 1e-9, "{} vs {want}", cost("pd1"));
    assert_eq!(cost("pd2"), 0.0, "<synthetic> is not a model");
    // Codex t1: 20k in·$10 + 80k cached·$1 + 1000 out·$50, then a 300k request at the long rate
    // (300k·$20 + 100·$75); the reviewer thread's codex-auto-review has no price.
    let want = (200_000.0 + 80_000.0 + 50_000.0 + 6_000_000.0 + 7_500.0) / 1e6;
    assert!((cost("t1") - want).abs() < 1e-9, "{} vs {want}", cost("t1"));
    let tokens: String = p.conn.query_row("SELECT tokens FROM turns WHERE id = 't1'", [], |r| r.get(0)).unwrap();
    assert!(tokens.contains("gpt-6-astra@long") && tokens.contains("codex-auto-review"), "the reviewer is counted, just not priced: {tokens}");

    let (c_pd1, c_t1) = (cost("pd1"), cost("t1"));
    let total = p.ctr("cost", "all");
    assert!((total - c_pd1 - c_t1).abs() < 1e-9);
    assert!((p.ctr("cost:codex", "all") - c_t1).abs() < 1e-9);
    assert_eq!(daemon::usage::fill(&mut p, &claude, &codex, i64::MAX, usize::MAX).unwrap(), 0, "each turn once");

    let day = daemon::report::day(&p.conn, tz, &Config::default(), &claude, chrono::NaiveDate::from_ymd_opt(2026, 10, 27).unwrap(), 1_793_200_000_000, false, None).unwrap();
    let lev = day["usd"].as_f64().unwrap() / total;
    assert!((day["leverage"].as_f64().unwrap() - lev).abs() < 1e-9, "economic leverage = $ of work / $ of model");
    assert!(day["character"]["sub"].as_str().unwrap().contains("模型花费"), "{}", day["character"]);
    let leaked: String = p.conn.query_row("SELECT group_concat(payload) FROM events WHERE kind = 'usage'", [], |r| r.get(0)).unwrap();
    assert!(!leaked.contains("login") && !leaked.contains("Login") && !leaked.contains("/tmp/demo"), "usage events carry counts only");
}
