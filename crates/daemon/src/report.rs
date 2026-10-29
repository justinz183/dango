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
use shadowcorp_core::pricing;
use shadowcorp_core::render::{fmt_short, fmt_usd};
use shadowcorp_core::scoring::ACTIVE_GAP_MINUTES;

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
    /// What the models cost for it at API prices.
    cost: f64,
    /// sessions.source: claude_code or codex.
    tool: String,
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
    tool: String,
}

/// Everything a period's turns add up to.
#[derive(Default)]
struct Tally {
    turns: Vec<Turn>,
    sessions: HashMap<String, Sess>,
    by_job: BTreeMap<String, f64>,
    /// Per agent: minutes, dollars, turns, model cost.
    by_tool: BTreeMap<String, (f64, f64, usize, f64)>,
    human: f64,
    usd: f64,
    cost: f64,
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

fn tally(conn: &Connection, tz: Tz, start: i64, end: i64, tool: Option<&str>) -> Result<Tally> {
    let mut st = conn.prepare(
        "SELECT t.session_id, t.started_at, t.ended_at, t.files_touched, t.test_run, t.test_passed, t.is_correction, t.work, t.usd, s.source, t.cost_usd
         FROM turns t JOIN sessions s ON s.id = t.session_id
         WHERE t.ended_at >= ?1 AND t.ended_at < ?2 AND (?3 IS NULL OR s.source = ?3) ORDER BY t.started_at",
    )?;
    let turns: Vec<Turn> = st
        .query_map(rusqlite::params![start, end, tool], |r| {
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
                tool: r.get(9)?,
                cost: r.get(10)?,
            })
        })?
        .flatten()
        .collect();
    let mut t = Tally::default();
    for x in &turns {
        let s = t.sessions.entry(x.session.clone()).or_insert_with(|| Sess { start: x.start, end: x.end, tool: x.tool.clone(), ..Default::default() });
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
        t.cost += x.cost;
        let e = t.by_tool.entry(x.tool.clone()).or_default();
        e.0 += x.human_minutes;
        e.1 += x.usd;
        e.2 += 1;
        e.3 += x.cost;
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
    /// Dollars of work per dollar of model.
    fn leverage(&self) -> Option<f64> {
        pricing::leverage(self.usd, self.cost)
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
                        "scene": t.scene(o), "look": job.map(|j| j.look.clone()).unwrap_or_default(),
                        "share": if self.usd > 0.0 { usd / self.usd } else { 0.0 } })
            })
            .collect()
    }

    /// Claude Code and Codex side by side, most dollars first.
    fn tools(&self) -> Vec<Value> {
        let mut list: Vec<_> = self.by_tool.iter().collect();
        list.sort_by(|a, b| b.1 .1.total_cmp(&a.1 .1));
        list.into_iter()
            .map(|(src, (m, usd, n, cost))| {
                let (name, color) = crate::widget::tool_label(src);
                json!({ "id": src, "name": name, "color": color, "hours": hours(*m), "usd": usd, "turns": n,
                        "cost": cost, "leverage": pricing::leverage(*usd, *cost),
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
                "tool": crate::widget::tool_label(&s.tool).0,
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

    /// "9.6 小时的活 · 模型花费 $85 · 杠杆 19.7x"
    fn worth_line(&self) -> String {
        let work = format!("{} 小时的活", fmt_short(hours(self.human)));
        match self.leverage() {
            Some(l) => format!("{work} · 模型花费 {} · 杠杆 {}", fmt_usd(self.cost), pricing::fmt_leverage(Some(l))),
            None => work,
        }
    }
}

/// What the previous period came to, for "比上周 +$600". Names are
/// relative ("上周 → 本周") for the current period, absolute ("第 43 周 →
/// 第 44 周") for an earlier one; `now_label` names the period itself.
fn prev(conn: &Connection, tz: Tz, label: &str, start: i64, end: i64, tool: Option<&str>) -> Result<Value> {
    let t = tally(conn, tz, start, end, tool)?;
    Ok(json!({ "label": label, "usd": t.usd, "hours": hours(t.human), "cost": t.cost, "leverage": t.leverage() }))
}

/// "今天这些活" for everything, "Codex 今天干的活" for one agent.
fn headline(when: &str, tool: Option<&str>) -> String {
    match tool {
        Some(t) => format!("{} {when}干的活，请人来做要花", crate::widget::tool_label(t).0),
        None => format!("{when}这些活，请人来做要花"),
    }
}

fn base(kind: &str, t: &Tally, show_names: bool, tool: Option<&str>) -> serde_json::Map<String, Value> {
    let rates = Table::builtin();
    let v = json!({
        "kind": kind,
        "tool": tool,
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
        "cost": t.cost,
        "jobs": t.jobs(),
        "tools": t.tools(),
        "rates": { "source": rates.source, "label": rates.label, "as_of": rates.as_of },
    });
    v.as_object().cloned().unwrap()
}

fn character(name: &str, mood: &str, headline: &str, number: String, sub: String, signoff: String) -> Value {
    json!({ "name": name, "mood": mood, "headline": headline, "number": number, "sub": sub, "signoff": signoff })
}

// ---- day ---------------------------------------------------------------

/// The report for one local day.
pub fn day(conn: &Connection, tz: Tz, cfg: &Config, claude_dir: &Path, date: NaiveDate, now: i64, show_names: bool, tool: Option<&str>) -> Result<Value> {
    let start = midnight(tz, date);
    let end = midnight(tz, date.succ_opt().unwrap());
    let t = tally(conn, tz, start, end, tool)?;
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
    let current = date == tz.date(now);
    let when = if current { "今天" } else { "那天" };
    let (mood, signoff) = if n == 0 {
        ("waiting", if current { "今天没开工，我在等你。".to_string() } else { "那天没开工。".to_string() })
    } else if h >= 16.0 {
        ("proud", format!("{when}顶一个人干两天，{n} 个回合。"))
    } else if t.night > 0 {
        ("sleepy", format!("凌晨那 {} 个回合，我记着。", t.night))
    } else if t.tests_run >= 3 && t.tests_passed == t.tests_run {
        ("happy", format!("{} 次测试全绿，手感不错。", t.tests_run))
    } else if t.corrections >= 5 {
        ("focused", format!("你把关了 {} 次，都改好了。", t.corrections))
    } else if let Some(b) = &best {
        ("happy", format!("{when}最长的一段在「{b}」。"))
    } else if let Some(job) = t.top_job() {
        ("happy", format!("{when}主要当{job}，{n} 个回合。"))
    } else {
        ("happy", format!("{n} 个回合，{} 小时的活。", fmt_short(h)))
    };
    let (title, number, sub) = if n == 0 {
        (format!("{when}没开工"), String::new(), "休息也是节奏的一部分。".to_string())
    } else {
        (headline(when, tool), fmt_usd(t.usd), t.worth_line())
    };
    let streak: Value = crate::db::get_meta(conn, "streak")?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null);

    let mut r = base("day", &t, show_names, tool);
    r.insert("date".into(), json!(day_key(date)));
    r.insert("label".into(), json!(format!("{}月{}日 · {}", date.month(), date.day(), WEEKDAYS[date.weekday().num_days_from_monday() as usize])));
    r.insert("character".into(), character(&cfg.character.name, mood, &title, number, sub, signoff));
    r.insert("sessions".into(), json!(sessions));
    r.insert("blocks".into(), json!(blocks));
    let before = if current { "昨天".to_string() } else { md(date.pred_opt().unwrap()) };
    r.insert("now_label".into(), json!(if current { "今天".to_string() } else { md(date) }));
    r.insert("prev".into(), prev(conn, tz, &before, midnight(tz, date.pred_opt().unwrap()), start, tool)?);
    r.insert("record_day_usd".into(), json!(snapshot::best_day_usd(conn)));
    // The streak is as of now, so only today's card shows it.
    r.insert("streak".into(), if current { streak.get("current").cloned().unwrap_or(json!(0)) } else { json!(0) });
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
pub fn week(conn: &Connection, tz: Tz, cfg: &Config, claude_dir: &Path, date: NaiveDate, now: i64, show_names: bool, tool: Option<&str>) -> Result<Value> {
    let monday = date - Duration::days(date.weekday().num_days_from_monday() as i64);
    let next = monday + Duration::days(7);
    let (start, end) = (midnight(tz, monday), midnight(tz, next));
    let t = tally(conn, tz, start, end, tool)?;
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
    let current = (monday..next).contains(&tz.date(now));
    let when = if current { "这周" } else { "那周" };
    let before = if current { "上周".to_string() } else { format!("第 {} 周", (monday - Duration::days(7)).iso_week().week()) };
    let last_week = prev(conn, tz, &before, midnight(tz, monday - Duration::days(7)), start, tool)?;
    let prev_usd = last_week["usd"].as_f64().unwrap_or(0.0);
    let (mood, signoff) = if t.turns.is_empty() {
        ("waiting", if current { "这周没开工，我等你。".to_string() } else { "那周没开工。".to_string() })
    } else if h >= 40.0 {
        ("proud", format!("{when}顶一个人干了一整周。"))
    } else if prev_usd > 0.0 && t.usd > prev_usd * 1.2 {
        ("proud", format!("{when}比{}多 {}。", if current { "上周" } else { "前一周" }, fmt_usd(t.usd - prev_usd)))
    } else if t.night * 3 >= t.turns.len() {
        ("sleepy", format!("{when}有三分之一是夜班。"))
    } else if t.by_job.len() >= 4 {
        ("happy", format!("{when}身兼 {} 职，主要当{}。", t.by_job.len(), t.top_job().unwrap_or("")))
    } else {
        ("happy", format!("{when}主要当{}，{active_days} 天在干。", t.top_job().unwrap_or("")))
    };
    let (title, number, sub) = if t.turns.is_empty() {
        (format!("{when}没开工"), String::new(), "休息也是节奏的一部分。".to_string())
    } else {
        (headline(when, tool), fmt_usd(t.usd), t.worth_line())
    };
    let iso = monday.iso_week();
    let sunday = next - Duration::days(1);

    let mut r = base("week", &t, show_names, tool);
    r.insert("date".into(), json!(week_key(monday)));
    r.insert("now_label".into(), json!(if current { "本周".to_string() } else { format!("第 {} 周", monday.iso_week().week()) }));
    r.insert("label".into(), json!(format!("{}月{}日 – {}月{}日 · 第 {} 周", monday.month(), monday.day(), sunday.month(), sunday.day(), iso.week())));
    r.insert("character".into(), character(&cfg.character.name, mood, &title, number, sub, signoff));
    r.insert("sessions".into(), json!(sessions));
    r.insert("days".into(), json!(days));
    r.insert("best_day".into(), json!(best));
    r.insert("active_days".into(), json!(active_days));
    r.insert("prev".into(), last_week);
    r.insert("record_day_usd".into(), json!(snapshot::best_day_usd(conn)));
    Ok(Value::Object(r))
}

// ---- month -------------------------------------------------------------

/// The report for the calendar month containing `date`.
pub fn month(conn: &Connection, tz: Tz, cfg: &Config, claude_dir: &Path, date: NaiveDate, now: i64, show_names: bool, tool: Option<&str>) -> Result<Value> {
    let first = date.with_day(1).unwrap();
    let next = if first.month() == 12 {
        NaiveDate::from_ymd_opt(first.year() + 1, 1, 1).unwrap()
    } else {
        NaiveDate::from_ymd_opt(first.year(), first.month() + 1, 1).unwrap()
    };
    let n_days = (next - first).num_days();
    let (start, end) = (midnight(tz, first), midnight(tz, next));
    let t = tally(conn, tz, start, end, tool)?;
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
    let longest = longest_run(&days_v);

    let (by_hour, window) = rhythm(&t, tz);

    let h = t.human / 60.0;
    let prev_first = if first.month() == 1 { NaiveDate::from_ymd_opt(first.year() - 1, 12, 1).unwrap() } else { NaiveDate::from_ymd_opt(first.year(), first.month() - 1, 1).unwrap() };
    let current = (first..next).contains(&today);
    let when = if current { "这个月" } else { "那个月" };
    let before = if current { "上个月".to_string() } else { format!("{} 月", prev_first.month()) };
    let last_month = prev(conn, tz, &before, midnight(tz, prev_first), start, tool)?;
    let (mood, signoff) = if t.turns.is_empty() {
        ("waiting", if current { "这个月没开工，我等你。".to_string() } else { "那个月没开工。".to_string() })
    } else if h >= FULL_TIME_MONTH_HOURS {
        ("proud", format!("{when}顶一个全职。"))
    } else if longest >= 7 {
        ("happy", format!("连着 {longest} 天没停，我都记着。"))
    } else if let Some(w) = &window {
        ("happy", format!("{active_days} 天在干，你最常在 {w}开工。"))
    } else {
        ("happy", format!("{when} {active_days} 天在干。"))
    };
    let (title, number, sub) = if t.turns.is_empty() {
        (format!("{when}没开工"), String::new(), "休息也是节奏的一部分。".to_string())
    } else {
        (headline(when, tool), fmt_usd(t.usd), t.worth_line())
    };

    let mut r = base("month", &t, show_names, tool);
    r.insert("date".into(), json!(format!("{}-{:02}", first.year(), first.month())));
    r.insert("now_label".into(), json!(if current { "本月".to_string() } else { format!("{} 月", first.month()) }));
    r.insert("label".into(), json!(format!("{} 年 {} 月", first.year(), first.month())));
    r.insert("character".into(), character(&cfg.character.name, mood, &title, number, sub, signoff));
    r.insert("sessions".into(), json!(sessions));
    r.insert("days".into(), json!(days));
    r.insert("first_weekday".into(), json!(first.weekday().num_days_from_monday()));
    r.insert("active_days".into(), json!(active_days));
    r.insert("longest_run".into(), json!(longest));
    r.insert("by_hour".into(), json!(by_hour.iter().map(|m| hours(*m)).collect::<Vec<_>>()));
    r.insert("peak_window".into(), json!(window));
    r.insert("prev".into(), last_month);
    r.insert("record_day_usd".into(), json!(snapshot::best_day_usd(conn)));
    Ok(Value::Object(r))
}

/// When the work happens: human minutes by local hour of the turn's
/// start, and the three-hour window with the most.
fn rhythm(t: &Tally, tz: Tz) -> ([f64; 24], Option<String>) {
    let mut by_hour = [0.0f64; 24];
    for x in &t.turns {
        by_hour[tz.local(x.start).hour() as usize] += x.human_minutes;
    }
    let peak = (0..24).max_by(|a, b| {
        let sum = |h: usize| by_hour[h] + by_hour[(h + 1) % 24] + by_hour[(h + 2) % 24];
        sum(*a).partial_cmp(&sum(*b)).unwrap()
    });
    (by_hour, peak.filter(|_| t.human > 0.0).map(|h| format!("{}–{} 点", h, (h + 3) % 24)))
}

fn longest_run(days: &[DayTotal]) -> usize {
    let (mut longest, mut run) = (0, 0);
    for d in days {
        run = if d.minutes > 0.0 { run + 1 } else { 0 };
        longest = longest.max(run);
    }
    longest
}

// ---- year --------------------------------------------------------------

/// Hours a full-time person works in a month (40 h × 4 weeks).
const FULL_TIME_MONTH_HOURS: f64 = 160.0;

/// The report for the calendar year containing `date`: twelve months
/// stacked by occupation, and every day as a heatmap.
pub fn year(conn: &Connection, tz: Tz, cfg: &Config, claude_dir: &Path, date: NaiveDate, now: i64, show_names: bool, tool: Option<&str>) -> Result<Value> {
    let first = NaiveDate::from_ymd_opt(date.year(), 1, 1).unwrap();
    let next = NaiveDate::from_ymd_opt(date.year() + 1, 1, 1).unwrap();
    let (start, end) = (midnight(tz, first), midnight(tz, next));
    let t = tally(conn, tz, start, end, tool)?;
    let sessions = t.sessions(conn, claude_dir, show_names, 3, |s, e| (md(tz.date(s)), md(tz.date(e))))?;
    let today = tz.date(now);
    let days_v = per_day(&t, tz, first, (next - first).num_days());
    let rates = Table::builtin();
    let mut months: Vec<(f64, f64, BTreeMap<String, f64>)> = vec![(0.0, 0.0, BTreeMap::new()); 12];
    for d in &days_v {
        let m = &mut months[d.date.month0() as usize];
        m.0 += d.usd;
        m.1 += d.minutes;
        for (o, mins) in &d.by_job {
            *m.2.entry(o.clone()).or_default() += mins;
        }
    }
    let months_json: Vec<Value> = months
        .iter()
        .enumerate()
        .map(|(i, (usd, mins, by_job))| {
            let parts: Vec<Value> = by_job
                .iter()
                .filter(|(_, m)| **m > 0.0)
                .map(|(o, m)| json!({ "job": o, "color": color(o), "hours": hours(*m), "usd": m / 60.0 * rates.rate(o) }))
                .collect();
            let starts = NaiveDate::from_ymd_opt(first.year(), i as u32 + 1, 1).unwrap();
            json!({ "label": format!("{}月", i + 1), "usd": usd, "hours": hours(*mins), "parts": parts,
                    "current": today.year() == first.year() && today.month0() as usize == i, "future": starts > today })
        })
        .collect();
    let active_days = days_v.iter().filter(|d| d.minutes > 0.0).count();
    let longest = longest_run(&days_v);
    let best_day = days_v.iter().filter(|d| d.minutes > 0.0).max_by(|a, b| a.usd.total_cmp(&b.usd));
    let best_month = (0..12).filter(|i| months[*i].0 > 0.0).max_by(|a, b| months[*a].0.total_cmp(&months[*b].0));
    let (by_hour, window) = rhythm(&t, tz);

    let h = t.human / 60.0;
    let current = first.year() == today.year();
    let when = if current { "今年" } else { "那一年" };
    let before = if current { "去年".to_string() } else { format!("{} 年", first.year() - 1) };
    let last_year = prev(conn, tz, &before, midnight(tz, NaiveDate::from_ymd_opt(first.year() - 1, 1, 1).unwrap()), start, tool)?;
    let (mood, signoff) = if t.turns.is_empty() {
        ("waiting", if current { "今年还没开工，我等你。".to_string() } else { "那一年没开工。".to_string() })
    } else if h >= FULL_TIME_MONTH_HOURS * 12.0 {
        ("proud", format!("{when}顶一个全职干了一整年。"))
    } else if h >= FULL_TIME_MONTH_HOURS {
        ("proud", format!("{when}顶一个全职干了 {} 个月。", fmt_short((h / FULL_TIME_MONTH_HOURS * 10.0).round() / 10.0)))
    } else if longest >= 14 {
        ("happy", format!("最长连着 {longest} 天没停，我都记着。"))
    } else {
        ("happy", format!("{when} {active_days} 天在干，主要当{}。", t.top_job().unwrap_or("")))
    };
    let (title, number, sub) = if t.turns.is_empty() {
        (if current { "今年还没开工".to_string() } else { "那一年没开工".to_string() }, String::new(), "休息也是节奏的一部分。".to_string())
    } else {
        (headline(when, tool), fmt_usd(t.usd), t.worth_line())
    };
    let label = if first.year() == today.year() {
        format!("{} 年 · 截至 {}月{}日", first.year(), today.month(), today.day())
    } else {
        format!("{} 年", first.year())
    };

    let mut r = base("year", &t, show_names, tool);
    r.insert("date".into(), json!(first.year().to_string()));
    r.insert("now_label".into(), json!(if current { "今年".to_string() } else { format!("{} 年", first.year()) }));
    r.insert("label".into(), json!(label));
    r.insert("character".into(), character(&cfg.character.name, mood, &title, number, sub, signoff));
    r.insert("sessions".into(), json!(sessions));
    r.insert("months".into(), json!(months_json));
    r.insert("best_month".into(), json!(best_month));
    // Every day's dollars from 1 January, for the heatmap.
    r.insert("heat".into(), json!(days_v.iter().map(|d| (d.usd * 100.0).round() / 100.0).collect::<Vec<_>>()));
    r.insert("first_weekday".into(), json!(first.weekday().num_days_from_monday()));
    r.insert("today_index".into(), json!((first.year() == today.year()).then(|| (today - first).num_days())));
    r.insert("active_days".into(), json!(active_days));
    r.insert("longest_run".into(), json!(longest));
    r.insert("best_day".into(), json!(best_day.map(|d| json!({ "date": md(d.date), "usd": d.usd }))));
    r.insert("by_hour".into(), json!(by_hour.iter().map(|m| hours(*m)).collect::<Vec<_>>()));
    r.insert("peak_window".into(), json!(window));
    r.insert("prev".into(), last_year);
    r.insert("record_day_usd".into(), json!(snapshot::best_day_usd(conn)));
    Ok(Value::Object(r))
}

// ---- text --------------------------------------------------------------

/// A plain-text version of any report for the terminal.
pub fn text(r: &Value) -> String {
    let c = &r["character"];
    let mut out = vec![format!("{}  {}", r["label"].as_str().unwrap_or(""), c["name"].as_str().unwrap_or("")), "─".repeat(44)];
    out.push(format!("{}{}", c["headline"].as_str().unwrap_or(""), c["number"].as_str().filter(|n| !n.is_empty()).map(|n| format!(" {n}")).unwrap_or_default()));
    out.push(c["sub"].as_str().unwrap_or("").to_string());
    let tools: Vec<String> = r["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|t| format!("{} {} · {}h", t["name"].as_str().unwrap_or(""), fmt_usd(t["usd"].as_f64().unwrap_or(0.0)), t["hours"]))
        .collect();
    if !tools.is_empty() {
        out.push(tools.join("  |  "));
    }
    if let Some(months) = r["months"].as_array() {
        let line: Vec<String> = months
            .iter()
            .filter(|m| m["usd"].as_f64().unwrap_or(0.0) > 0.0)
            .map(|m| format!("{} {}", m["label"].as_str().unwrap_or(""), fmt_usd(m["usd"].as_f64().unwrap_or(0.0))))
            .collect();
        out.push(String::new());
        out.push(format!("  活跃 {} 天：{}", r["active_days"], line.join(" · ")));
    } else if let Some(days) = r["days"].as_array().filter(|_| r["kind"] != "day") {
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
    out.push("  都当了谁：".to_string());
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
    let (now_usd, prev_usd) = (r["usd"].as_f64().unwrap_or(0.0), r["prev"]["usd"].as_f64().unwrap_or(0.0));
    let diff = now_usd - prev_usd;
    out.push(format!(
        "  {} {} · {}{} · 单日纪录 {}",
        r["prev"]["label"].as_str().unwrap_or("上次"),
        fmt_usd(prev_usd),
        if diff >= 0.0 { "+" } else { "−" },
        fmt_usd(diff.abs()),
        fmt_usd(r["record_day_usd"].as_f64().unwrap_or(0.0))
    ));
    out.push(format!("「{}」", c["signoff"].as_str().unwrap_or("")));
    out.join("\n")
}

/// Kept for callers of the first version.
pub fn day_text(r: &Value) -> String {
    text(r)
}
