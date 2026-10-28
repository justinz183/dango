//! Reports (DESIGN.md §5): what your Claude did over a day, a week or a
//! month — what it would have cost to hire people for it and who, when it
//! happened, the sessions, and the character's mood and lines. Everything
//! comes from turns and sessions; names come from session_meta and only
//! appear when `show_names` is set.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use chrono::{Datelike, Duration, NaiveDate, Timelike};
use rusqlite::Connection;
use serde_json::{json, Value};
use shadowcorp_core::occupation::{self, Table};
use shadowcorp_core::rank::{standing, xp_from_pd};
use shadowcorp_core::render::{fmt_int, fmt_short, fmt_usd};
use shadowcorp_core::scoring::{leverage, ScoringConstants, ACTIVE_GAP_MINUTES, LEVERAGE_MIN_ACTIVE};

use crate::config::Config;
use crate::ingest::{day_key, week_key, Result, Tz};
use crate::snapshot;
use crate::titles;

const MIN: f64 = 60_000.0;
const WEEKDAYS: [&str; 7] = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"];
const WEEKDAYS_SHORT: [&str; 7] = ["一", "二", "三", "四", "五", "六", "日"];

struct Turn {
    session: String,
    start: i64,
    end: i64,
    files: i64,
    test_run: bool,
    test_passed: bool,
    correction: bool,
    /// Credited minutes per occupation, their sum, and their price.
    work: BTreeMap<String, f64>,
    human_minutes: f64,
    usd: f64,
}

impl Turn {
    fn job(&self) -> String {
        occupation::main(&self.work).unwrap_or_default()
    }
}

fn color(job: &str) -> Option<&'static str> {
    Table::builtin().get(job).map(|j| j.color.as_str())
}

#[derive(Default)]
struct Sess {
    start: i64,
    end: i64,
    turns: usize,
    human: f64,
    usd: f64,
    active: f64,
    last_end: Option<i64>,
    by_job: BTreeMap<String, f64>,
}

/// Everything a period's turns add up to.
#[derive(Default)]
struct Tally {
    turns: Vec<Turn>,
    sessions: HashMap<String, Sess>,
    by_job: BTreeMap<String, f64>,
    human: f64,
    usd: f64,
    active: f64,
    files: i64,
    tests_run: usize,
    tests_passed: usize,
    corrections: usize,
    night: usize,
}

fn hhmm(tz: Tz, ms: i64) -> String {
    let t = tz.local(ms);
    format!("{:02}:{:02}", t.hour(), t.minute())
}

fn md(d: NaiveDate) -> String {
    format!("{}/{}", d.month(), d.day())
}

fn hours(minutes: f64) -> f64 {
    (minutes / 60.0 * 10.0).round() / 10.0
}

fn midnight(tz: Tz, d: NaiveDate) -> i64 {
    tz.ms(d.and_hms_opt(0, 0, 0).unwrap())
}

fn tally(conn: &Connection, tz: Tz, start: i64, end: i64) -> Result<Tally> {
    let mut st = conn.prepare(
        "SELECT session_id, started_at, ended_at, files_touched, test_run, test_passed, is_correction, work, usd
         FROM turns WHERE ended_at >= ?1 AND ended_at < ?2 ORDER BY started_at",
    )?;
    let turns: Vec<Turn> = st
        .query_map([start, end], |r| {
            let work = crate::widget::work_of(&r.get::<_, String>(7)?);
            Ok(Turn {
                session: r.get(0)?,
                start: r.get(1)?,
                end: r.get(2)?,
                files: r.get(3)?,
                test_run: r.get::<_, i64>(4)? == 1,
                test_passed: r.get::<_, Option<i64>>(5)? == Some(1),
                correction: r.get::<_, i64>(6)? == 1,
                human_minutes: work.values().sum(),
                work,
                usd: r.get(8)?,
            })
        })?
        .flatten()
        .collect();
    let mut t = Tally::default();
    for x in &turns {
        let s = t.sessions.entry(x.session.clone()).or_insert_with(|| Sess { start: x.start, end: x.end, ..Default::default() });
        s.start = s.start.min(x.start);
        s.end = s.end.max(x.end);
        s.turns += 1;
        s.human += x.human_minutes;
        s.usd += x.usd;
        for (o, m) in &x.work {
            *s.by_job.entry(o.clone()).or_default() += m;
            *t.by_job.entry(o.clone()).or_default() += m;
        }
        let gap = s.last_end.map(|e| (x.start - e) as f64 / MIN).filter(|g| *g > 0.0 && *g < ACTIVE_GAP_MINUTES).unwrap_or(0.0);
        s.active += (x.end - x.start) as f64 / MIN + gap;
        s.last_end = Some(x.end);
        t.human += x.human_minutes;
        t.usd += x.usd;
        t.files += x.files;
        if x.test_run {
            t.tests_run += 1;
            t.tests_passed += x.test_passed as usize;
        }
        t.corrections += x.correction as usize;
        if tz.local(x.end).hour() < 5 {
            t.night += 1;
        }
    }
    t.active = t.sessions.values().map(|s| s.active).sum();
    t.turns = turns;
    Ok(t)
}

impl Tally {
    fn leverage(&self) -> Option<f64> {
        leverage(self.human, self.active).filter(|_| self.active >= LEVERAGE_MIN_ACTIVE)
    }

    /// Who you would have hired: one entry per occupation, most dollars first.
    fn jobs(&self) -> Vec<Value> {
        let t = Table::builtin();
        let mut list: Vec<(&String, f64, f64)> = self.by_job.iter().filter(|(_, m)| **m > 0.0).map(|(o, m)| (o, *m, m / 60.0 * t.rate(o))).collect();
        list.sort_by(|a, b| b.2.total_cmp(&a.2));
        list.into_iter()
            .map(|(o, m, usd)| {
                let job = t.get(o);
                json!({ "id": o, "name": t.name(o), "name_en": job.map(|j| j.name_en.as_str()), "soc": job.map(|j| j.soc.as_str()),
                        "color": color(o), "rate": t.rate(o), "hours": hours(m), "usd": usd,
                        "share": if self.usd > 0.0 { usd / self.usd } else { 0.0 } })
            })
            .collect()
    }

    /// The occupation that earned most, as its display name.
    fn top_job(&self) -> Option<&str> {
        let t = Table::builtin();
        self.by_job.iter().max_by(|a, b| (a.1 * t.rate(a.0)).total_cmp(&(b.1 * t.rate(b.0)))).map(|(o, _)| t.name(o))
    }

    /// Sessions by hours, top `limit`. `span` formats a session's start/end.
    fn sessions(&self, conn: &Connection, claude_dir: &Path, show_names: bool, limit: usize, span: impl Fn(i64, i64) -> (String, String)) -> Result<Vec<Value>> {
        let mut list: Vec<(&String, &Sess)> = self.sessions.iter().collect();
        list.sort_by(|a, b| b.1.human.partial_cmp(&a.1.human).unwrap());
        let mut rows = Vec::new();
        for (i, (sid, s)) in list.into_iter().take(limit).enumerate() {
            let ended: Option<i64> = conn.query_row("SELECT ended_at FROM sessions WHERE id = ?1", [sid], |r| r.get(0)).unwrap_or(None);
            let meta = titles::cached(conn, claude_dir, sid, ended.is_some())?;
            let top = occupation::main(&s.by_job).unwrap_or_default();
            let fallback = format!("会话 {}", i + 1);
            let (from, to) = span(s.start, s.end);
            rows.push(json!({
                "from": from,
                "to": to,
                "hours": hours(s.human),
                "usd": s.usd,
                "turns": s.turns,
                "job": top,
                "job_name": Table::builtin().name(&top),
                "color": color(&top),
                "title": if show_names { meta.title.clone().unwrap_or(fallback.clone()) } else { fallback },
                "project": if show_names { meta.project.clone() } else { None },
                "has_title": meta.title.is_some(),
            }));
        }
        Ok(rows)
    }

    /// "9.6 小时的活 · 你花了 2.1 小时 · 杠杆 4.6x"
    fn worth_line(&self) -> String {
        let a = self.active / 60.0;
        let you = if a < 1.0 { format!("{} 分钟", (a * 60.0).round()) } else { format!("{} 小时", fmt_short(a)) };
        let work = format!("{} 小时的活", fmt_short(hours(self.human)));
        match self.leverage() {
            Some(l) => format!("{work} · 你花了 {you} · 杠杆 {l:.1}x"),
            None => format!("{work} · 你花了 {you}"),
        }
    }
}

/// XP and rank as they stood at `ts`.
fn rank_at(conn: &Connection, ts: i64) -> Result<Value> {
    let pd: f64 = conn.query_row("SELECT COALESCE(SUM(credited_pd), 0) FROM turns WHERE ended_at < ?1", [ts], |r| r.get(0))?;
    let s = standing(xp_from_pd(pd, ScoringConstants::builtin().caps.minutes_per_day));
    Ok(json!({ "label": s.label(), "xp": s.xp, "color": s.rank().color, "index": s.index, "level": s.level() }))
}

fn rank_now(conn: &Connection, tz: Tz, now: i64) -> Value {
    let o = snapshot::output(conn, tz, now);
    json!({
        "label": o.rank.label(), "xp": o.rank.xp, "progress": o.rank.progress, "color": o.rank.rank().color,
        "xp_to_next": o.rank.xp_to_next(), "next_label": o.rank.next_label(),
    })
}

fn base(kind: &str, t: &Tally, show_names: bool) -> serde_json::Map<String, Value> {
    let rates = Table::builtin();
    let v = json!({
        "kind": kind,
        "show_names": show_names,
        "human_hours": hours(t.human),
        "active_hours": hours(t.active),
        "leverage": t.leverage(),
        "turns": t.turns.len(),
        "clean_turns": t.turns.len() - t.corrections,
        "files": t.files,
        "tests_run": t.tests_run,
        "tests_passed": t.tests_passed,
        "night_turns": t.night,
        "usd": t.usd,
        "jobs": t.jobs(),
        "rates": { "source": rates.source, "label": rates.label, "as_of": rates.as_of },
    });
    v.as_object().cloned().unwrap()
}

fn character(name: &str, mood: &str, headline: &str, number: String, sub: String, signoff: String) -> Value {
    json!({ "name": name, "mood": mood, "headline": headline, "number": number, "sub": sub, "signoff": signoff })
}

// ---- day ---------------------------------------------------------------

/// The report for one local day.
pub fn day(conn: &Connection, tz: Tz, cfg: &Config, claude_dir: &Path, date: NaiveDate, now: i64, show_names: bool) -> Result<Value> {
    let start = midnight(tz, date);
    let end = midnight(tz, date.succ_opt().unwrap());
    let t = tally(conn, tz, start, end)?;
    let sessions = t.sessions(conn, claude_dir, show_names, 10, |s, e| (hhmm(tz, s.max(start)), hhmm(tz, e.min(end - 1))))?;
    let blocks: Vec<Value> = t
        .turns
        .iter()
        .map(|x| {
            let job = x.job();
            let from = ((x.start.max(start) - start) as f64 / MIN).floor() as i64;
            let to = ((x.end.min(end) - start) as f64 / MIN).ceil().max(from as f64 + 1.0) as i64;
            json!({ "from_min": from, "to_min": to, "job": job, "color": color(&job) })
        })
        .collect();
    let best = sessions.first().and_then(|s| s["has_title"].as_bool().unwrap_or(false).then(|| s["title"].as_str().unwrap_or("").to_string()));

    let h = t.human / 60.0;
    let n = t.turns.len();
    let (mood, signoff) = if n == 0 {
        ("waiting", "今天没开工，我在等你。".to_string())
    } else if h >= 16.0 {
        ("proud", format!("今天顶一个人干两天，{n} 个回合。"))
    } else if t.night > 0 {
        ("sleepy", format!("凌晨那 {} 个回合，我记着。", t.night))
    } else if t.tests_run >= 3 && t.tests_passed == t.tests_run {
        ("happy", format!("{} 次测试全绿，手感不错。", t.tests_run))
    } else if t.corrections >= 5 {
        ("focused", format!("你把关了 {} 次，都改好了。", t.corrections))
    } else if let Some(b) = &best {
        ("happy", format!("今天最长的一段在「{b}」。"))
    } else if let Some(job) = t.top_job() {
        ("happy", format!("今天主要当{job}，{n} 个回合。"))
    } else {
        ("happy", format!("{n} 个回合，{} 小时的活。", fmt_short(h)))
    };
    let (headline, number, sub) = if n == 0 {
        ("今天没开工", String::new(), "休息也是节奏的一部分。".to_string())
    } else {
        ("今天这些活，请人来做要花", fmt_usd(t.usd), t.worth_line())
    };
    let streak: Value = crate::db::get_meta(conn, "streak")?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null);

    let mut r = base("day", &t, show_names);
    r.insert("date".into(), json!(day_key(date)));
    r.insert("label".into(), json!(format!("{}月{}日 · {}", date.month(), date.day(), WEEKDAYS[date.weekday().num_days_from_monday() as usize])));
    r.insert("character".into(), character(&cfg.character.name, mood, headline, number, sub, signoff));
    r.insert("sessions".into(), json!(sessions));
    r.insert("blocks".into(), json!(blocks));
    r.insert("rank".into(), rank_now(conn, tz, now));
    r.insert("streak".into(), streak.get("current").cloned().unwrap_or(json!(0)));
    Ok(Value::Object(r))
}

// ---- week --------------------------------------------------------------

/// One day of a week or month: minutes, dollars, and minutes per occupation.
struct DayTotal {
    date: NaiveDate,
    minutes: f64,
    usd: f64,
    by_job: BTreeMap<String, f64>,
}

fn per_day(t: &Tally, tz: Tz, from: NaiveDate, days: i64) -> Vec<DayTotal> {
    let mut out: Vec<DayTotal> =
        (0..days).map(|i| DayTotal { date: from + Duration::days(i), minutes: 0.0, usd: 0.0, by_job: BTreeMap::new() }).collect();
    for x in &t.turns {
        let i = (tz.date(x.end) - from).num_days();
        if (0..days).contains(&i) {
            let e = &mut out[i as usize];
            e.minutes += x.human_minutes;
            e.usd += x.usd;
            for (o, m) in &x.work {
                *e.by_job.entry(o.clone()).or_default() += m;
            }
        }
    }
    out
}

/// The report for the ISO week (Monday–Sunday) containing `date`.
pub fn week(conn: &Connection, tz: Tz, cfg: &Config, claude_dir: &Path, date: NaiveDate, now: i64, show_names: bool) -> Result<Value> {
    let monday = date - Duration::days(date.weekday().num_days_from_monday() as i64);
    let next = monday + Duration::days(7);
    let (start, end) = (midnight(tz, monday), midnight(tz, next));
    let t = tally(conn, tz, start, end)?;
    let sessions = t.sessions(conn, claude_dir, show_names, 3, |s, e| (md(tz.date(s)), md(tz.date(e))))?;
    let today = tz.date(now);
    let days_v = per_day(&t, tz, monday, 7);
    let days: Vec<Value> = days_v
        .iter()
        .enumerate()
        .map(|(i, d)| {
            let rates = Table::builtin();
            let parts: Vec<Value> = d
                .by_job
                .iter()
                .filter(|(_, m)| **m > 0.0)
                .map(|(o, m)| json!({ "job": o, "color": color(o), "hours": hours(*m), "usd": m / 60.0 * rates.rate(o) }))
                .collect();
            json!({ "date": day_key(d.date), "label": WEEKDAYS_SHORT[i], "hours": hours(d.minutes), "usd": d.usd, "parts": parts, "today": d.date == today })
        })
        .collect();
    let active_days = days_v.iter().filter(|d| d.minutes > 0.0).count();
    let best = days_v.iter().enumerate().max_by(|a, b| a.1.usd.total_cmp(&b.1.usd)).filter(|(_, d)| d.minutes > 0.0).map(|(i, _)| i);

    let h = t.human / 60.0;
    let rank_start = rank_at(conn, start)?;
    let rank_end = rank_at(conn, end.min(now + 1))?;
    let rose = rank_end["level"].as_u64() > rank_start["level"].as_u64();
    let (mood, signoff) = if t.turns.is_empty() {
        ("waiting", "这周没开工，我等你。".to_string())
    } else if h >= 40.0 {
        ("proud", "这周顶一个人干了一整周。".to_string())
    } else if rose {
        ("proud", format!("这周升到了{}。", rank_end["label"].as_str().unwrap_or("")))
    } else if t.night * 3 >= t.turns.len() {
        ("sleepy", "这周有三分之一是夜班。".to_string())
    } else if t.by_job.len() >= 4 {
        ("happy", format!("这周身兼 {} 职，主要当{}。", t.by_job.len(), t.top_job().unwrap_or("")))
    } else {
        ("happy", format!("这周主要当{}，{active_days} 天在干。", t.top_job().unwrap_or("")))
    };
    let (headline, number, sub) = if t.turns.is_empty() {
        ("这周没开工", String::new(), "休息也是节奏的一部分。".to_string())
    } else {
        ("这周这些活，请人来做要花", fmt_usd(t.usd), t.worth_line())
    };
    let iso = monday.iso_week();
    let sunday = next - Duration::days(1);

    let mut r = base("week", &t, show_names);
    r.insert("date".into(), json!(week_key(monday)));
    r.insert("label".into(), json!(format!("{}月{}日 – {}月{}日 · 第 {} 周", monday.month(), monday.day(), sunday.month(), sunday.day(), iso.week())));
    r.insert("character".into(), character(&cfg.character.name, mood, headline, number, sub, signoff));
    r.insert("sessions".into(), json!(sessions));
    r.insert("days".into(), json!(days));
    r.insert("best_day".into(), json!(best));
    r.insert("active_days".into(), json!(active_days));
    r.insert("rank_start".into(), rank_start);
    r.insert("rank_end".into(), rank_end);
    r.insert("rank".into(), rank_now(conn, tz, now));
    Ok(Value::Object(r))
}

// ---- month -------------------------------------------------------------

/// The report for the calendar month containing `date`.
pub fn month(conn: &Connection, tz: Tz, cfg: &Config, claude_dir: &Path, date: NaiveDate, now: i64, show_names: bool) -> Result<Value> {
    let first = date.with_day(1).unwrap();
    let next = if first.month() == 12 {
        NaiveDate::from_ymd_opt(first.year() + 1, 1, 1).unwrap()
    } else {
        NaiveDate::from_ymd_opt(first.year(), first.month() + 1, 1).unwrap()
    };
    let n_days = (next - first).num_days();
    let (start, end) = (midnight(tz, first), midnight(tz, next));
    let t = tally(conn, tz, start, end)?;
    let sessions = t.sessions(conn, claude_dir, show_names, 3, |s, e| (md(tz.date(s)), md(tz.date(e))))?;
    let today = tz.date(now);
    let days_v = per_day(&t, tz, first, n_days);
    let days: Vec<Value> = days_v
        .iter()
        .map(|d| {
            json!({ "date": day_key(d.date), "day": d.date.day(), "weekday": d.date.weekday().num_days_from_monday(),
                    "hours": hours(d.minutes), "usd": d.usd, "today": d.date == today, "future": d.date > today })
        })
        .collect();
    let active_days = days_v.iter().filter(|d| d.minutes > 0.0).count();
    let mut longest = 0;
    let mut run = 0;
    for d in &days_v {
        run = if d.minutes > 0.0 { run + 1 } else { 0 };
        longest = longest.max(run);
    }

    // When the work happens: human minutes by local hour of the turn's start.
    let mut by_hour = [0.0f64; 24];
    for x in &t.turns {
        by_hour[tz.local(x.start).hour() as usize] += x.human_minutes;
    }
    let peak = (0..24).max_by(|a, b| {
        let sum = |h: usize| by_hour[h] + by_hour[(h + 1) % 24] + by_hour[(h + 2) % 24];
        sum(*a).partial_cmp(&sum(*b)).unwrap()
    });
    let window = peak.filter(|_| t.human > 0.0).map(|h| format!("{}–{} 点", h, (h + 3) % 24));

    let h = t.human / 60.0;
    let rank_start = rank_at(conn, start)?;
    let rank_end = rank_at(conn, end.min(now + 1))?;
    let (mood, signoff) = if t.turns.is_empty() {
        ("waiting", "这个月没开工，我等你。".to_string())
    } else if h >= 160.0 {
        ("proud", "这个月顶一个全职。".to_string())
    } else if longest >= 7 {
        ("happy", format!("连着 {longest} 天没停，我都记着。"))
    } else if let Some(w) = &window {
        ("happy", format!("{active_days} 天在干，你最常在 {w}开工。"))
    } else {
        ("happy", format!("这个月 {active_days} 天在干。"))
    };
    let (headline, number, sub) = if t.turns.is_empty() {
        ("这个月没开工", String::new(), "休息也是节奏的一部分。".to_string())
    } else {
        ("这个月这些活，请人来做要花", fmt_usd(t.usd), t.worth_line())
    };

    let mut r = base("month", &t, show_names);
    r.insert("date".into(), json!(format!("{}-{:02}", first.year(), first.month())));
    r.insert("label".into(), json!(format!("{} 年 {} 月", first.year(), first.month())));
    r.insert("character".into(), character(&cfg.character.name, mood, headline, number, sub, signoff));
    r.insert("sessions".into(), json!(sessions));
    r.insert("days".into(), json!(days));
    r.insert("first_weekday".into(), json!(first.weekday().num_days_from_monday()));
    r.insert("active_days".into(), json!(active_days));
    r.insert("longest_run".into(), json!(longest));
    r.insert("by_hour".into(), json!(by_hour.iter().map(|m| hours(*m)).collect::<Vec<_>>()));
    r.insert("peak_window".into(), json!(window));
    r.insert("rank_start".into(), rank_start);
    r.insert("rank_end".into(), rank_end);
    r.insert("rank".into(), rank_now(conn, tz, now));
    Ok(Value::Object(r))
}

// ---- text --------------------------------------------------------------

/// A plain-text version of any report for the terminal.
pub fn text(r: &Value) -> String {
    let c = &r["character"];
    let mut out = vec![format!("{}  {}", r["label"].as_str().unwrap_or(""), c["name"].as_str().unwrap_or("")), "─".repeat(44)];
    out.push(format!("{}{}", c["headline"].as_str().unwrap_or(""), c["number"].as_str().filter(|n| !n.is_empty()).map(|n| format!(" {n}")).unwrap_or_default()));
    out.push(c["sub"].as_str().unwrap_or("").to_string());
    if let Some(days) = r["days"].as_array().filter(|_| r["kind"] != "day") {
        let line: Vec<String> = days
            .iter()
            .filter(|d| d["hours"].as_f64().unwrap_or(0.0) > 0.0)
            .map(|d| format!("{} {}", d.get("label").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| d["day"].to_string()), fmt_usd(d["usd"].as_f64().unwrap_or(0.0))))
            .collect();
        out.push(String::new());
        out.push(format!("  活跃 {} 天：{}", r["active_days"], line.join(" · ")));
    }
    out.push(String::new());
    for s in r["sessions"].as_array().into_iter().flatten() {
        let proj = s["project"].as_str().map(|p| format!("{p} · ")).unwrap_or_default();
        out.push(format!(
            "  {}–{}  {}{}  {}h · {}",
            s["from"].as_str().unwrap_or(""),
            s["to"].as_str().unwrap_or(""),
            proj,
            s["title"].as_str().unwrap_or(""),
            s["hours"],
            fmt_usd(s["usd"].as_f64().unwrap_or(0.0))
        ));
    }
    out.push(String::new());
    out.push("  相当于请了：".to_string());
    for j in r["jobs"].as_array().into_iter().flatten() {
        out.push(format!(
            "  {}  {}h × ${:.2}/h = {}",
            j["name"].as_str().unwrap_or(""),
            j["hours"],
            j["rate"].as_f64().unwrap_or(0.0),
            fmt_usd(j["usd"].as_f64().unwrap_or(0.0))
        ));
    }
    out.push(format!("  {}", r["rates"]["label"].as_str().unwrap_or("")));
    out.push(String::new());
    out.push(format!(
        "  回合 {} · 文件 {} · 测试 {}/{} · 一次过 {}/{}",
        r["turns"], r["files"], r["tests_passed"], r["tests_run"], r["clean_turns"], r["turns"]
    ));
    if r["rank_start"].is_object() {
        out.push(format!(
            "  {} → {} · +{} XP",
            r["rank_start"]["label"].as_str().unwrap_or(""),
            r["rank_end"]["label"].as_str().unwrap_or(""),
            fmt_int(r["rank_end"]["xp"].as_i64().unwrap_or(0) - r["rank_start"]["xp"].as_i64().unwrap_or(0))
        ));
    } else {
        out.push(format!("  {} · {} XP", r["rank"]["label"].as_str().unwrap_or(""), fmt_int(r["rank"]["xp"].as_i64().unwrap_or(0))));
    }
    out.push(format!("「{}」", c["signoff"].as_str().unwrap_or("")));
    out.join("\n")
}

/// Kept for callers of the first version.
pub fn day_text(r: &Value) -> String {
    text(r)
}
