//! Reports (DESIGN.md §5): what your Claude did on a day, as the numbers,
//! the timeline, the kinds of work, and the character's mood and lines.
//! Everything comes from turns, sessions and daily; names come from
//! session_meta and only leave this machine when `show_names` is set.

use std::collections::HashMap;
use std::path::Path;

use chrono::{Datelike, NaiveDate, Timelike};
use rusqlite::Connection;
use serde_json::{json, Value};
use shadowcorp_core::event::TaskClass;
use shadowcorp_core::render::{fmt_int, fmt_short};
use shadowcorp_core::scoring::{leverage, ACTIVE_GAP_MINUTES, LEVERAGE_MIN_ACTIVE};
use shadowcorp_core::value::Category;

use crate::config::Config;
use crate::ingest::{day_key, Result, Tz};
use crate::snapshot;
use crate::titles;

const MIN: f64 = 60_000.0;
const WEEKDAYS: [&str; 7] = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"];

struct Turn {
    session: String,
    start: i64,
    end: i64,
    class: TaskClass,
    files: i64,
    test_run: bool,
    test_passed: bool,
    correction: bool,
    human_minutes: f64,
}

#[derive(Default)]
struct Sess {
    start: i64,
    end: i64,
    turns: usize,
    human: f64,
    active: f64,
    last_end: Option<i64>,
    by_cat: HashMap<Category, f64>,
}

fn hhmm(tz: Tz, ms: i64) -> String {
    let t = tz.local(ms);
    format!("{:02}:{:02}", t.hour(), t.minute())
}

fn hours(minutes: f64) -> f64 {
    (minutes / 60.0 * 10.0).round() / 10.0
}

/// The character's mood and words for a day (DESIGN.md §2).
fn character(name: &str, human_h: f64, active_h: f64, lev: Option<f64>, turns: usize, night: usize, tests_run: usize, tests_passed: usize, corrections: usize, best: Option<&str>) -> Value {
    let (mood, signoff) = if turns == 0 {
        ("waiting", "今天没开工，我在等你。".to_string())
    } else if human_h >= 16.0 {
        ("proud", format!("今天顶一个人干两天，{turns} 个回合。"))
    } else if night > 0 {
        ("sleepy", format!("凌晨那 {night} 个回合，我记着。"))
    } else if tests_run >= 3 && tests_passed == tests_run {
        ("happy", format!("{tests_run} 次测试全绿，手感不错。"))
    } else if corrections >= 5 {
        ("focused", format!("你把关了 {corrections} 次，都改好了。"))
    } else if let Some(b) = best {
        ("happy", format!("今天最长的一段在「{b}」。"))
    } else {
        ("happy", format!("{turns} 个回合，{} 小时的活。", fmt_short(human_h)))
    };
    let headline = if turns == 0 { "今天没开工".to_string() } else { "我替你干了".to_string() };
    let number = if turns == 0 { String::new() } else { format!("{} 小时", fmt_short(human_h)) };
    let sub = if turns == 0 {
        "休息也是节奏的一部分。".to_string()
    } else {
        let you = if active_h < 1.0 { format!("{} 分钟", (active_h * 60.0).round()) } else { format!("{} 小时", fmt_short(active_h)) };
        match lev {
            Some(l) => format!("你花了 {you} · 杠杆 {l:.1}x"),
            None => format!("你花了 {you}"),
        }
    };
    json!({ "name": name, "mood": mood, "headline": headline, "number": number, "sub": sub, "signoff": signoff })
}

/// The report for one local day.
pub fn day(conn: &Connection, tz: Tz, cfg: &Config, claude_dir: &Path, date: NaiveDate, now: i64, show_names: bool) -> Result<Value> {
    let start = tz.ms(date.and_hms_opt(0, 0, 0).unwrap());
    let end = tz.ms(date.succ_opt().unwrap().and_hms_opt(0, 0, 0).unwrap());

    let mut st = conn.prepare(
        "SELECT session_id, started_at, ended_at, task_class, files_touched, test_run, test_passed, is_correction, human_minutes
         FROM turns WHERE ended_at >= ?1 AND ended_at < ?2 ORDER BY started_at",
    )?;
    let turns: Vec<Turn> = st
        .query_map([start, end], |r| {
            Ok(Turn {
                session: r.get(0)?,
                start: r.get(1)?,
                end: r.get(2)?,
                class: TaskClass::parse(&r.get::<_, String>(3)?).unwrap_or(TaskClass::Other),
                files: r.get(4)?,
                test_run: r.get::<_, i64>(5)? == 1,
                test_passed: r.get::<_, Option<i64>>(6)? == Some(1),
                correction: r.get::<_, i64>(7)? == 1,
                human_minutes: r.get(8)?,
            })
        })?
        .flatten()
        .collect();

    let mut sessions: HashMap<String, Sess> = HashMap::new();
    let mut by_cat: HashMap<Category, f64> = HashMap::new();
    let mut blocks = Vec::new();
    let (mut files, mut tests_run, mut tests_passed, mut corrections, mut night, mut human) = (0, 0, 0, 0, 0, 0.0);
    for t in &turns {
        let cat = Category::of(t.class);
        let s = sessions.entry(t.session.clone()).or_insert_with(|| Sess { start: t.start, end: t.end, ..Default::default() });
        s.start = s.start.min(t.start);
        s.end = s.end.max(t.end);
        s.turns += 1;
        s.human += t.human_minutes;
        *s.by_cat.entry(cat).or_default() += t.human_minutes;
        let gap = s.last_end.map(|e| (t.start - e) as f64 / MIN).filter(|g| *g > 0.0 && *g < ACTIVE_GAP_MINUTES).unwrap_or(0.0);
        s.active += (t.end - t.start) as f64 / MIN + gap;
        s.last_end = Some(t.end);
        *by_cat.entry(cat).or_default() += t.human_minutes;
        human += t.human_minutes;
        files += t.files;
        if t.test_run {
            tests_run += 1;
            tests_passed += t.test_passed as usize;
        }
        corrections += t.correction as usize;
        if tz.local(t.end).hour() < 5 {
            night += 1;
        }
        let from = ((t.start.max(start) - start) as f64 / MIN).floor() as i64;
        let to = ((t.end.min(end) - start) as f64 / MIN).ceil().max(from as f64 + 1.0) as i64;
        blocks.push(json!({ "from_min": from, "to_min": to, "category": cat.as_str(), "color": cat.color() }));
    }
    let active: f64 = sessions.values().map(|s| s.active).sum();
    let lev = leverage(human, active).filter(|_| active >= LEVERAGE_MIN_ACTIVE);

    let mut list: Vec<(String, Sess)> = sessions.into_iter().collect();
    list.sort_by(|a, b| b.1.human.partial_cmp(&a.1.human).unwrap());
    let mut session_rows = Vec::new();
    for (i, (sid, s)) in list.iter().enumerate() {
        let ended: Option<i64> = conn.query_row("SELECT ended_at FROM sessions WHERE id = ?1", [sid], |r| r.get(0)).unwrap_or(None);
        let meta = titles::cached(conn, claude_dir, sid, ended.is_some())?;
        let top = s.by_cat.iter().max_by(|a, b| a.1.partial_cmp(b.1).unwrap()).map(|(c, _)| *c).unwrap_or(Category::Other);
        let fallback = format!("会话 {}", i + 1);
        session_rows.push(json!({
            "from": hhmm(tz, s.start.max(start)),
            "to": hhmm(tz, s.end.min(end - 1)),
            "hours": hours(s.human),
            "turns": s.turns,
            "category": top.as_str(),
            "color": top.color(),
            "title": if show_names { meta.title.clone().unwrap_or(fallback.clone()) } else { fallback.clone() },
            "project": if show_names { meta.project.clone() } else { None },
            "has_title": meta.title.is_some(),
        }));
    }
    let best = session_rows.first().and_then(|s| s["has_title"].as_bool().unwrap_or(false).then(|| s["title"].as_str().unwrap_or("").to_string()));

    let cats: Vec<Value> = Category::ALL
        .iter()
        .map(|c| {
            let m = by_cat.get(c).copied().unwrap_or(0.0);
            json!({ "category": c.as_str(), "name": c.name_zh(), "tagline": c.tagline(), "color": c.color(),
                    "hours": hours(m), "share": if human > 0.0 { m / human } else { 0.0 } })
        })
        .collect();

    let o = snapshot::output(conn, tz, cfg, now);
    let streak: Value = crate::db::get_meta(conn, "streak")?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null);
    let name = cfg.character.name.clone();
    let active_h = active / 60.0;
    let human_h = human / 60.0;
    Ok(json!({
        "kind": "day",
        "date": day_key(date),
        "label": format!("{}月{}日 · {}", date.month(), date.day(), WEEKDAYS[date.weekday().num_days_from_monday() as usize]),
        "show_names": show_names,
        "character": character(&name, human_h, active_h, lev, turns.len(), night, tests_run, tests_passed, corrections, best.as_deref()),
        "human_hours": hours(human),
        "active_hours": hours(active),
        "leverage": lev,
        "turns": turns.len(),
        "clean_turns": turns.len() - corrections,
        "files": files,
        "tests_run": tests_run,
        "tests_passed": tests_passed,
        "night_turns": night,
        "usd": (cfg.value.hourly_rate_usd > 0.0).then(|| human_h * cfg.value.hourly_rate_usd),
        "categories": cats,
        "sessions": session_rows,
        "blocks": blocks,
        "rank": {
            "label": o.rank.label(), "xp": o.rank.xp, "progress": o.rank.progress, "color": o.rank.rank().color,
            "xp_to_next": o.rank.xp_to_next(), "next_label": o.rank.next_label(),
        },
        "streak": streak.get("current").cloned().unwrap_or(json!(0)),
    }))
}

/// A plain-text version of the day report for the terminal.
pub fn day_text(r: &Value) -> String {
    let c = &r["character"];
    let mut out = vec![format!("{}  {}", r["label"].as_str().unwrap_or(""), c["name"].as_str().unwrap_or("")), "─".repeat(44)];
    out.push(format!("{}{}", c["headline"].as_str().unwrap_or(""), c["number"].as_str().map(|n| format!(" {n} 的活")).unwrap_or_default()));
    out.push(c["sub"].as_str().unwrap_or("").to_string());
    out.push(String::new());
    for s in r["sessions"].as_array().into_iter().flatten() {
        let proj = s["project"].as_str().map(|p| format!("{p} · ")).unwrap_or_default();
        out.push(format!("  {}–{}  {}{}  {}h", s["from"].as_str().unwrap_or(""), s["to"].as_str().unwrap_or(""), proj, s["title"].as_str().unwrap_or(""), s["hours"]));
    }
    out.push(String::new());
    for cat in r["categories"].as_array().into_iter().flatten() {
        if cat["hours"].as_f64().unwrap_or(0.0) > 0.0 {
            out.push(format!("  {}  {}h · {:.0}%", cat["name"].as_str().unwrap_or(""), cat["hours"], cat["share"].as_f64().unwrap_or(0.0) * 100.0));
        }
    }
    out.push(String::new());
    out.push(format!(
        "  回合 {} · 文件 {} · 测试 {}/{} · 一次过 {}/{}",
        r["turns"], r["files"], r["tests_passed"], r["tests_run"], r["clean_turns"], r["turns"]
    ));
    out.push(format!("  {} · {} XP", r["rank"]["label"].as_str().unwrap_or(""), fmt_int(r["rank"]["xp"].as_i64().unwrap_or(0))));
    out.push(format!("「{}」", c["signoff"].as_str().unwrap_or("")));
    out.join("\n")
}
