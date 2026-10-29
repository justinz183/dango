//! Every achievement gets one "just unlocks" and one "just misses" sequence
//! (SPEC 16 M2 gate, 17.1). Sequences go through the real capture path:
//! Claude Code-shaped hook JSON → events → processor.

use std::sync::atomic::{AtomicUsize, Ordering};

use chrono::{FixedOffset, NaiveDateTime};
use daemon::capture::{from_claude_hook, CaptureEnv};
use daemon::config::Config;
use daemon::db;
use daemon::ingest::{Mode, Processor, Tz};
use daemon::paths::Paths;
use serde_json::{json, Value};
use dango_core::achievements::{Catalog, Store};
use dango_core::event::{Event, GitAction, Kind, Source};

static N: AtomicUsize = AtomicUsize::new(0);

struct Sim {
    p: Processor,
    paths: Paths,
    t: i64,
    sid: String,
    pid: String,
    n: usize,
}

const TZ: i32 = 8 * 3600;

impl Sim {
    fn new() -> Sim {
        let k = N.fetch_add(1, Ordering::SeqCst);
        let paths = Paths::at(std::env::temp_dir().join(format!("sc-ach-{}-{k}", std::process::id())));
        paths.ensure().unwrap();
        let p = Processor::new(db::open_memory().unwrap(), Mode::Live, Tz::Fixed(FixedOffset::east_opt(TZ).unwrap()), Config::default());
        let mut s = Sim { p, paths, t: 0, sid: String::new(), pid: String::new(), n: 0 };
        s.at("2026-10-26 10:00"); // a Monday
        s
    }

    fn at(&mut self, local: &str) -> &mut Self {
        let dt = NaiveDateTime::parse_from_str(local, "%Y-%m-%d %H:%M").unwrap();
        self.t = dt.and_local_timezone(FixedOffset::east_opt(TZ).unwrap()).unwrap().timestamp_millis();
        self
    }

    fn adv(&mut self, minutes: f64) -> &mut Self {
        self.t += (minutes * 60_000.0) as i64;
        self
    }

    fn send(&mut self, name: &str, extra: Value) {
        let mut v = json!({
            "hook_event_name": name, "session_id": self.sid, "prompt_id": self.pid,
            "cwd": "/w/repo", "permission_mode": "default",
        });
        for (k, x) in extra.as_object().unwrap() {
            v[k] = x.clone();
        }
        self.n += 1;
        let env = CaptureEnv { paths: &self.paths, now_ms: self.t, nonce: self.n.to_string(), git_lookup: false };
        if let Some(ev) = from_claude_hook(&v, b"", &env) {
            self.event(ev);
        }
    }

    fn event(&mut self, ev: Event) {
        self.p.begin().unwrap();
        self.p.handle(&ev).unwrap();
        self.p.commit().unwrap();
    }

    fn start_src(&mut self, src: &str) -> &mut Self {
        self.n += 1;
        self.sid = format!("s{}", self.n);
        self.send("SessionStart", json!({ "source": src }));
        self
    }

    fn start(&mut self) -> &mut Self {
        self.start_src("startup")
    }

    fn prompt(&mut self, text: &str) -> &mut Self {
        self.n += 1;
        self.pid = format!("p{}", self.n);
        self.send("UserPromptSubmit", json!({ "prompt": text }));
        self
    }

    fn edit(&mut self, path: &str, added: usize, removed: usize) -> &mut Self {
        let mut lines: Vec<String> = (0..added).map(|i| format!("+a{i}")).collect();
        lines.extend((0..removed).map(|i| format!("-r{i}")));
        let resp = json!({ "structuredPatch": [{ "lines": lines }] });
        let input = json!({ "file_path": format!("/w/repo/{path}"), "old_string": "o", "new_string": "n" });
        self.send("PostToolUse", json!({ "tool_name": "Edit", "tool_input": input, "tool_response": resp }));
        self
    }

    fn bash(&mut self, cmd: &str, ok: bool) -> &mut Self {
        let name = if ok { "PostToolUse" } else { "PostToolUseFailure" };
        self.send(name, json!({ "tool_name": "Bash", "tool_input": { "command": cmd } }));
        self
    }

    fn agent(&mut self) -> &mut Self {
        self.send("PostToolUse", json!({ "tool_name": "Agent", "tool_input": {} }));
        self
    }

    fn stop(&mut self) -> &mut Self {
        self.send("Stop", json!({ "stop_hook_active": false }));
        self
    }

    fn end(&mut self) -> &mut Self {
        self.send("SessionEnd", json!({ "reason": "other" }));
        self
    }

    /// A message injected mid-turn (task notification, queued input):
    /// Claude Code fires UserPromptSubmit again with the same prompt_id.
    fn inject(&mut self, text: &str) -> &mut Self {
        self.send("UserPromptSubmit", json!({ "prompt": text }));
        self
    }

    /// prompt → `minutes` of work → Stop.
    fn turn(&mut self, text: &str, minutes: f64) -> &mut Self {
        self.prompt(text).adv(minutes).stop()
    }

    /// A big turn: about 355 human minutes ≈ 0.74 person-days (17 edits of
    /// 75 lines, a test run, three agents and a commit).
    fn big_turn(&mut self) -> &mut Self {
        self.prompt("implement the whole thing");
        for i in 0..17 {
            self.edit(&format!("src/m{i}.rs"), 75, 0);
        }
        self.bash("cargo test", true).agent().agent().agent();
        self.bash("git commit -m done", true).adv(30.0).stop()
    }

    /// About 0.13 person-days (10 × 5.8 + 5 programmer minutes): enough
    /// to make a day active.
    fn medium_turn(&mut self) -> &mut Self {
        self.prompt("implement a form");
        for i in 0..10 {
            self.edit(&format!("src/f{i}.rs"), 12, 0);
        }
        self.adv(5.0).stop()
    }

    fn tier(&mut self, id: &str) -> u32 {
        self.p.unlocked_tier(id)
    }

    fn bump(&mut self, metric: &str, by: f64) -> &mut Self {
        self.p.begin().unwrap();
        self.p.add_ctr(metric, "all", by);
        self.p.commit().unwrap();
        self
    }

    /// Marks an achievement unlocked directly (for set tests).
    fn grant(&mut self, id: &str, tier: u32) -> &mut Self {
        self.p
            .conn
            .execute("INSERT OR IGNORE INTO unlocks (achievement_id, tier, unlocked_at) VALUES (?1, ?2, 0)", rusqlite::params![id, tier])
            .unwrap();
        self.p.forget_caches();
        self
    }

    fn other_source(&mut self, source: Source, kind: Kind) -> &mut Self {
        self.n += 1;
        // Codex arrives from its logs: a backfill event with Codex as origin.
        let from = if source == Source::Codex { Source::Backfill } else { source };
        let mut ev = Event::new(format!("x{}", self.n), self.t, from, kind);
        ev.payload.origin = (source == Source::Codex).then_some(Source::Codex);
        ev.session_id = Some(format!("{}-{}", source.as_str(), self.n));
        ev.payload.git_action = Some(GitAction::Commit);
        self.event(ev);
        self
    }
}

/// Counter milestones: one small turn short of the threshold, then over it.
fn milestone(id: &str, threshold: f64) {
    let mut s = Sim::new();
    s.start().bump("person_days", threshold - 0.5).turn("看看这个", 1.0);
    assert_eq!(s.tier(id), 0, "{id} near miss");
    s.big_turn();
    assert_eq!(s.tier(id), 1, "{id} unlock");
}

#[test]
fn m01_first_hire() {
    let mut s = Sim::new();
    s.start().big_turn();
    assert_eq!(s.tier("M01"), 0);
    s.big_turn();
    assert_eq!(s.tier("M01"), 1);
}

#[test]
fn m02_one_person_week() {
    let mut s = Sim::new();
    s.start();
    for _ in 0..6 {
        s.big_turn();
    }
    assert_eq!(s.tier("M02"), 0, "4.5 person-days");
    s.big_turn();
    assert_eq!(s.tier("M02"), 1);
}

#[test]
fn m03_to_m07_milestones() {
    milestone("M03", 22.0);
    milestone("M04", 100.0);
    milestone("M05", 250.0);
    milestone("M06", 1000.0);
    milestone("M07", 10000.0);
}

#[test]
fn l01_light_touch_needs_session_leverage() {
    let mut s = Sim::new();
    // Three video renders (3 × 15) + the 5-minute turn base = 50 human minutes.
    let cut = "ffmpeg -i a.mp4 b.mp4";
    s.start().prompt("cut the video").bash(cut, true).bash(cut, true).bash(cut, true).adv(11.0).stop().end();
    assert_eq!(s.tier("L01"), 0, "50 / 11 = 4.5x");
    s.start().prompt("cut the video").bash(cut, true).bash(cut, true).bash(cut, true).adv(10.0).stop().end();
    assert_eq!(s.tier("L01"), 1, "5x");
    s.start().prompt("cut the video").bash(cut, true).bash(cut, true).bash(cut, true).adv(5.0).stop().end();
    assert_eq!(s.tier("L01"), 2, "10x");
}

#[test]
fn l02_hands_off() {
    let mut s = Sim::new();
    s.start().turn("implement x", 14.0);
    assert_eq!(s.tier("L02"), 0);
    s.turn("implement x", 15.0);
    assert_eq!(s.tier("L02"), 1);
    s.turn("implement x", 60.0);
    assert_eq!(s.tier("L02"), 3);
}

#[test]
fn l03_first_try_resets_on_correction() {
    let mut s = Sim::new();
    s.start();
    for _ in 0..4 {
        s.turn("implement x", 1.0);
    }
    s.turn("不对，换个做法", 1.0); // reset, then this turn counts 1
    for _ in 0..3 {
        s.turn("implement x", 1.0);
    }
    assert_eq!(s.tier("L03"), 0, "streak 4");
    s.turn("implement x", 1.0);
    assert_eq!(s.tier("L03"), 1);
}

#[test]
fn l04_combo_is_per_session() {
    let mut s = Sim::new();
    s.start();
    for _ in 0..4 {
        s.turn("implement x", 1.0);
    }
    s.start();
    for _ in 0..4 {
        s.turn("implement x", 1.0);
    }
    assert_eq!(s.tier("L04"), 0, "4 in this session");
    assert_eq!(s.tier("L03"), 1, "8 overall");
    s.turn("implement x", 1.0);
    assert_eq!(s.tier("L04"), 1);
}

#[test]
fn l05_commander() {
    let mut s = Sim::new();
    s.start().prompt("research options").agent().agent().adv(2.0).stop();
    assert_eq!(s.tier("L05"), 0);
    s.prompt("research more").agent().adv(2.0).stop();
    assert_eq!(s.tier("L05"), 1);
}

#[test]
fn t01_night_owl() {
    let mut s = Sim::new();
    s.at("2026-10-27 05:10").start();
    assert_eq!(s.tier("T01"), 0);
    s.at("2026-10-28 04:59").start();
    assert_eq!(s.tier("T01"), 1);
}

#[test]
fn t02_early_bird() {
    let mut s = Sim::new();
    s.at("2026-10-27 06:00").start();
    assert_eq!(s.tier("T02"), 0);
    s.at("2026-10-28 05:30").start();
    assert_eq!(s.tier("T02"), 1);
}

#[test]
fn t03_weekend_warrior_counts_new_sessions_only() {
    let mut s = Sim::new();
    s.at("2026-10-31 10:00");
    for _ in 0..4 {
        s.start();
    }
    s.start_src("resume").start_src("compact");
    assert_eq!(s.tier("T03"), 0);
    s.start();
    assert_eq!(s.tier("T03"), 1);
}

#[test]
fn t04_in_one_go() {
    let mut s = Sim::new();
    s.start().turn("implement x", 179.0);
    assert_eq!(s.tier("T04"), 0);
    s.adv(1.0).turn("implement y", 1.0);
    assert_eq!(s.tier("T04"), 1, "179 + 1 gap + 1");
}

#[test]
fn t05_marathon() {
    let mut s = Sim::new();
    s.start().turn("implement x", 359.0);
    assert_eq!(s.tier("T05"), 0);
    s.adv(1.0).turn("implement y", 1.0);
    assert_eq!(s.tier("T05"), 1);
}

#[test]
fn t06_first_merge() {
    let mut s = Sim::new();
    s.start().prompt("ship it").bash("git status", true).bash("git commit -m x", false);
    assert_eq!(s.tier("T06"), 0);
    s.bash("git commit -m x", true);
    assert_eq!(s.tier("T06"), 1);
}

#[test]
fn t07_green_light_needs_first_run_pass() {
    let mut s = Sim::new();
    s.start().prompt("fix it").bash("npm test", false).bash("npm test", true).stop();
    assert_eq!(s.tier("T07"), 0);
    s.prompt("add tests").bash("npm test", true).stop();
    assert_eq!(s.tier("T07"), 1);
}

#[test]
fn s01_sweeper() {
    let mut s = Sim::new();
    s.start().prompt("clean up").edit("old.rs", 0, 499).stop();
    assert_eq!(s.tier("S01"), 0);
    s.prompt("clean up").edit("old.rs", 0, 1).stop();
    assert_eq!(s.tier("S01"), 1);
}

#[test]
fn s02_archaeologist() {
    let mut s = Sim::new();
    s.start().prompt("fix the legacy parser");
    let tool = |s: &mut Sim, age: u32| {
        s.n += 1;
        let mut ev = Event::new(format!("age{}", s.n), s.t, Source::ClaudeCode, Kind::Tool);
        ev.session_id = Some(s.sid.clone());
        ev.turn_id = Some(s.pid.clone());
        ev.payload.files_touched = Some(1);
        ev.payload.file_ids = vec![format!("f{age}")];
        ev.payload.file_ages_days_max = Some(age);
        s.event(ev);
    };
    tool(&mut s, 1094);
    s.stop();
    assert_eq!(s.tier("S02"), 0);
    s.prompt("fix again");
    tool(&mut s, 1095);
    s.stop();
    assert_eq!(s.tier("S02"), 1);
}

#[test]
fn s03_polyglot_ignores_prose() {
    let mut s = Sim::new();
    s.start().prompt("implement").edit("a.rs", 1, 0).edit("b.py", 1, 0).edit("c.go", 1, 0).edit("d.ts", 1, 0).edit("README.md", 1, 0).edit("x.json", 1, 0).stop();
    assert_eq!(s.tier("S03"), 0);
    s.prompt("implement").edit("e.swift", 1, 0).stop();
    assert_eq!(s.tier("S03"), 1);
}

#[test]
fn s04_bomb_squad() {
    let mut s = Sim::new();
    s.start().prompt("fix").bash("cargo test", false).stop();
    assert_eq!(s.tier("S04"), 0);
    s.prompt("fix").bash("cargo test", true).stop();
    assert_eq!(s.tier("S04"), 1, "fail → pass across turns");
}

#[test]
fn s05_gatekeeper() {
    let mut s = Sim::new();
    s.start();
    for _ in 0..9 {
        s.turn("错了，重新来", 1.0);
    }
    assert_eq!(s.tier("S05"), 0);
    s.turn("wrong file", 1.0);
    assert_eq!(s.tier("S05"), 1);
}

#[test]
fn s06_demolition_crew() {
    let mut s = Sim::new();
    s.start().prompt("rename everywhere");
    for i in 0..49 {
        s.edit(&format!("f{i}.rs"), 1, 1);
    }
    s.stop();
    assert_eq!(s.tier("S06"), 0);
    s.prompt("one more").edit("last.rs", 1, 1).stop();
    assert_eq!(s.tier("S06"), 1);
}

#[test]
fn s07_surgeon() {
    let mut s = Sim::new();
    s.start();
    for _ in 0..9 {
        s.prompt("fix").edit("a.rs", 2, 2).bash("cargo test", true).stop();
    }
    s.prompt("fix").edit("a.rs", 6, 0).bash("cargo test", true).stop();
    assert_eq!(s.tier("S07"), 0, "6 lines is not surgery");
    s.prompt("fix").edit("a.rs", 1, 1).bash("cargo test", true).stop();
    assert_eq!(s.tier("S07"), 1);
}

#[test]
fn s08_doc_lover() {
    let mut s = Sim::new();
    s.start();
    for _ in 0..19 {
        s.turn("更新文档", 1.0);
    }
    assert_eq!(s.tier("S08"), 0);
    s.turn("update the docs", 1.0);
    assert_eq!(s.tier("S08"), 1);
}

#[test]
fn c01_habit_skips_weekends() {
    let mut s = Sim::new();
    for d in ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-02"] {
        s.at(&format!("{d} 10:00")).start().medium_turn();
    }
    assert_eq!(s.tier("C01"), 0, "6 weekdays + a Saturday");
    s.at("2026-11-03 10:00").start().medium_turn();
    assert_eq!(s.tier("C01"), 1);
}

#[test]
fn c02_unplugged_gives_a_freeze_token() {
    let mut s = Sim::new();
    s.at("2026-10-23 10:00").start().medium_turn(); // Friday
    s.at("2026-10-24 10:00").start(); // Saturday session
    s.at("2026-10-26 10:00").start().medium_turn();
    assert_eq!(s.tier("C02"), 0, "a session on Saturday");
    s.at("2026-11-02 10:00").start().medium_turn();
    assert_eq!(s.tier("C02"), 1, "quiet weekend before this Monday");
    let tokens: i64 = s.p.conn.query_row("SELECT freeze_tokens FROM wallet", [], |r| r.get(0)).unwrap();
    assert_eq!(tokens, 1);
}

#[test]
fn c03_deep_breath() {
    for (day2_turns, want) in [(5, 0), (6, 1)] {
        let mut s = Sim::new();
        s.at("2026-10-26 09:00").start();
        for _ in 0..8 {
            s.big_turn(); // 8 × 0.74 ≈ 5.9 person-days
        }
        s.at("2026-10-27 09:00").start();
        for _ in 0..day2_turns {
            s.big_turn();
        }
        s.at("2026-11-02 09:00").start().turn("看看", 1.0);
        assert_eq!(s.tier("C03"), want, "day 2 turns {day2_turns}");
    }
}

#[test]
fn c04_welcome_back() {
    let mut s = Sim::new();
    s.at("2026-10-26 10:00").start().medium_turn();
    s.at("2026-11-08 10:00").start();
    assert_eq!(s.tier("C04"), 0, "13 days");
    s.at("2026-11-09 10:00").start();
    assert_eq!(s.tier("C04"), 1);
}

#[test]
fn x01_dual_wield() {
    let mut s = Sim::new();
    s.start().turn("implement", 1.0);
    s.adv(24.0 * 60.0).other_source(Source::Codex, Kind::Commit);
    assert_eq!(s.tier("X01"), 0, "Codex on another day");
    s.turn("implement", 1.0);
    assert_eq!(s.tier("X01"), 1);
}

#[test]
fn x02_trident() {
    let mut s = Sim::new();
    s.start().turn("implement", 1.0).other_source(Source::Codex, Kind::Commit);
    assert_eq!(s.tier("X02"), 0);
    s.other_source(Source::Git, Kind::Commit);
    assert_eq!(s.tier("X02"), 1);
}

#[test]
fn x03_to_x07_social_counters() {
    // Fed by later milestones (cards, friends, beta install); the engine side
    // is just a counter.
    for (id, metric, threshold) in
        [("X03", "cards_exported", 1.0), ("X04", "friends", 1.0), ("X05", "board_wins", 1.0), ("X06", "gifts_sent", 1.0), ("X07", "early_bird", 1.0)]
    {
        let mut s = Sim::new();
        s.start().bump(metric, threshold - 1.0).turn("看看", 1.0);
        assert_eq!(s.tier(id), 0, "{id}");
        s.bump(metric, 1.0).turn("看看", 1.0);
        assert_eq!(s.tier(id), 1, "{id}");
    }
}

#[test]
fn h01_four_am_commit() {
    let mut s = Sim::new();
    s.at("2026-10-27 05:00").start().prompt("ship").bash("git commit -m x", true);
    assert_eq!(s.tier("H01"), 0);
    s.at("2026-10-28 04:30").prompt("ship").bash("git commit -m y", true);
    assert_eq!(s.tier("H01"), 1);
}

#[test]
fn h02_second_thoughts() {
    let mut s = Sim::new();
    s.start().prompt("implement").edit("old.rs", 150, 0).stop();
    s.adv(8.0 * 24.0 * 60.0).prompt("redo").edit("old.rs", 0, 120).stop();
    assert_eq!(s.tier("H02"), 0, "written more than 7 days ago");
    s.prompt("implement").edit("new.rs", 150, 0).stop();
    s.prompt("redo").edit("new.rs", 0, 99).stop();
    assert_eq!(s.tier("H02"), 0, "99 lines");
    s.prompt("implement").edit("third.rs", 150, 0).stop();
    s.prompt("redo").edit("third.rs", 0, 100).stop();
    assert_eq!(s.tier("H02"), 1);
}

#[test]
fn h03_one_more_time() {
    let mut s = Sim::new();
    s.start().turn("继续", 1.0).turn("继续", 1.0).turn("别的", 1.0).turn("继续", 1.0).turn("继续", 1.0);
    assert_eq!(s.tier("H03"), 0);
    s.turn("继续", 1.0);
    assert_eq!(s.tier("H03"), 1);
}

#[test]
fn h04_new_years_eve() {
    let mut s = Sim::new();
    s.at("2026-12-31 22:59").start();
    s.at("2027-01-01 01:00").prompt("happy new year");
    assert_eq!(s.tier("H04"), 0);
    s.at("2026-12-31 23:01").prompt("one more");
    assert_eq!(s.tier("H04"), 1);
}

#[test]
fn h05_april_fools() {
    let mut s = Sim::new();
    s.at("2027-03-31 23:59").start();
    assert_eq!(s.tier("H05"), 0);
    s.at("2027-04-01 00:01").prompt("fix it");
    assert_eq!(s.tier("H05"), 1);
}

#[test]
fn h06_one_line_fix() {
    let mut s = Sim::new();
    s.start().prompt("fix").bash("cargo test", false).edit("a.rs", 2, 1).bash("cargo test", true).stop();
    assert_eq!(s.tier("H06"), 0, "two lines added");
    s.prompt("fix").bash("cargo test", false).edit("a.rs", 1, 1).bash("cargo test", true).stop();
    assert_eq!(s.tier("H06"), 1);
}

#[test]
fn h07_one_year_together() {
    let mut s = Sim::new();
    s.at("2026-10-26 10:00").start().turn("hi", 1.0);
    s.at("2027-10-25 10:00").start().turn("hi", 1.0);
    assert_eq!(s.tier("H07"), 0, "364 days");
    s.at("2027-10-26 10:00").start().turn("hi", 1.0);
    assert_eq!(s.tier("H07"), 1);
}

#[test]
fn h08_all_hands() {
    let mut s = Sim::new();
    s.start().turn("hi", 1.0);
    assert_eq!(s.tier("H08"), 0, "1 turn, 1 employee");
    s.turn("hi", 1.0);
    assert_eq!(s.tier("H08"), 1);
}

#[test]
fn h09_low_profile() {
    let days = ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-11-02", "2026-11-03"];
    let mut s = Sim::new();
    for d in &days[..6] {
        s.at(&format!("{d} 10:00")).start().medium_turn();
    }
    assert_eq!(s.tier("H09"), 0, "streak 6");
    s.at(&format!("{} 10:00", days[6])).start().medium_turn();
    assert_eq!(s.tier("H09"), 1);

    // Same week, but a stage-up (a grand ceremony) on day 5.
    let mut s = Sim::new();
    for (i, d) in days.iter().enumerate() {
        if i == 4 {
            let have = s.p.ctr("person_days", "all");
            s.bump("person_days", 21.9 - have);
        }
        s.at(&format!("{d} 10:00")).start().medium_turn();
    }
    assert_eq!(s.tier("H09"), 0, "grand ceremony 4 days ago");
}

/// One turn per file path, each pointing at a different role card.
fn role_turn(s: &mut Sim, prompt: &str, files: &[&str]) {
    s.prompt(prompt);
    for f in files {
        s.edit(f, 1, 0);
    }
    s.stop();
}

const ELEVEN_ROLES: [(&str, &[&str]); 11] = [
    ("implement", &["web/App.tsx"]),
    ("implement", &["api/main.go"]),
    ("implement", &["db/q.sql"]),
    ("implement", &["Dockerfile"]),
    ("implement", &["tests/a.test.ts"]),
    ("implement", &["NOTES.md"]),
    ("implement", &["auth/token.go"]),
    ("implement", &["eda.ipynb"]),
    ("implement", &["ios/View.swift"]),
    ("implement", &["a/x.go", "b/y.go", "c/z.go"]),
    ("research the options", &[]),
];

#[test]
fn p01_generalist() {
    let mut s = Sim::new();
    s.start();
    for (p, f) in &ELEVEN_ROLES[..5] {
        role_turn(&mut s, p, f);
    }
    assert_eq!(s.tier("P01"), 0);
    role_turn(&mut s, ELEVEN_ROLES[5].0, ELEVEN_ROLES[5].1);
    assert_eq!(s.tier("P01"), 1);
}

#[test]
fn p02_full_stack() {
    let mut s = Sim::new();
    s.start();
    for (p, f) in &ELEVEN_ROLES {
        role_turn(&mut s, p, f);
    }
    assert_eq!(s.tier("P02"), 0, "11 roles");
    role_turn(&mut s, "implement", &["scripts/train_model.py"]);
    assert_eq!(s.tier("P02"), 1);
}

#[test]
fn p03_master_key() {
    let mut s = Sim::new();
    s.start();
    for r in Catalog::builtin().role_cards.iter() {
        s.bump(&format!("role:{}", r.id), 49.0);
    }
    for (p, f) in &ELEVEN_ROLES {
        role_turn(&mut s, p, f);
    }
    assert_eq!(s.tier("P03"), 0);
    role_turn(&mut s, "implement", &["scripts/train_model.py"]);
    assert_eq!(s.tier("P03"), 1);
}

#[test]
fn p04_night_shift() {
    let mut s = Sim::new();
    s.grant("T04", 1).grant("T05", 1).grant("H01", 1);
    s.start().turn("hi", 1.0);
    assert_eq!(s.tier("P04"), 0);
    s.at("2026-10-27 04:00").start();
    assert_eq!(s.tier("T01"), 1);
    assert_eq!(s.tier("P04"), 1);
}

#[test]
fn p05_rhythm_master() {
    let mut s = Sim::new();
    s.grant("C01", 2).grant("C02", 1).grant("C03", 1);
    s.start().turn("hi", 1.0);
    assert_eq!(s.tier("P05"), 0, "Habit II only");
    s.grant("C01", 3).turn("hi", 1.0);
    assert_eq!(s.tier("P05"), 1);
}

#[test]
fn p06_collector() {
    let ids: Vec<String> = Catalog::builtin()
        .achievements
        .iter()
        .filter(|a| !a.id.starts_with('P') && !["H08", "M01"].contains(&a.id.as_str()))
        .map(|a| a.id.clone())
        .collect();
    let mut s = Sim::new();
    for id in &ids[..29] {
        s.grant(id, 1);
    }
    s.start().turn("config env", 1.0);
    assert_eq!(s.tier("P06"), 0, "29 unlocked");
    s.grant(&ids[29], 1).turn("config env", 1.0);
    assert_eq!(s.tier("P06"), 1);
}

#[test]
fn mid_turn_prompt_keeps_the_turn_and_its_box() {
    let mut s = Sim::new();
    s.start().prompt("Yes, register it").edit("a.rs", 10, 0).adv(1.0);
    s.inject("<task-notification>background command failed</task-notification>");
    s.edit("b.rs", 5, 0).adv(1.0).stop();
    let sid = s.sid.clone();
    let summary = s.p.settlements.remove(&sid).expect("Stop must produce a box");
    assert_eq!(summary.files, 2, "both edits belong to the one turn");
    let ended: i64 = s.p.conn.query_row("SELECT COUNT(*) FROM turns WHERE ended_at IS NOT NULL", [], |r| r.get(0)).unwrap();
    assert_eq!(ended, 1);
}

#[test]
fn reused_prompt_id_after_stop_starts_a_fresh_turn() {
    let mut s = Sim::new();
    s.start().prompt("implement x").edit("a.rs", 3, 0).stop();
    s.p.settlements.clear();
    // The agent is woken again (e.g. by a background task) under the same id.
    s.adv(1.0).inject("<task-notification>done</task-notification>").edit("c.rs", 4, 0).adv(1.0).stop();
    let sid = s.sid.clone();
    assert!(s.p.settlements.remove(&sid).is_some(), "the second Stop gets a box too");
    let ended: i64 = s.p.conn.query_row("SELECT COUNT(*) FROM turns WHERE ended_at IS NOT NULL", [], |r| r.get(0)).unwrap();
    assert_eq!(ended, 2);
}

#[test]
fn every_catalog_entry_has_a_test_here() {
    let src = include_str!("achievements.rs").to_lowercase();
    for a in &Catalog::builtin().achievements {
        let id = a.id.to_lowercase();
        let covered = src.contains(&format!("fn {id}_"))
            || src.contains(&format!("\"{}\"", a.id).to_lowercase());
        assert!(covered, "{} has no test", a.id);
    }
}

#[test]
fn turns_are_priced_by_who_would_have_done_them() {
    let mut s = Sim::new();
    s.start().prompt("把这段视频剪一下").bash("ffmpeg -i a.mp4 b.mp4", true).bash("ffmpeg -i b.mp4 c.mp4", true).adv(3.0).stop();
    let sid = s.sid.clone();
    let b = s.p.settlements.remove(&sid).expect("a box");
    assert_eq!(b.jobs, vec!["视频剪辑".to_string()]);
    // 2 × 15 minutes of editing + the 5-minute turn base, at $36.26/h.
    assert!((b.usd - 35.0 / 60.0 * 36.26).abs() < 1e-9, "{}", b.usd);
    assert!((b.today_usd - b.usd).abs() < 1e-9);
    // A tool result that lands after Stop adds to the same turn.
    let before = s.p.ctr("usd", "all");
    s.adv(0.1).bash("ffmpeg -i c.mp4 d.mp4", true);
    let after = s.p.ctr("usd", "all");
    assert!((after - before - 15.0 / 60.0 * 36.26).abs() < 1e-9, "{before} → {after}");
    let (usd, work): (f64, String) = s.p.conn.query_row("SELECT usd, work FROM turns", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert!((usd - after).abs() < 1e-9 && work.contains("\"video\":50"), "{work}");
}
