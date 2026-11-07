//! ~/.dango/widget.json: the state the desktop widget shows — the
//! headline dollars and rank for the collapsed panel, the character's live
//! mood and line, and the history the expanded dashboard draws. Rewritten
//! by the daemon after new activity.

use std::collections::{BTreeMap, HashMap};
use std::fs;

use chrono::{Datelike, Duration, Timelike};
use rusqlite::{Connection, OptionalExtension};
use serde_json::{json, Value};
use dango_core::occupation::{self, Table};
use dango_core::pricing;
use dango_core::i18n::{a_job, Lang};
use dango_core::render::{fmt_hours_in, fmt_usd};
use dango_core::scoring::ScoringConstants;

use crate::config::Config;
use crate::ingest::{day_key, week_key, Result, Tz};
use crate::paths::{write_private, Paths};
use crate::snapshot::{self, Output};

const MIN_MS: i64 = 60_000;
const DAY_MS: i64 = 86_400_000;
pub const HISTORY_DAYS: i64 = 30;

/// A turn's credited minutes per occupation (turns.work).
/// A turn's minutes per occupation, merged occupations counted as their
/// representative.
pub fn work_of(json: &str) -> BTreeMap<String, f64> {
    let raw: BTreeMap<String, f64> = serde_json::from_str(json).unwrap_or_default();
    let t = Table::builtin();
    let mut out = BTreeMap::new();
    for (o, m) in raw {
        *out.entry(t.canon(&o).to_string()).or_default() += m;
    }
    out
}

/// Puts every occupation's name in `lang`: objects that carry an
/// occupation as "id" (or "job") and a "name" (or "job_name").
pub fn localize(v: &mut Value, lang: Lang) {
    let t = Table::builtin();
    match v {
        Value::Object(m) => {
            for (key, name_key) in [("id", "name"), ("job", "name"), ("job", "job_name")] {
                let id = m.get(key).and_then(Value::as_str).map(str::to_string);
                if let (Some(id), true) = (id, m.contains_key(name_key)) {
                    if t.get(&id).is_some() {
                        m.insert(name_key.into(), json!(t.name_in(&id, lang)));
                    }
                }
            }
            for x in m.values_mut() {
                localize(x, lang);
            }
        }
        Value::Array(a) => a.iter_mut().for_each(|x| localize(x, lang)),
        _ => {}
    }
}

/// Display name and colour of an agent (sessions.source).
pub fn tool_label(source: &str) -> (&'static str, &'static str) {
    match source {
        "codex" => ("Codex", "#5b6b7a"),
        "deepseek" => ("DeepSeek", "#4d6bfe"),
        "workbuddy" => ("WorkBuddy", "#7b61ff"),
        _ => ("Claude Code", "#d97757"),
    }
}

/// Claude Code and Codex side by side for turns that ended in [from, to):
/// dollars, hours, turns and share of the dollars, biggest first.
pub fn tools(conn: &Connection, from: i64, to: i64) -> Result<Vec<Value>> {
    let k = ScoringConstants::builtin();
    let mut st = conn.prepare(
        "SELECT s.source, SUM(t.usd), SUM(t.credited_pd), COUNT(*), SUM(t.cost_usd) FROM turns t JOIN sessions s ON s.id = t.session_id
         WHERE t.ended_at >= ?1 AND t.ended_at < ?2 GROUP BY s.source ORDER BY SUM(t.usd) DESC",
    )?;
    let rows: Vec<(String, f64, f64, i64, f64)> =
        st.query_map([from, to], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)))?.flatten().collect();
    let total: f64 = rows.iter().map(|r| r.1).sum();
    Ok(rows
        .into_iter()
        .map(|(src, usd, pd, n, cost)| {
            let (name, color) = tool_label(&src);
            json!({ "id": src, "name": name, "color": color, "usd": usd, "hours": pd * k.units.minutes_per_day / 60.0, "turns": n,
                    "cost": cost, "leverage": pricing::leverage(usd, cost), "share": if total > 0.0 { usd / total } else { 0.0 } })
        })
        .collect())
}

/// One counter per day (e.g. `usd`, `minutes:codex`), for days on or after `from`.
pub fn metric_by_day(conn: &Connection, metric: &str, from: chrono::NaiveDate) -> Result<HashMap<String, f64>> {
    let mut st = conn.prepare("SELECT substr(scope, 5), value FROM counters WHERE metric = ?1 AND scope LIKE 'day:%' AND scope >= ?2")?;
    let rows = st.query_map([metric.to_string(), format!("day:{}", day_key(from))], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))?;
    Ok(rows.flatten().collect())
}

/// Who did the work of turns that ended in [from, to), for all agents or
/// one: one entry per occupation with hours, dollars and share of the
/// dollars, biggest first.
pub fn jobs(conn: &Connection, from: i64, to: i64, tool: Option<&str>) -> Result<Vec<Value>> {
    let t = Table::builtin();
    let mut st = conn.prepare(
        "SELECT j.key, SUM(j.value) FROM turns JOIN sessions s ON s.id = turns.session_id, json_each(turns.work) j
         WHERE turns.ended_at >= ?1 AND turns.ended_at < ?2 AND (?3 IS NULL OR s.source = ?3) GROUP BY j.key",
    )?;
    // Merged occupations count as their representative.
    let mut minutes: BTreeMap<String, f64> = BTreeMap::new();
    for (o, m) in st.query_map(rusqlite::params![from, to, tool], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))?.flatten() {
        *minutes.entry(t.canon(&o).to_string()).or_default() += m;
    }
    let mut rows: Vec<(String, f64, f64)> = minutes
        .into_iter()
        .filter(|(_, m)| *m > 0.0)
        .map(|(o, m)| {
            let usd = m / 60.0 * t.rate(&o);
            (o, m, usd)
        })
        .collect();
    rows.sort_by(|a, b| b.2.total_cmp(&a.2));
    let total: f64 = rows.iter().map(|r| r.2).sum();
    Ok(rows
        .into_iter()
        .map(|(o, m, usd)| {
            let job = t.get(&o);
            json!({
                "id": o, "name": t.name(&o), "name_en": job.map(|j| j.name_en.as_str()), "color": job.map(|j| j.color.as_str()),
                "rate": t.rate(&o), "hours": m / 60.0, "usd": usd, "share": if total > 0.0 { usd / total } else { 0.0 },
            })
        })
        .collect())
}

/// The occupation the agent is "being" right now: the main one of the
/// turns in progress, else of the last finished turn.
pub fn current_job(conn: &Connection, now: i64) -> Result<Option<String>> {
    const WORKING_WINDOW_MS: i64 = 20 * MIN_MS;
    let mut st = conn.prepare(
        "SELECT json_extract(t.agg, '$.work'), json_extract(t.agg, '$.last_activity')
         FROM sessions s JOIN turns t ON t.id = json_extract(s.state, '$.open_turn') WHERE t.ended_at IS NULL",
    )?;
    let mut work: BTreeMap<String, f64> = BTreeMap::new();
    for (w, last) in st.query_map([], |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, Option<i64>>(1)?)))?.flatten() {
        if last.is_some_and(|l| now - l < WORKING_WINDOW_MS) {
            for (o, m) in work_of(&w.unwrap_or_default()) {
                *work.entry(o).or_default() += m;
            }
        }
    }
    if let Some(j) = occupation::main(&work) {
        return Ok(Some(j));
    }
    let last: Option<String> = conn
        .query_row("SELECT work FROM turns WHERE ended_at IS NOT NULL ORDER BY ended_at DESC LIMIT 1", [], |r| r.get(0))
        .optional()?;
    Ok(last.and_then(|w| occupation::main(&work_of(&w))))
}

/// How many failed test commands in one turn make its job fume.
pub const FUMING_FAILS: i64 = 3;
/// How long a job stays happy after a turn that ended with tests green or
/// a commit.
pub const HAPPY_MS: i64 = 30 * MIN_MS;

#[derive(Default)]
struct Member {
    minutes: f64,
    last: i64,
    working: bool,
    helpers: i64,
    /// An event-driven state (waiting, fuming, happy) and when it began;
    /// the widget derives idle / sleeping / off from `last` itself.
    status: Option<&'static str>,
    status_since: i64,
}

/// Who is in the office: the occupations that did any work in the last
/// seven days (eight at most, by what they earned; the room shows six at a
/// time and takes the rest in turns). An occupation is at work
/// when a turn in progress is mainly its job, or has given it 15 minutes
/// already; its helpers are that turn's sub-agents. The job of a turn whose
/// session waits on a permission prompt is `waiting`; one whose turn has
/// failed tests FUMING_FAILS times is `fuming`; one whose last turn ended
/// within HAPPY_MS with tests green or a commit is `happy`. The rest slack
/// off, by how long ago they last worked (the widget decides how).
pub fn office(conn: &Connection, tz: Tz, now: i64) -> Result<Vec<Value>> {
    const WORKING_MS: i64 = 20 * MIN_MS;
    const STAFF_DAYS: i64 = 7;
    let t = Table::builtin();
    let from = tz.ms((tz.date(now) - Duration::days(STAFF_DAYS - 1)).and_hms_opt(0, 0, 0).unwrap());
    let mut staff: BTreeMap<String, Member> = BTreeMap::new();
    let mut st = conn.prepare(
        "SELECT j.key, SUM(j.value), MAX(turns.ended_at) FROM turns, json_each(turns.work) j
         WHERE turns.ended_at >= ?1 AND j.value > 0 GROUP BY j.key",
    )?;
    for (o, m, last) in st.query_map([from], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?, r.get::<_, i64>(2)?)))?.flatten() {
        let e = staff.entry(t.canon(&o).to_string()).or_insert_with(|| Member { last, ..Default::default() });
        e.minutes += m;
        e.last = e.last.max(last);
    }
    let mut st = conn.prepare(
        "SELECT json_extract(t.agg, '$.work'), json_extract(t.agg, '$.last_activity'),
                json_extract(t.agg, '$.agent_calls'), json_extract(t.agg, '$.subagent_stops'),
                json_extract(s.state, '$.waiting_since'), json_extract(t.agg, '$.test_fails'),
                json_extract(t.agg, '$.subagent_starts')
         FROM sessions s JOIN turns t ON t.id = json_extract(s.state, '$.open_turn') WHERE t.ended_at IS NULL",
    )?;
    type Open = (Option<String>, Option<i64>, Option<i64>, Option<i64>, Option<i64>, Option<i64>, Option<i64>);
    let open: Vec<Open> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)))?.flatten().collect();
    let mut any_open = false;
    for (work, last, calls, stops, waiting, fails, starts) in open {
        let last = last.unwrap_or(0);
        // A prompt waits as long as it takes; work goes quiet after a while.
        if waiting.is_none() && now - last >= WORKING_MS {
            continue;
        }
        any_open = true;
        let w = work_of(&work.unwrap_or_default());
        let main = occupation::main(&w).or_else(|| current_job(conn, now).ok().flatten());
        for (o, m) in &w {
            let is_main = main.as_deref() == Some(o.as_str());
            if is_main || *m >= 15.0 {
                let e = staff.entry(o.clone()).or_insert_with(|| Member { last, ..Default::default() });
                e.last = e.last.max(last);
                e.working = true;
                if is_main {
                    e.helpers += snapshot::running_helpers(calls.unwrap_or(0), starts.unwrap_or(0), stops.unwrap_or(0));
                }
            }
        }
        if let Some(j) = main {
            let e = staff.entry(j).or_insert_with(|| Member { last: now, ..Default::default() });
            e.working = true;
            if let Some(since) = waiting {
                e.status = Some("waiting");
                e.status_since = since;
            } else if fails.unwrap_or(0) >= FUMING_FAILS {
                e.status = Some("fuming");
                e.status_since = last;
            }
        }
    }
    // A turn that has not done anything yet: whoever did the last one is on it.
    if any_open && !staff.values().any(|v| v.working) {
        if let Some(j) = current_job(conn, now)? {
            let e = staff.entry(j).or_insert_with(|| Member { last: now, ..Default::default() });
            e.working = true;
        }
    }
    // Just done, and well: the job of a turn that ended within HAPPY_MS with
    // its tests green or a commit is happy about it.
    let mut st = conn.prepare("SELECT work, ended_at, test_passed, git_action FROM turns WHERE ended_at >= ?1 ORDER BY ended_at DESC")?;
    for (work, ended, passed, git) in st
        .query_map([now - HAPPY_MS], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, Option<i64>>(2)?, r.get::<_, Option<String>>(3)?)))?
        .flatten()
    {
        let Some(j) = occupation::main(&work_of(&work)) else { continue };
        let well = passed == Some(1) || matches!(git.as_deref(), Some("commit") | Some("merge"));
        if let Some(e) = staff.get_mut(&j) {
            if well && !e.working && e.status.is_none() {
                e.status = Some("happy");
                e.status_since = ended;
            }
        }
    }
    let mut list: Vec<(String, f64, Member)> = staff.into_iter().map(|(o, m)| (o.clone(), m.minutes / 60.0 * t.rate(&o), m)).collect();
    list.sort_by(|a, b| b.2.working.cmp(&a.2.working).then(b.1.total_cmp(&a.1)));
    Ok(list
        .into_iter()
        .take(8)
        .map(|(o, usd, m)| {
            json!({ "id": o, "name": t.name(&o), "color": t.get(&o).map(|x| x.color.as_str()), "scene": t.scene(&o),
                    "working": m.working, "helpers": m.helpers, "since": m.last, "usd": usd,
                    "status": m.status, "status_since": if m.status.is_some() { Some(m.status_since) } else { None } })
        })
        .collect())
}

/// Days since the first active day, today included.
fn days_together(conn: &Connection, tz: Tz, now: i64) -> i64 {
    crate::db::get_meta(conn, "first_active_day")
        .ok()
        .flatten()
        .and_then(|d| crate::ingest::parse_day(&d))
        .map(|first| (tz.date(now) - first).num_days() + 1)
        .unwrap_or(0)
}

/// The character's mood and line right now (DESIGN.md §2), from what the
/// agent is doing, how long it has been quiet, what just happened and what
/// it remembers: the best day, last week, how long you have worked together.
pub fn character(conn: &Connection, tz: Tz, cfg: &Config, o: &Output, now: i64, working: i64, subagents: i64, last_event: Option<i64>, job: Option<&str>) -> Result<Value> {
    let since = last_event.map(|t| now - t).unwrap_or(i64::MAX);
    let last: Option<(String, f64, i64, i64, Option<i64>, f64)> = conn
        .query_row(
            "SELECT work, credited_pd, ended_at, test_run, test_passed, usd FROM turns WHERE ended_at IS NOT NULL ORDER BY ended_at DESC LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?)),
        )
        .optional()?;
    let k = ScoringConstants::builtin();
    let t = Table::builtin();
    let local = tz.local(now);
    let hour = local.hour();
    let today = tz.date(now);
    let prev_week = snapshot::counter(conn, "usd", &format!("week:{}", week_key(today - Duration::days(7))));
    let days = days_together(conn, tz, now);
    let lang = cfg.lang();
    let en = lang.en();
    let job_name = job.map(|j| t.name_in(j, lang).to_string());
    let s = |zh: &str, en: &str| lang.t(zh, en).to_string();
    let (mood, line) = if working > 0 && since < 20 * MIN_MS {
        if hour < 5 {
            ("sleepy", s("这么晚了，还在干。", "Still at it this late."))
        } else if subagents > 0 {
            ("focused", if en { format!("Working with {subagents} helpers.") } else { format!("带着 {subagents} 个帮手在干。") })
        } else if let Some(j) = &job_name {
            ("focused", if en { format!("Working as {} right now. Don't rush me.", a_job(j)) } else { format!("在当{j}，别催。") })
        } else {
            ("focused", s("在做了，别催。", "On it. Don't rush me."))
        }
    } else if since > 14 * DAY_MS && last_event.is_some() {
        ("missing", s("欢迎回来，灯一直亮着。", "Welcome back. I kept the lights on."))
    } else if since > 60 * MIN_MS {
        if hour < 11 {
            ("waiting", s("早。我在，随时开工。", "Morning. Ready when you are."))
        } else if hour >= 22 {
            ("waiting", s("不早了，要干就快。", "It's late. Let's be quick."))
        } else {
            ("waiting", s("我在，随时开工。", "I'm here. Ready when you are."))
        }
    } else if o.today_usd >= 20.0 && o.today_usd + 1e-9 >= o.record_day_usd {
        ("proud", s("今天破了单日纪录。", "A new daily record today."))
    } else if o.today_hours >= 16.0 {
        ("proud", s("今天顶一个人干两天。", "Two days of one person's work today."))
    } else if let Some((work, pd, _, test_run, passed, usd)) = last.filter(|l| now - l.2 < 30 * MIN_MS) {
        if test_run == 1 && passed == Some(1) {
            ("happy", s("这把测试全绿。", "All tests green this time."))
        } else {
            let job = occupation::main(&work_of(&work)).map(|o| t.name_in(&o, lang).to_string()).unwrap_or_default();
            let h = fmt_hours_in(pd * k.units.minutes_per_day / 60.0, lang);
            ("happy", if en { format!("Just did {h} of {} work, worth {}.", dango_core::i18n::lower_first(&job), fmt_usd(usd)) } else { format!("刚干了 {h} 的{job}活，值 {}。", fmt_usd(usd)) })
        }
    } else if let Some(l) = o.week_leverage.filter(|l| *l >= 10.0 && o.week_cost >= 1.0) {
        ("happy", if en { format!("This week every $1 of model did ${l:.0} of work.") } else { format!("这周每花 $1，干出 ${l:.0} 的活。") })
    } else if prev_week > 0.0 && o.week_usd > prev_week * 1.2 && local.weekday().num_days_from_monday() >= 3 {
        ("happy", if en { format!("Up {} on last week.", fmt_usd(o.week_usd - prev_week)) } else { format!("这周比上周多 {}。", fmt_usd(o.week_usd - prev_week)) })
    } else if o.today_usd > 0.0 && (days == 7 || days % 30 == 0 || days % 100 == 0) {
        ("happy", if en { format!("Day {days} of working together.") } else { format!("一起干活的第 {days} 天。") })
    } else if o.today_usd > 0.0 {
        ("happy", if en { format!("{} of work today.", fmt_usd(o.today_usd)) } else { format!("今天干了 {} 的活。", fmt_usd(o.today_usd)) })
    } else {
        ("waiting", s("我在，随时开工。", "I'm here. Ready when you are."))
    };
    Ok(json!({ "name": cfg.character_name(), "mood": mood, "line": line, "days_together": days }))
}

/// The last ten turns, newest first, for all agents or one.
fn recent_turns(conn: &Connection, tool: Option<&str>) -> Result<Vec<Value>> {
    let k = ScoringConstants::builtin();
    let t = Table::builtin();
    let mut st = conn.prepare(
        "SELECT t.ended_at, t.work, t.credited_pd, t.files_touched, t.test_run, t.test_passed, t.usd, s.source FROM turns t
         JOIN sessions s ON s.id = t.session_id WHERE t.ended_at IS NOT NULL AND (?1 IS NULL OR s.source = ?1)
         ORDER BY t.ended_at DESC LIMIT 10",
    )?;
    let rows = st.query_map([tool], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, f64>(2)?,
            r.get::<_, i64>(3)?,
            r.get::<_, i64>(4)?,
            r.get::<_, Option<i64>>(5)?,
            r.get::<_, f64>(6)?,
            r.get::<_, String>(7)?,
        ))
    })?;
    Ok(rows
        .flatten()
        .map(|(at, work, pd, files, test_run, passed, usd, src)| {
            let job = occupation::main(&work_of(&work)).unwrap_or_default();
            json!({
                "at": at, "tool": tool_label(&src).0, "job": job, "name": t.name(&job), "color": t.get(&job).map(|j| j.color.as_str()),
                "hours": pd * k.units.minutes_per_day / 60.0, "usd": usd, "person_days": pd, "files": files,
                "test_passed": (test_run == 1).then(|| passed == Some(1)),
            })
        })
        .collect())
}

/// The dashboard's numbers — today, week, month, total, the last 30 days,
/// who was hired, recent turns — for all agents (`None`) or one agent.
pub fn view(conn: &Connection, tz: Tz, now: i64, tool: Option<&str>) -> Result<Value> {
    let k = ScoringConstants::builtin();
    let today = tz.date(now);
    let (usd_m, min_m, cost_m) = match tool {
        Some(t) => (format!("usd:{t}"), format!("minutes:{t}"), format!("cost:{t}")),
        None => ("usd".to_string(), "person_days".to_string(), "cost".to_string()),
    };
    // Credited minutes: per-agent counters hold minutes, the overall one person-days.
    let to_hours = |v: f64| if tool.is_some() { v / 60.0 } else { v * k.units.minutes_per_day / 60.0 };
    let c = |m: &str, scope: String| snapshot::counter(conn, m, &scope);
    let pair = |scope: String| {
        let (usd, cost) = (c(&usd_m, scope.clone()), c(&cost_m, scope.clone()));
        json!({ "usd": usd, "hours": to_hours(c(&min_m, scope)), "cost": cost, "leverage": pricing::leverage(usd, cost) })
    };

    let month_start = today.with_day(1).unwrap_or(today);
    let from = today - Duration::days(HISTORY_DAYS - 1);
    let first = from.min(month_start);
    let midnight = |d: chrono::NaiveDate| tz.ms(d.and_hms_opt(0, 0, 0).unwrap());
    let (d1, d7, d30) = (midnight(today), midnight(today - Duration::days(6)), midnight(from));
    let (usd_days, min_days, cost_days) = (metric_by_day(conn, &usd_m, first)?, metric_by_day(conn, &min_m, first)?, metric_by_day(conn, &cost_m, first)?);
    let mut turns_by_day: HashMap<String, i64> = HashMap::new();
    let mut st = conn.prepare(
        "SELECT t.ended_at FROM turns t JOIN sessions s ON s.id = t.session_id WHERE t.ended_at >= ?1 AND (?2 IS NULL OR s.source = ?2)",
    )?;
    for at in st.query_map(rusqlite::params![d30, tool], |r| r.get::<_, i64>(0))?.flatten() {
        *turns_by_day.entry(day_key(tz.date(at))).or_default() += 1;
    }
    // Today by local hour of the turn's end.
    let mut hours = [0.0f64; 24];
    let mut st = conn.prepare(
        "SELECT t.ended_at, t.usd FROM turns t JOIN sessions s ON s.id = t.session_id WHERE t.ended_at >= ?1 AND (?2 IS NULL OR s.source = ?2)",
    )?;
    for (at, usd) in st.query_map(rusqlite::params![d1, tool], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, f64>(1)?)))?.flatten() {
        hours[tz.local(at).hour() as usize] += usd;
    }
    let get = |m: &HashMap<String, f64>, d: &str| m.get(d).copied().unwrap_or(0.0);
    let days: Vec<Value> = (0..HISTORY_DAYS)
        .map(|i| {
            let key = day_key(from + Duration::days(i));
            json!({ "day": key, "usd": get(&usd_days, &key), "hours": to_hours(get(&min_days, &key)), "cost": get(&cost_days, &key),
                    "turns": turns_by_day.get(&key).copied().unwrap_or(0) })
        })
        .collect();
    let in_month = |m: &HashMap<String, f64>| m.iter().filter(|(d, _)| **d >= day_key(month_start)).map(|(_, v)| v).sum::<f64>();
    Ok(json!({
        "today": pair(format!("day:{}", day_key(today))),
        "week": pair(format!("week:{}", week_key(today))),
        "month": { "usd": in_month(&usd_days), "hours": to_hours(in_month(&min_days)), "cost": in_month(&cost_days),
                   "leverage": pricing::leverage(in_month(&usd_days), in_month(&cost_days)) },
        "total": pair("all".to_string()),
        "days": days,
        "hours": hours.to_vec(),
        "jobs": jobs(conn, d30, i64::MAX, tool)?,
        "jobs_7d": jobs(conn, d7, i64::MAX, tool)?,
        "jobs_1d": jobs(conn, d1, i64::MAX, tool)?,
        "turns": recent_turns(conn, tool)?,
    }))
}

pub fn data(conn: &Connection, tz: Tz, cfg: &Config, now: i64) -> Result<Value> {
    let o = snapshot::output(conn, tz, now);
    let (working, subagents, last_event) = snapshot::activity(conn, now)?;
    let t = Table::builtin();
    let job = current_job(conn, now)?;
    let job_json = job.as_deref().map(|j| json!({ "id": j, "name": t.name(j), "color": t.get(j).map(|x| x.color.as_str()), "scene": t.scene(j) }));
    let all = view(conn, tz, now, None)?;
    let today = tz.date(now);
    let midnight = |d: chrono::NaiveDate| tz.ms(d.and_hms_opt(0, 0, 0).unwrap());

    let lang = cfg.lang();
    let mut out = json!({
        "generated_at": now,
        "lang": lang.code(),
        "rates": { "source": t.source, "label": t.label_in(lang), "as_of": t.as_of },
        "occupations": t.occupation.iter().map(|o| json!({ "id": o.id, "name": o.name, "color": o.color, "scene": o.scene, "look": o.look })).collect::<Vec<_>>(),
        "character": character(conn, tz, cfg, &o, now, working, subagents, last_event, job.as_deref())?,
        "record": { "day_usd": o.record_day_usd },
        "total": { "hours": o.total_hours, "usd": o.total_usd, "person_days": o.total_pd, "cost": o.total_cost,
                   "leverage": pricing::leverage(o.total_usd, o.total_cost) },
        "today": { "hours": o.today_hours, "usd": o.today_usd, "person_days": o.today_pd, "cost": o.today_cost,
                   "leverage": pricing::leverage(o.today_usd, o.today_cost) },
        "week": { "hours": o.week_hours, "usd": o.week_usd, "person_days": o.week_pd, "cost": o.week_cost, "leverage": o.week_leverage },
        "month": all["month"],
        "days": all["days"],
        "hours": all["hours"],
        "jobs": all["jobs"],
        "jobs_7d": all["jobs_7d"],
        "jobs_1d": all["jobs_1d"],
        "tools": tools(conn, midnight(today - Duration::days(HISTORY_DAYS - 1)), i64::MAX)?,
        "tools_7d": tools(conn, midnight(today - Duration::days(6)), i64::MAX)?,
        "tools_1d": tools(conn, midnight(today), i64::MAX)?,
        "tools_all": tools(conn, 0, i64::MAX)?,
        "turns": all["turns"],
        "activity": { "working": working, "subagents": subagents, "last_event": last_event, "job": job_json },
        "office": office(conn, tz, now)?,
        "boss": boss(conn, tz, cfg, now)?,
    });
    localize(&mut out, lang);
    Ok(out)
}

/// Who the user is as a boss over all their history, for the panel's card
/// (user, 2026-11-07: 「加到主页面去，能显眼一些」); null before any turn.
fn boss(conn: &Connection, tz: Tz, cfg: &Config, now: i64) -> Result<Value> {
    let turns: i64 = conn.query_row("SELECT COUNT(*) FROM turns WHERE ended_at IS NOT NULL", [], |r| r.get(0))?;
    if turns == 0 {
        return Ok(Value::Null);
    }
    let r = crate::abti::result(conn, tz, cfg, now)?;
    Ok(json!({ "code": r["code"], "name": r["type"]["name"], "roast": r["type"]["roast"], "scale": r["scale"]["name"],
               "margin": r["margin"], "margin_tier": r["margin_tier"]["name"] }))
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
