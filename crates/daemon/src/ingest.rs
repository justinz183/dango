//! The processor: consumes events in order, keeps turns/sessions/daily and
//! counters up to date, runs the achievement engine and queues ceremonies.
//! Only one processor may run at a time (the daemon holds processor.lock).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::{Read, Seek, SeekFrom};

use chrono::{DateTime, Datelike, Duration, FixedOffset, NaiveDate, NaiveDateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use dango_core::achievements::{self, display_name, roman, Catalog, Category, Ctx, Rarity, Scopes, Store};
use dango_core::classify::{final_class, turn_role};
use dango_core::event::{Event, Kind, Role, Source, TaskClass};
use dango_core::expr::Val;
use dango_core::occupation::{self, Table};
use dango_core::progress::{self, coins_for_pd, stage_for, Streak, ACTIVE_DAY_PD, DEFAULT_WEEKLY_TARGET};
use dango_core::render::{fmt_pd, fmt_short, width, TurnSummary, HIGHLIGHT_WIDTH};
use dango_core::scoring::{self, leverage, ScoringConstants, TurnSignals};

use crate::config::Config;
use crate::db::{get_meta, set_meta};
use crate::paths::Paths;
use crate::spool;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

const MIN: f64 = 60_000.0;
const DAY_MS: i64 = 86_400_000;
/// Grand ceremonies wait this long after a permission prompt (SPEC 8.2).
pub const PERMISSION_QUIET_MS: i64 = 60_000;
/// The "deleted recent agent lines" window (H02).
const AGENT_LINES_WINDOW_MS: i64 = 7 * DAY_MS;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Real-time: ceremonies, settlements and record celebrations.
    Live,
    /// History import: everything is counted, nothing is celebrated.
    Backfill,
    /// Re-deriving from the events table.
    Rebuild,
}

#[derive(Debug, Clone, Copy)]
pub enum Tz {
    Local,
    Fixed(FixedOffset),
}

impl Tz {
    /// `DANGO_TZ=+08:00` (or the older `SHADOWCORP_TZ`) pins the zone (tests and replays).
    pub fn from_env() -> Tz {
        std::env::var("DANGO_TZ").or_else(|_| std::env::var("SHADOWCORP_TZ")).ok().and_then(|s| s.parse().ok()).map(Tz::Fixed).unwrap_or(Tz::Local)
    }

    pub fn local(&self, ms: i64) -> NaiveDateTime {
        let utc = DateTime::<Utc>::from_timestamp_millis(ms).unwrap_or_default();
        match self {
            Tz::Local => utc.with_timezone(&chrono::Local).naive_local(),
            Tz::Fixed(o) => utc.with_timezone(o).naive_local(),
        }
    }

    pub fn date(&self, ms: i64) -> NaiveDate {
        self.local(ms).date()
    }

    /// Unix ms of a local wall-clock time (the earlier instant when the
    /// clock is ambiguous, the next valid one when it is skipped).
    pub fn ms(&self, local: NaiveDateTime) -> i64 {
        match self {
            Tz::Local => chrono::TimeZone::from_local_datetime(&chrono::Local, &local)
                .earliest()
                .or_else(|| chrono::TimeZone::from_local_datetime(&chrono::Local, &(local + Duration::hours(1))).earliest())
                .map(|d| d.timestamp_millis())
                .unwrap_or(0),
            Tz::Fixed(o) => local.and_local_timezone(*o).unwrap().timestamp_millis(),
        }
    }
}

pub fn day_key(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

pub fn week_key(d: NaiveDate) -> String {
    let w = d.iso_week();
    format!("{}-W{:02}", w.year(), w.week())
}

/// Whether turn `tid` was opened for prompt `prompt_id` (the id itself, or
/// the `<prompt_id>:<event id>` form used when a prompt id is reused).
fn same_prompt(tid: &str, prompt_id: &str) -> bool {
    tid == prompt_id || tid.strip_prefix(prompt_id).is_some_and(|rest| rest.starts_with(':'))
}

pub fn parse_day(s: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").ok()
}

/// Running aggregates of a turn, stored as JSON in turns.agg.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
struct TurnAgg {
    file_ids: BTreeSet<String>,
    dir_ids: BTreeSet<String>,
    roles: Vec<Role>,
    langs: BTreeSet<String>,
    lines_added: u32,
    lines_removed: u32,
    test_run: bool,
    test_first: Option<bool>,
    test_last: Option<bool>,
    /// Test commands that failed in this turn (three make the office fume).
    test_fails: u32,
    test_fixed: bool,
    commit: bool,
    merge: bool,
    push: bool,
    agent_calls: u32,
    /// Subagents set off and finished (transcripts give both; the hooks
    /// give only the stops). Running = starts − stops, when there are starts.
    #[serde(default)]
    subagent_starts: u32,
    subagent_stops: u32,
    file_age_max: Option<u32>,
    migration: bool,
    recent_agent_removed: u32,
    last_activity: i64,
    /// Minutes per occupation from the turn's steps.
    work: BTreeMap<String, f64>,
    /// What the steps so far add up to (files touched, commands run), so a
    /// file counts once and repeats count less (occupation::TurnSteps).
    steps: occupation::TurnSteps,
    /// What the turn is about (an occupation id), from the prompt or a connector.
    topic: Option<String>,
}

impl TurnAgg {
    fn signals(&self) -> TurnSignals {
        TurnSignals {
            files: self.file_ids.len() as u32,
            lines: self.lines_added + self.lines_removed,
            test_run: self.test_run,
            subagents: self.agent_calls.max(self.subagent_stops),
            merged: self.commit || self.merge,
        }
    }

    /// Minutes per occupation the whole turn is worth (docs/DESIGN.md §3).
    fn work(&self) -> BTreeMap<String, f64> {
        let mut w = self.work.clone();
        occupation::remap(&mut w, self.topic.as_deref());
        occupation::finish(w, self.agent_calls.max(self.subagent_stops), self.topic.as_deref())
    }
}

fn scaled(work: &BTreeMap<String, f64>, k: f64) -> BTreeMap<String, f64> {
    work.iter().map(|(o, m)| (o.clone(), m * k)).collect()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
struct SessState {
    counted: bool,
    open_turn: Option<String>,
    last_turn_end: Option<i64>,
    last_test_failed: bool,
    /// The last turn's topic and when it ended: a prompt with none of its
    /// own ("继续") stays on it for a while (occupation::TOPIC_MEMORY_MINUTES).
    last_topic: Option<String>,
    last_topic_at: Option<i64>,
    /// A permission prompt the user has not answered yet: the office shows
    /// the turn's job waiting until the next event of the session.
    waiting_since: Option<i64>,
}

struct TurnRow {
    session_id: String,
    started_at: i64,
    ended_at: Option<i64>,
    prompt_class: TaskClass,
    human_minutes: f64,
    credited_pd: f64,
    agg: TurnAgg,
    paid: BTreeMap<String, f64>,
    usd: f64,
}

#[derive(Debug, Clone)]
enum Highlight {
    Unlock { id: String, tier: u32 },
    Ring { pd: f64, target: f64 },
    Record { key: String, new: f64, old: f64 },
}

pub struct Processor {
    pub conn: Connection,
    pub mode: Mode,
    pub tz: Tz,
    pub cfg: Config,
    cat: &'static Catalog,
    k: &'static ScoringConstants,
    occ: &'static Table,
    counters: HashMap<(String, String), f64>,
    dirty: HashSet<(String, String)>,
    unlocked: Option<HashMap<String, u32>>,
    /// Finished-turn summaries waiting for the Stop hook, by session.
    pub settlements: HashMap<String, TurnSummary>,
    pending: Vec<Highlight>,
    now: i64,
    source: Source,
}

impl Store for Processor {
    fn counter(&mut self, metric: &str, scope: &str) -> f64 {
        self.ctr(metric, scope)
    }
    fn add(&mut self, metric: &str, scope: &str, by: f64) {
        self.add_ctr(metric, scope, by)
    }
    fn unlocked_tier(&mut self, id: &str) -> u32 {
        self.unlocked_map().get(id).copied().unwrap_or(0)
    }
}

impl Processor {
    pub fn new(conn: Connection, mode: Mode, tz: Tz, cfg: Config) -> Processor {
        Processor {
            conn,
            mode,
            tz,
            cfg,
            cat: Catalog::builtin(),
            k: ScoringConstants::builtin(),
            occ: Table::builtin(),
            counters: HashMap::new(),
            dirty: HashSet::new(),
            unlocked: None,
            settlements: HashMap::new(),
            pending: Vec::new(),
            now: 0,
            source: Source::ClaudeCode,
        }
    }

    fn live(&self) -> bool {
        self.mode == Mode::Live
    }

    // ---- storage helpers -------------------------------------------------

    pub fn ctr(&mut self, metric: &str, scope: &str) -> f64 {
        let key = (metric.to_string(), scope.to_string());
        if let Some(v) = self.counters.get(&key) {
            return *v;
        }
        let v = self
            .conn
            .prepare_cached("SELECT value FROM counters WHERE metric = ?1 AND scope = ?2")
            .and_then(|mut st| st.query_row([metric, scope], |r| r.get::<_, f64>(0)).optional())
            .ok()
            .flatten()
            .unwrap_or(0.0);
        self.counters.insert(key, v);
        v
    }

    fn set_ctr(&mut self, metric: &str, scope: &str, v: f64) {
        let key = (metric.to_string(), scope.to_string());
        self.counters.insert(key.clone(), v);
        self.dirty.insert(key);
    }

    pub fn add_ctr(&mut self, metric: &str, scope: &str, by: f64) {
        let v = self.ctr(metric, scope) + by;
        self.set_ctr(metric, scope, v);
    }

    fn add_in(&mut self, metric: &str, by: f64, sc: &Scopes, scopes: &[&str]) {
        for s in scopes {
            if let Some(key) = sc.key(s) {
                self.add_ctr(metric, &key, by);
            }
        }
    }

    fn flush(&mut self) -> Result<()> {
        let dirty = std::mem::take(&mut self.dirty);
        let mut st = self.conn.prepare_cached(
            "INSERT INTO counters (metric, scope, value) VALUES (?1, ?2, ?3)
             ON CONFLICT(metric, scope) DO UPDATE SET value = excluded.value",
        )?;
        for key in dirty {
            st.execute(params![key.0, key.1, self.counters[&key]])?;
        }
        Ok(())
    }

    /// Drops caches so the next read sees the database (after another
    /// writer, such as a test or a later social feature, changed it).
    pub fn forget_caches(&mut self) {
        self.counters.clear();
        self.dirty.clear();
        self.unlocked = None;
    }

    fn unlocked_map(&mut self) -> &mut HashMap<String, u32> {
        if self.unlocked.is_none() {
            let mut m = HashMap::new();
            if let Ok(mut st) = self.conn.prepare("SELECT achievement_id, MAX(tier) FROM unlocks GROUP BY achievement_id") {
                if let Ok(rows) = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, u32>(1)?))) {
                    m.extend(rows.flatten());
                }
            }
            self.unlocked = Some(m);
        }
        self.unlocked.as_mut().unwrap()
    }

    fn meta(&self, key: &str) -> Result<Option<String>> {
        Ok(get_meta(&self.conn, key)?)
    }

    fn set_meta(&self, key: &str, value: &str) -> Result<()> {
        Ok(set_meta(&self.conn, key, value)?)
    }

    fn meta_day(&self, key: &str) -> Result<Option<NaiveDate>> {
        Ok(self.meta(key)?.as_deref().and_then(parse_day))
    }

    pub fn begin(&mut self) -> Result<()> {
        self.conn.execute_batch("BEGIN IMMEDIATE")?;
        Ok(())
    }

    pub fn commit(&mut self) -> Result<()> {
        self.flush()?;
        self.conn.execute_batch("COMMIT")?;
        Ok(())
    }

    pub fn rollback(&mut self) {
        let _ = self.conn.execute_batch("ROLLBACK");
        self.forget_caches();
    }

    fn scopes(&self, ts: i64, session: Option<&str>) -> Scopes {
        let d = self.tz.date(ts);
        Scopes { session: session.map(str::to_string), day: day_key(d), week: week_key(d) }
    }

    fn time_fields(&self, ts: i64) -> HashMap<String, Val> {
        let t = self.tz.local(ts);
        let mut f = HashMap::new();
        f.insert("hour".into(), Val::Num(chrono::Timelike::hour(&t) as f64));
        f.insert("minute".into(), Val::Num(chrono::Timelike::minute(&t) as f64));
        f.insert("month".into(), Val::Num(t.month() as f64));
        f.insert("day".into(), Val::Num(t.day() as f64));
        f.insert("year".into(), Val::Num(t.year() as f64));
        f.insert("weekday".into(), Val::Num(t.weekday().number_from_monday() as f64));
        f.insert("source".into(), Val::Str(self.source.as_str().into()));
        f
    }

    // ---- event entry points ---------------------------------------------

    /// Processes one event inside a savepoint. Returns Ok(false) for a
    /// duplicate id. An event that fails is rolled back alone and skipped,
    /// so one bad line never blocks the spool.
    pub fn handle(&mut self, ev: &Event) -> Result<bool> {
        self.conn.execute_batch("SAVEPOINT ev")?;
        match self.handle_inner(ev).and_then(|new| self.flush().map(|_| new)) {
            Ok(new) => {
                self.conn.execute_batch("RELEASE ev")?;
                Ok(new)
            }
            Err(e) => {
                self.conn.execute_batch("ROLLBACK TO ev; RELEASE ev")?;
                self.forget_caches();
                Err(e)
            }
        }
    }

    fn handle_inner(&mut self, ev: &Event) -> Result<bool> {
        let Some(ts) = ev.ts_ms() else { return Ok(false) };
        let payload = serde_json::to_string(&ev.payload)?;
        let n = self
            .conn
            .prepare_cached(
                "INSERT OR IGNORE INTO events (id, ts, source, kind, session_id, turn_id, cwd_hash, payload)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            )?
            .execute(params![ev.id, ts, ev.source.as_str(), ev.kind.as_str(), ev.session_id, ev.turn_id, ev.cwd_hash, payload])?;
        if n == 0 {
            return Ok(false);
        }
        // Codex is counted from its own logs (codex_tail), as backfill
        // events. What its hooks sent before that (2026-10-29) is kept but
        // not counted, so a turn seen both ways counts once.
        if ev.source == Source::Codex {
            return Ok(false);
        }
        self.now = ts;
        self.source = ev.origin();
        // Each tool's first live event: its history before that comes from
        // backfill ("live_since" is Claude Code's, from before Codex).
        let live_key = match ev.source {
            Source::ClaudeCode => "live_since".to_string(),
            s => format!("live_since:{}", s.as_str()),
        };
        if ev.source != Source::Backfill && self.mode != Mode::Rebuild && self.meta(&live_key)?.is_none() {
            self.set_meta(&live_key, &ts.to_string())?;
            if self.meta("installed_at")?.is_none() {
                self.set_meta("installed_at", &ts.to_string())?;
            }
        }
        self.rollover(ts)?;
        match ev.kind {
            Kind::SessionStart => self.on_session_start(ev, ts)?,
            Kind::Prompt => self.on_prompt(ev, ts)?,
            Kind::Tool => self.on_tool(ev, ts)?,
            Kind::SubagentStart => self.on_subagent_start(ev, ts)?,
            Kind::SubagentStop => self.on_subagent_stop(ev, ts)?,
            Kind::TurnEnd => self.on_turn_end(ev, ts)?,
            Kind::Notification => {
                if ev.payload.notification_type.as_deref() == Some("permission_prompt") {
                    self.set_meta("last_permission_ms", &ts.to_string())?;
                    if let Some(sid) = ev.session_id.as_deref() {
                        let mut st = self.sess(sid)?;
                        st.waiting_since = Some(ts);
                        self.save_sess(sid, &st)?;
                    }
                }
            }
            Kind::SessionEnd => self.on_session_end(ev, ts)?,
            Kind::Commit => self.on_commit(ev, ts)?,
            Kind::PreCompact => {}
            Kind::Usage => self.on_usage(ev)?,
        }
        // Anything the session does next answers its permission prompt.
        if matches!(ev.kind, Kind::Tool | Kind::TurnEnd | Kind::Prompt | Kind::SubagentStart | Kind::SubagentStop) {
            if let Some(sid) = ev.session_id.as_deref() {
                let mut st = self.sess(sid)?;
                if st.waiting_since.is_some() {
                    st.waiting_since = None;
                    self.save_sess(sid, &st)?;
                }
            }
        }
        Ok(true)
    }

    /// Reads new complete lines from every spool file and processes them.
    pub fn ingest_spool(&mut self, paths: &Paths) -> Result<usize> {
        let mut n = 0;
        let files = spool::files(paths);
        for f in &files {
            let name = f.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
            let key = format!("spool_offset:{name}");
            let off: u64 = self.meta(&key)?.and_then(|v| v.parse().ok()).unwrap_or(0);
            let len = fs::metadata(f).map(|m| m.len()).unwrap_or(0);
            if len <= off {
                continue;
            }
            let mut file = fs::File::open(f)?;
            file.seek(SeekFrom::Start(off))?;
            let mut buf = Vec::with_capacity((len - off) as usize);
            file.take(len - off).read_to_end(&mut buf)?;
            let Some(last_nl) = buf.iter().rposition(|b| *b == b'\n') else { continue };
            let chunk = &buf[..=last_nl];
            self.begin()?;
            for line in chunk.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
                if let Ok(ev) = serde_json::from_slice::<Event>(line) {
                    match self.handle(&ev) {
                        Ok(true) => n += 1,
                        Ok(false) => {}
                        Err(e) => eprintln!("dango: skipped event {}: {e}", ev.id),
                    }
                }
            }
            if let Err(e) = self.set_meta(&key, &(off + chunk.len() as u64).to_string()) {
                self.rollback();
                return Err(e);
            }
            self.commit()?;
        }
        // Retention: drop consumed spool files older than a week.
        let today = Utc::now().date_naive();
        for f in files {
            let Some(day) = spool::file_day(&f) else { continue };
            if (today - day).num_days() <= spool::RETENTION_DAYS {
                continue;
            }
            let name = f.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
            let key = format!("spool_offset:{name}");
            let off: u64 = self.meta(&key)?.and_then(|v| v.parse().ok()).unwrap_or(0);
            if fs::metadata(&f).map(|m| m.len()).unwrap_or(u64::MAX) <= off {
                let _ = fs::remove_file(&f);
                self.conn.execute("DELETE FROM meta WHERE key = ?1", [key])?;
            }
        }
        Ok(n)
    }

    // ---- days and weeks -------------------------------------------------

    fn rollover(&mut self, ts: i64) -> Result<()> {
        let today = self.tz.date(ts);
        match self.meta_day("last_day")? {
            None => self.set_meta("last_day", &day_key(today))?,
            Some(last) if today > last => {
                let mut d = last;
                while d < today {
                    d = d.succ_opt().unwrap();
                    if d.weekday() == chrono::Weekday::Mon {
                        self.on_new_week(d)?;
                    }
                }
                self.set_meta("last_day", &day_key(today))?;
            }
            _ => {}
        }
        Ok(())
    }

    /// Recomputes an automatic weekly target on the first Monday of a month,
    /// from week 5 on (SPEC 6.3).
    fn on_new_week(&mut self, monday: NaiveDate) -> Result<()> {
        if self.cfg.general.weekly_target > 0.0 || monday.day() > 7 {
            return Ok(());
        }
        let Some(first) = self.meta_day("first_active_day")? else { return Ok(()) };
        if (monday - first).num_days() < 28 {
            return Ok(());
        }
        let weeks: Vec<f64> = (1..=4)
            .map(|i| {
                let w = week_key(monday - Duration::days(7 * i));
                self.ctr("person_days", &format!("week:{w}"))
            })
            .collect();
        let target = progress::auto_weekly_target(&weeks);
        self.set_meta("weekly_target", &target.to_string())
    }

    pub fn weekly_target(&self) -> f64 {
        if self.cfg.general.weekly_target > 0.0 {
            return self.cfg.general.weekly_target;
        }
        self.meta("weekly_target").ok().flatten().and_then(|v| v.parse().ok()).unwrap_or(DEFAULT_WEEKLY_TARGET)
    }

    fn streak(&self) -> Result<Streak> {
        Ok(self.meta("streak")?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default())
    }

    fn save_streak(&mut self, s: &Streak) -> Result<()> {
        self.set_meta("streak", &serde_json::to_string(s)?)?;
        self.conn.execute("UPDATE wallet SET freeze_tokens = ?1 WHERE id = 1", [s.tokens])?;
        self.set_ctr("streak", "all", s.current as f64);
        Ok(())
    }

    fn on_day_active(&mut self, day: NaiveDate) -> Result<()> {
        let mut s = self.streak()?;
        s.mark_active(day);
        self.save_streak(&s)?;
        self.record("max_streak", s.longest as f64)?;
        if self.meta_day("last_active_day")?.map_or(true, |d| day > d) {
            self.set_meta("last_active_day", &day_key(day))?;
        }
        if self.meta("first_active_day")?.is_none() {
            self.set_meta("first_active_day", &day_key(day))?;
        }
        Ok(())
    }

    fn upsert_daily(&mut self, sc: &Scopes) -> Result<()> {
        let k = format!("day:{}", sc.day);
        let pd = self.ctr("person_days", &k);
        let am = self.ctr("active_minutes", &k);
        let turns = self.ctr("turns", &k);
        let sessions = self.ctr("sessions", &k);
        self.conn.execute(
            "INSERT INTO daily (day, person_days, active_minutes, turns, sessions, is_active) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(day) DO UPDATE SET person_days = excluded.person_days, active_minutes = excluded.active_minutes,
               turns = excluded.turns, sessions = excluded.sessions, is_active = excluded.is_active",
            params![sc.day, pd, am, turns as i64, sessions as i64, (pd + 1e-9 >= ACTIVE_DAY_PD) as i64],
        )?;
        Ok(())
    }

    fn mark_source(&mut self, ts: i64) -> Result<()> {
        let src = match self.source {
            Source::Backfill => Source::ClaudeCode,
            s => s,
        };
        let name = format!("src:{}", src.as_str());
        if self.ctr(&name, "all") == 0.0 {
            self.set_ctr(&name, "all", 1.0);
            self.add_ctr("sources", "all", 1.0);
        }
        let day = format!("day:{}", day_key(self.tz.date(ts)));
        if self.ctr(&name, &day) == 0.0 {
            self.set_ctr(&name, &day, 1.0);
            if self.ctr("src:claude_code", &day) > 0.0 && self.ctr("src:codex", &day) > 0.0 {
                self.add_ctr("dual_days", "all", 1.0);
            }
        }
        Ok(())
    }

    // ---- sessions ---------------------------------------------------------

    fn ensure_session(&mut self, sid: &str, ts: i64) -> Result<()> {
        self.conn.execute(
            "INSERT OR IGNORE INTO sessions (id, source, started_at) VALUES (?1, ?2, ?3)",
            params![sid, self.source.as_str(), ts],
        )?;
        Ok(())
    }

    fn sess(&self, sid: &str) -> Result<SessState> {
        let s: Option<String> = self.conn.query_row("SELECT state FROM sessions WHERE id = ?1", [sid], |r| r.get(0)).optional()?;
        Ok(s.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default())
    }

    fn save_sess(&self, sid: &str, st: &SessState) -> Result<()> {
        self.conn.execute("UPDATE sessions SET state = ?2 WHERE id = ?1", params![sid, serde_json::to_string(st)?])?;
        Ok(())
    }

    fn days_since_last_active(&self, ts: i64) -> Result<f64> {
        let today = self.tz.date(ts);
        Ok(match self.meta_day("last_active_day")? {
            Some(d) if d < today => (today - d).num_days() as f64,
            _ => 0.0,
        })
    }

    fn on_session_start(&mut self, ev: &Event, ts: i64) -> Result<()> {
        let Some(sid) = ev.session_id.as_deref() else { return Ok(()) };
        self.ensure_session(sid, ts)?;
        let mut st = self.sess(sid)?;
        let src = ev.payload.session_source.as_deref().unwrap_or("startup");
        let new_session = !st.counted && matches!(src, "startup" | "clear");
        let sc = self.scopes(ts, Some(sid));
        let mut f = self.time_fields(ts);
        f.insert("days_since_last_active".into(), Val::Num(self.days_since_last_active(ts)?));
        f.insert("new_session".into(), Val::Bool(new_session));
        if new_session {
            st.counted = true;
            self.save_sess(sid, &st)?;
            self.add_in("sessions", 1.0, &sc, &["all", "day", "week"]);
            self.upsert_daily(&sc)?;
        }
        self.mark_source(ts)?;
        self.eval("session_start", f, &sc)
    }

    fn on_session_end(&mut self, ev: &Event, ts: i64) -> Result<()> {
        let Some(sid) = ev.session_id.as_deref() else { return Ok(()) };
        self.ensure_session(sid, ts)?;
        if let Some(open) = self.sess(sid)?.open_turn {
            self.close_turn(sid, &open, None)?;
        }
        let sc = self.scopes(ts, Some(sid));
        let skey = sc.key("session").unwrap();
        let lev = leverage(self.ctr("human_minutes", &skey), self.ctr("active_minutes", &skey));
        if let Some(l) = lev {
            self.set_ctr("leverage", &skey, l);
            self.record("max_leverage", l)?;
        }
        self.conn.execute("UPDATE sessions SET ended_at = ?2, leverage = ?3 WHERE id = ?1", params![sid, ts, lev])?;
        let mut f = self.time_fields(ts);
        self.session_fields(&skey, &mut f);
        self.eval("session_end", f, &sc)
    }

    fn session_fields(&mut self, skey: &str, f: &mut HashMap<String, Val>) {
        for m in ["active_minutes", "lines_added", "lines_removed", "files_touched", "subagents", "turns", "person_days"] {
            f.insert(format!("session.{m}"), Val::Num(self.ctr(m, skey)));
        }
    }

    // ---- turns ------------------------------------------------------------

    fn turn(&self, tid: &str) -> Result<Option<TurnRow>> {
        Ok(self
            .conn
            .query_row(
                "SELECT session_id, started_at, ended_at, task_class, human_minutes, credited_pd, agg, work, usd FROM turns WHERE id = ?1",
                [tid],
                |r| {
                    Ok(TurnRow {
                        session_id: r.get(0)?,
                        started_at: r.get(1)?,
                        ended_at: r.get(2)?,
                        prompt_class: TaskClass::parse(&r.get::<_, String>(3)?).unwrap_or(TaskClass::Other),
                        human_minutes: r.get(4)?,
                        credited_pd: r.get(5)?,
                        agg: serde_json::from_str(&r.get::<_, String>(6)?).unwrap_or_default(),
                        paid: serde_json::from_str(&r.get::<_, String>(7)?).unwrap_or_default(),
                        usd: r.get(8)?,
                    })
                },
            )
            .optional()?)
    }

    fn save_agg(&self, tid: &str, agg: &TurnAgg) -> Result<()> {
        self.conn.execute("UPDATE turns SET agg = ?2 WHERE id = ?1", params![tid, serde_json::to_string(agg)?])?;
        Ok(())
    }

    fn create_turn(&self, tid: &str, sid: &str, ts: i64, class: TaskClass, correction: bool, agg: TurnAgg) -> Result<()> {
        let agg = TurnAgg { last_activity: ts, ..agg };
        self.conn.execute(
            "INSERT OR IGNORE INTO turns (id, session_id, started_at, task_class, is_correction, scoring_version, agg)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![tid, sid, ts, class.as_str(), correction as i64, self.k.version, serde_json::to_string(&agg)?],
        )?;
        Ok(())
    }

    /// The turn a tool-level event belongs to: its own turn id if known,
    /// else the session's open turn, else its latest turn, else a new one.
    fn turn_for(&mut self, ev: &Event, sid: &str, ts: i64) -> Result<String> {
        if let (Some(open), Some(t)) = (self.sess(sid)?.open_turn, &ev.turn_id) {
            if same_prompt(&open, t) {
                return Ok(open);
            }
        }
        if let Some(t) = &ev.turn_id {
            if self.turn(t)?.is_some_and(|r| r.session_id == sid) {
                return Ok(t.clone());
            }
        }
        let mut st = self.sess(sid)?;
        if let Some(t) = st.open_turn.clone() {
            return Ok(t);
        }
        let latest: Option<String> = self
            .conn
            .query_row("SELECT id FROM turns WHERE session_id = ?1 ORDER BY started_at DESC LIMIT 1", [sid], |r| r.get(0))
            .optional()?;
        if let Some(t) = latest {
            return Ok(t);
        }
        let tid = ev.turn_id.clone().unwrap_or_else(|| format!("imp_{}", ev.id));
        self.create_turn(&tid, sid, ts, TaskClass::Other, false, TurnAgg::default())?;
        st.open_turn = Some(tid.clone());
        self.save_sess(sid, &st)?;
        Ok(tid)
    }

    fn on_prompt(&mut self, ev: &Event, ts: i64) -> Result<()> {
        let Some(sid) = ev.session_id.as_deref() else { return Ok(()) };
        self.ensure_session(sid, ts)?;
        let base = ev.turn_id.clone().unwrap_or_else(|| ev.id.clone());
        let open = self.sess(sid)?.open_turn;
        // A message injected mid-turn (a task notification, queued input)
        // fires UserPromptSubmit again with the same prompt_id: the turn
        // simply continues, and its text is not the user's request.
        if open.as_deref().is_some_and(|o| same_prompt(o, &base)) {
            return Ok(());
        }
        if let Some(open) = open {
            // No Stop came (interrupted): close it at its last activity.
            self.close_turn(sid, &open, None)?;
        }
        let p = &ev.payload;
        let correction = p.is_correction.unwrap_or(false);
        let sc = self.scopes(ts, Some(sid));
        if correction {
            self.add_in("corrections", 1.0, &sc, &["all", "session"]);
            self.set_ctr("clean_streak", "all", 0.0);
            self.set_ctr("clean_streak", &sc.key("session").unwrap(), 0.0);
        }
        // A finished turn's id can come back when the agent is woken again
        // under the same prompt; that work is scored as a turn of its own.
        let tid = if self.turn(&base)?.is_some() { format!("{base}:{}", ev.id) } else { base };
        let mut st = self.sess(sid)?;
        let remembered = st
            .last_topic
            .clone()
            .filter(|_| st.last_topic_at.is_some_and(|at| (ts - at) as f64 / MIN <= occupation::TOPIC_MEMORY_MINUTES));
        // A prompt that reads as several things equally stays on what the
        // session was already doing.
        let ties: Vec<String> = p.topic_ties.iter().flatten().map(|t| self.occ.canon(t).to_string()).collect();
        let topic = match (p.topic(), &remembered) {
            (Some(_), Some(r)) if ties.contains(r) => Some(r.clone()),
            (t, r) => t.or(r.clone()),
        };
        let agg = TurnAgg { topic, ..Default::default() };
        self.create_turn(&tid, sid, ts, p.task_class.unwrap_or(TaskClass::Other), correction, agg)?;
        st.open_turn = Some(tid);
        self.save_sess(sid, &st)?;
        let mut f = self.time_fields(ts);
        f.insert("is_correction".into(), Val::Bool(correction));
        f.insert("prompt_repeat".into(), Val::Num(p.prompt_repeat.unwrap_or(1) as f64));
        self.eval("prompt", f, &sc)
    }

    fn on_tool(&mut self, ev: &Event, ts: i64) -> Result<()> {
        let Some(sid) = ev.session_id.as_deref() else { return Ok(()) };
        self.ensure_session(sid, ts)?;
        let tid = self.turn_for(ev, sid, ts)?;
        let Some(row) = self.turn(&tid)? else { return Ok(()) };
        let mut agg = row.agg;
        let p = &ev.payload;
        let (added, removed) = (p.lines_added.unwrap_or(0), p.lines_removed.unwrap_or(0));
        agg.lines_added += added;
        agg.lines_removed += removed;
        agg.file_ids.extend(p.file_ids.iter().cloned());
        agg.dir_ids.extend(p.dir_ids.iter().cloned());
        agg.roles.extend(p.roles.iter().copied());
        agg.langs.extend(p.languages.iter().cloned());
        agg.migration |= p.migration_path.unwrap_or(false);
        if let Some(age) = p.file_ages_days_max {
            agg.file_age_max = Some(agg.file_age_max.unwrap_or(0).max(age));
        }
        for fid in &p.file_ids {
            agg.recent_agent_removed += self.track_agent_lines(fid, ts, added, removed)?;
        }
        if p.test_cmd == Some(true) {
            let passed = p.test_passed.unwrap_or(false);
            let mut st = self.sess(sid)?;
            agg.test_run = true;
            agg.test_first.get_or_insert(passed);
            agg.test_last = Some(passed);
            if !passed {
                agg.test_fails += 1;
            }
            if passed && st.last_test_failed {
                agg.test_fixed = true;
            }
            st.last_test_failed = !passed;
            self.save_sess(sid, &st)?;
        }
        match p.git_action.map(|g| g.as_str()) {
            Some("commit") => agg.commit = true,
            Some("merge") => agg.merge = true,
            Some("push") => agg.push = true,
            _ => {}
        }
        agg.agent_calls += p.subagents.unwrap_or(0);
        if let (Some(o), Some(m)) = (&p.occupation, p.minutes) {
            // Prose is counted from its words at today's pace (2,000 an
            // hour); from 10-29 to 10-31 it was stored as research. Shell
            // scripts are ops' since 2026-11-07 (stored as the software
            // engineer's before).
            let prose = (o == "writer" || o == "research" || o == "pm") && p.words.is_some();
            let shell = o == "swe" && p.languages.iter().any(|l| l == "shell");
            let o = if prose { if o == "pm" { "pm" } else { "writer" } } else if shell { "ops" } else { o.as_str() }.to_string();
            let m = match (p.tool.as_deref(), p.file_ids.first()) {
                // An edit: its file counts once a turn (code by lines, prose
                // by words, a config or an image flat).
                (Some("edit" | "write"), Some(f)) => {
                    let price = if prose {
                        occupation::EditPrice::Prose(p.words.unwrap_or(0))
                    } else if matches!(o.as_str(), "swe" | "web" | "qa") || shell {
                        occupation::EditPrice::Code(added + removed)
                    } else {
                        occupation::EditPrice::Flat(m)
                    };
                    agg.steps.edit(f, price)
                }
                // A command or a lookup: repeats count less.
                (Some("bash" | "web" | "mcp"), _) => agg.steps.run(&o, m),
                _ => m,
            };
            *agg.work.entry(o).or_default() += m;
        }
        if agg.topic.is_none() {
            agg.topic = p.topic();
        }
        agg.last_activity = agg.last_activity.max(ts);
        self.save_agg(&tid, &agg)?;

        let sc = self.scopes(ts, Some(sid));
        let mut f = self.time_fields(ts);
        f.insert("agent".into(), Val::Bool(true));
        f.insert("tool".into(), Val::Str(p.tool.clone().unwrap_or_default()));
        if let Some(g) = p.git_action {
            f.insert("git_action".into(), Val::Str(g.as_str().into()));
        }
        self.eval("tool", f, &sc)?;
        if row.ended_at.is_some() {
            self.rescore(&tid)?;
        }
        Ok(())
    }

    /// Lines removed from what the agent wrote in this file within 7 days.
    fn track_agent_lines(&mut self, fid: &str, ts: i64, added: u32, removed: u32) -> Result<u32> {
        let prev: Option<(i64, i64)> = self
            .conn
            .query_row("SELECT last_write, lines FROM agent_files WHERE file_id = ?1", [fid], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?;
        let (recent, kept) = match prev {
            Some((at, lines)) if ts - at <= AGENT_LINES_WINDOW_MS => {
                let r = (removed as i64).min(lines);
                (r as u32, lines - r)
            }
            _ => (0, 0),
        };
        self.conn.execute(
            "INSERT INTO agent_files (file_id, last_write, lines) VALUES (?1, ?2, ?3)
             ON CONFLICT(file_id) DO UPDATE SET last_write = excluded.last_write, lines = excluded.lines",
            params![fid, ts, kept + added as i64],
        )?;
        Ok(recent)
    }

    /// A subagent set off: counted toward the helpers at work, nothing
    /// credited (its work is credited when it finishes).
    fn on_subagent_start(&mut self, ev: &Event, ts: i64) -> Result<()> {
        let Some(sid) = ev.session_id.as_deref() else { return Ok(()) };
        self.ensure_session(sid, ts)?;
        let tid = self.turn_for(ev, sid, ts)?;
        let Some(row) = self.turn(&tid)? else { return Ok(()) };
        let mut agg = row.agg;
        agg.subagent_starts += 1;
        agg.last_activity = agg.last_activity.max(ts);
        self.save_agg(&tid, &agg)
    }

    fn on_subagent_stop(&mut self, ev: &Event, ts: i64) -> Result<()> {
        let Some(sid) = ev.session_id.as_deref() else { return Ok(()) };
        self.ensure_session(sid, ts)?;
        let tid = self.turn_for(ev, sid, ts)?;
        let Some(row) = self.turn(&tid)? else { return Ok(()) };
        let mut agg = row.agg;
        agg.subagent_stops += 1;
        agg.last_activity = agg.last_activity.max(ts);
        self.save_agg(&tid, &agg)?;
        if row.ended_at.is_some() {
            self.rescore(&tid)?;
        }
        Ok(())
    }

    fn on_turn_end(&mut self, ev: &Event, ts: i64) -> Result<()> {
        if ev.payload.stop_hook_active == Some(true) {
            return Ok(());
        }
        let Some(sid) = ev.session_id.as_deref() else { return Ok(()) };
        self.ensure_session(sid, ts)?;
        let open = self.sess(sid)?.open_turn;
        let tid = match open {
            Some(t) => t,
            None => match &ev.turn_id {
                Some(t) if self.turn(t)?.is_some_and(|r| r.ended_at.is_none()) => t.clone(),
                _ => return Ok(()),
            },
        };
        self.close_turn(sid, &tid, Some(ts))
    }

    fn on_commit(&mut self, ev: &Event, ts: i64) -> Result<()> {
        self.mark_source(ts)?;
        let sc = self.scopes(ts, ev.session_id.as_deref());
        let mut f = self.time_fields(ts);
        if let Some(g) = ev.payload.git_action {
            f.insert("git_action".into(), Val::Str(g.as_str().into()));
        }
        f.insert("agent".into(), Val::Bool(ev.payload.subagents.unwrap_or(0) > 0));
        self.eval("commit", f, &sc)
    }

    /// Scores a finished turn and moves every counter it touches. `end` is
    /// the Stop time; None closes an interrupted turn at its last activity.
    fn close_turn(&mut self, sid: &str, tid: &str, end: Option<i64>) -> Result<()> {
        let Some(row) = self.turn(tid)? else { return Ok(()) };
        if row.ended_at.is_some() {
            return Ok(());
        }
        let agg = row.agg;
        let end_ts = end.unwrap_or(agg.last_activity).max(row.started_at);
        let class = final_class(row.prompt_class, agg.test_run, agg.migration);
        let sig = agg.signals();
        let work = agg.work();
        let h: f64 = work.values().sum();
        let sc = self.scopes(end_ts, Some(sid));
        let (dkey, wkey, skey) = (sc.key("day").unwrap(), sc.key("week").unwrap(), sc.key("session").unwrap());
        let day_pd = self.ctr("person_days", &dkey);
        let week_pd = self.ctr("person_days", &wkey);
        // Every minute counts: no turn, day or week cap (2026-10-29).
        let mpd = self.k.units.minutes_per_day;
        let credited = h / mpd;
        let paid = work.clone();
        let usd = self.occ.usd(&paid);
        let role = turn_role(class, &agg.roles, agg.dir_ids.len());
        let duration = (end_ts - row.started_at) as f64 / MIN;

        let mut st = self.sess(sid)?;
        let gap = st.last_turn_end.map(|e| scoring::active_gap((row.started_at - e) as f64 / MIN)).unwrap_or(0.0);
        let active = duration + gap;
        st.last_turn_end = Some(end_ts);
        if agg.topic.is_some() {
            st.last_topic = agg.topic.clone();
            st.last_topic_at = Some(end_ts);
        }
        if st.open_turn.as_deref() == Some(tid) {
            st.open_turn = None;
        }
        self.save_sess(sid, &st)?;

        let git = if agg.merge {
            Some("merge")
        } else if agg.commit {
            Some("commit")
        } else if agg.push {
            Some("push")
        } else {
            None
        };
        self.conn.execute(
            "UPDATE turns SET ended_at = ?2, task_class = ?3, role_card = ?4, files_touched = ?5, lines_added = ?6,
               lines_removed = ?7, test_run = ?8, test_passed = ?9, git_action = ?10, subagents = ?11,
               human_minutes = ?12, credited_pd = ?13, scoring_version = ?14, work = ?15, usd = ?16 WHERE id = ?1",
            params![
                tid, end_ts, class.as_str(), role.map(|r| r.as_str()), sig.files, agg.lines_added, agg.lines_removed,
                agg.test_run as i64, agg.test_last.map(|b| b as i64), git, sig.subagents, h, credited, self.k.version,
                serde_json::to_string(&paid)?, usd
            ],
        )?;
        self.conn.execute(
            "UPDATE sessions SET human_minutes = human_minutes + ?2, active_minutes = active_minutes + ?3,
               files_touched = files_touched + ?4, subagents_max = MAX(subagents_max, ?5) WHERE id = ?1",
            params![sid, h, active, sig.files, sig.subagents],
        )?;

        let old_total = self.ctr("person_days", "all");
        let all4 = ["all", "day", "week", "session"];
        self.add_in("person_days", credited, &sc, &all4);
        self.add_in("human_minutes", h, &sc, &all4);
        self.add_in("active_minutes", active, &sc, &all4);
        self.add_in("turns", 1.0, &sc, &all4);
        let tool = self.session_tool(sid)?;
        self.add_paid(&paid, usd, &sc, &tool);
        let day_usd = self.ctr("usd", &dkey);
        self.record("max_day_usd", day_usd)?;
        self.add_in("clean_streak", 1.0, &sc, &["all", "session"]);
        self.add_ctr("files_touched", &skey, sig.files as f64);
        self.add_ctr("lines_added", &skey, agg.lines_added as f64);
        self.add_ctr("lines_removed", &skey, agg.lines_removed as f64);
        self.add_ctr("subagents", &skey, sig.subagents as f64);
        if let Some(r) = role {
            self.add_ctr(&format!("role:{}", r.as_str()), "all", 1.0);
        }
        for l in &agg.langs {
            let m = format!("lang:{l}");
            if self.ctr(&m, "all") == 0.0 {
                self.set_ctr(&m, "all", 1.0);
                self.add_ctr("languages", "all", 1.0);
            }
        }
        self.mark_source(end_ts)?;
        self.upsert_daily(&sc)?;

        let new_total = old_total + credited;
        self.give_coins(coins_for_pd(old_total, new_total))?;
        let (old_stage, new_stage) = (stage_for(old_total), stage_for(new_total));
        if new_stage.level > old_stage.level && self.live() {
            self.ceremony("grand", "stage_up", &new_stage.level.to_string())?;
        }
        let day = self.tz.date(end_ts);
        if day_pd + 1e-9 < ACTIVE_DAY_PD && day_pd + credited + 1e-9 >= ACTIVE_DAY_PD {
            self.on_day_active(day)?;
        }
        let target = self.weekly_target();
        if week_pd < target && week_pd + credited + 1e-9 >= target && self.live() {
            self.pending.push(Highlight::Ring { pd: week_pd + credited, target });
            self.ceremony("mid", "ring", &sc.week)?;
        }
        self.record("max_day", day_pd + credited)?;
        let session_pd = self.ctr("person_days", &skey);
        self.record("max_session", session_pd)?;

        let mut f = self.time_fields(end_ts);
        f.insert("task_class".into(), Val::Str(class.as_str().into()));
        f.insert("role".into(), Val::Str(role.map(|r| r.as_str()).unwrap_or("").into()));
        f.insert("files_touched".into(), Val::Num(sig.files as f64));
        f.insert("lines_added".into(), Val::Num(agg.lines_added as f64));
        f.insert("lines_removed".into(), Val::Num(agg.lines_removed as f64));
        f.insert("lines".into(), Val::Num(sig.lines as f64));
        f.insert("test_run".into(), Val::Bool(agg.test_run));
        f.insert("test_passed".into(), Val::Bool(agg.test_last == Some(true)));
        f.insert("test_first_pass".into(), Val::Bool(agg.test_first == Some(true)));
        f.insert("test_fixed".into(), Val::Bool(agg.test_fixed));
        f.insert("git_action".into(), Val::Str(git.unwrap_or("").into()));
        f.insert("subagents".into(), Val::Num(sig.subagents as f64));
        f.insert("duration_min".into(), Val::Num(duration));
        f.insert("file_age_days_max".into(), Val::Num(agg.file_age_max.unwrap_or(0) as f64));
        f.insert("recent_agent_lines_removed".into(), Val::Num(agg.recent_agent_removed as f64));
        f.insert("human_minutes".into(), Val::Num(h));
        f.insert("person_days".into(), Val::Num(credited));
        self.session_fields(&skey, &mut f);
        f.insert("day.turns".into(), Val::Num(self.ctr("turns", &dkey)));
        f.insert("employees".into(), Val::Num(new_stage.employees as f64));
        self.eval("turn_end", f, &sc)?;
        self.eval_day(end_ts)?;

        if end.is_some() && self.live() {
            // Who was hired, biggest share first; minor helpers stay off the box.
            let mut jobs: Vec<(&String, &f64)> = paid.iter().collect();
            jobs.sort_by(|a, b| b.1.total_cmp(a.1));
            let summary = TurnSummary {
                usd,
                hours: credited * mpd / 60.0,
                jobs: jobs
                    .iter()
                    .enumerate()
                    .filter(|(i, (_, m))| *i == 0 || **m >= 0.2 * credited * mpd)
                    .map(|(_, (o, _))| self.occ.name_in(o, self.cfg.lang()).to_string())
                    .collect(),
                files: sig.files,
                test_passed: agg.test_run.then_some(agg.test_last == Some(true)),
                committed: sig.merged,
                today_usd: self.ctr("usd", &dkey),
                week_usd: self.ctr("usd", &wkey),
                total_usd: self.ctr("usd", "all"),
                record_usd: self.record_value("max_day_usd")?,
                leverage: dango_core::pricing::leverage(self.ctr("usd", &wkey), self.ctr("cost", &wkey)),
                lang: self.cfg.lang(),
                highlight: self.take_highlight(),
            };
            self.settlements.insert(sid.to_string(), summary);
        }
        Ok(())
    }

    /// A late tool event landed on a finished turn: add the difference.
    /// Never subtracts (SPEC 1: 永不减少).
    fn rescore(&mut self, tid: &str) -> Result<()> {
        let Some(row) = self.turn(tid)? else { return Ok(()) };
        let Some(end_ts) = row.ended_at else { return Ok(()) };
        let work = row.agg.work();
        let h: f64 = work.values().sum();
        if h <= row.human_minutes + 1e-9 {
            return Ok(());
        }
        let dh = h - row.human_minutes;
        let sc = self.scopes(end_ts, Some(&row.session_id));
        let dpd = dh / self.k.units.minutes_per_day;
        // The extra minutes, split the way the turn now splits.
        let add = scaled(&work, dh / h);
        let dusd = self.occ.usd(&add);
        let mut paid = row.paid;
        for (o, m) in &add {
            *paid.entry(o.clone()).or_default() += m;
        }
        self.conn.execute(
            "UPDATE turns SET human_minutes = ?2, credited_pd = ?3, work = ?4, usd = ?5 WHERE id = ?1",
            params![tid, h, row.credited_pd + dpd, serde_json::to_string(&paid)?, row.usd + dusd],
        )?;
        self.conn.execute(
            "UPDATE sessions SET human_minutes = human_minutes + ?2 WHERE id = ?1",
            params![row.session_id, dh],
        )?;
        let old_total = self.ctr("person_days", "all");
        let all4 = ["all", "day", "week", "session"];
        self.add_in("person_days", dpd, &sc, &all4);
        self.add_in("human_minutes", dh, &sc, &all4);
        let tool = self.session_tool(&row.session_id)?;
        self.add_paid(&add, dusd, &sc, &tool);
        let day_usd = self.ctr("usd", &sc.key("day").unwrap());
        self.record("max_day_usd", day_usd)?;
        self.upsert_daily(&sc)?;
        self.give_coins(coins_for_pd(old_total, old_total + dpd))
    }

    /// A finished turn's model usage: price it and move the cost counters,
    /// on the day the turn ended. Applied once per turn.
    fn on_usage(&mut self, ev: &Event) -> Result<()> {
        let Some(tid) = ev.turn_id.as_deref() else { return Ok(()) };
        let row: Option<(String, Option<i64>, i64)> = self
            .conn
            .query_row("SELECT session_id, ended_at, cost_done FROM turns WHERE id = ?1", [tid], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .optional()?;
        let Some((sid, Some(end_ts), 0)) = row else { return Ok(()) };
        let (cost, _) = dango_core::pricing::PriceTable::builtin().cost(&ev.payload.tokens);
        self.conn.execute(
            "UPDATE turns SET tokens = ?2, cost_usd = ?3, cost_done = 1 WHERE id = ?1",
            params![tid, serde_json::to_string(&ev.payload.tokens)?, cost],
        )?;
        let sc = self.scopes(end_ts, Some(&sid));
        let tool = self.session_tool(&sid)?;
        self.add_in("cost", cost, &sc, &["all", "day", "week", "session"]);
        self.add_in(&format!("cost:{tool}"), cost, &sc, &["all", "day", "week"]);
        Ok(())
    }

    /// Which agent a session belongs to (claude_code, codex).
    fn session_tool(&self, sid: &str) -> Result<String> {
        Ok(self.conn.query_row("SELECT source FROM sessions WHERE id = ?1", [sid], |r| r.get(0)).optional()?.unwrap_or_else(|| "claude_code".into()))
    }

    /// Moves the money, per-agent and per-occupation counters by credited work.
    fn add_paid(&mut self, paid: &BTreeMap<String, f64>, usd: f64, sc: &Scopes, tool: &str) {
        self.add_in("usd", usd, sc, &["all", "day", "week", "session"]);
        self.add_in(&format!("usd:{tool}"), usd, sc, &["all", "day", "week"]);
        self.add_in(&format!("minutes:{tool}"), paid.values().sum(), sc, &["all", "day", "week"]);
        for (o, m) in paid {
            self.add_in(&format!("work:{o}"), *m, sc, &["all", "day", "week"]);
        }
    }

    // ---- rewards, records, ceremonies --------------------------------------

    fn give_coins(&mut self, n: i64) -> Result<()> {
        if n > 0 {
            self.conn.execute("UPDATE wallet SET coins = coins + ?1 WHERE id = 1", [n])?;
        }
        Ok(())
    }

    fn record_value(&self, key: &str) -> Result<f64> {
        Ok(self.conn.query_row("SELECT value FROM records WHERE key = ?1", [key], |r| r.get(0)).optional()?.unwrap_or(0.0))
    }

    fn record(&mut self, key: &str, value: f64) -> Result<()> {
        let old: Option<f64> = self.conn.query_row("SELECT value FROM records WHERE key = ?1", [key], |r| r.get(0)).optional()?;
        if old.is_some_and(|o| value <= o + 1e-9) {
            return Ok(());
        }
        self.conn.execute(
            "INSERT INTO records (key, value, at) VALUES (?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value, at = excluded.at",
            params![key, value, self.now],
        )?;
        // Celebrate a broken record once per key per day, live only, once the
        // old record is worth beating and the gain shows at display precision.
        let floor = match key {
            "max_day_usd" => 20.0,
            "max_day" => 0.5,
            "max_session" => 0.25,
            "max_leverage" => 3.0,
            _ => 5.0,
        };
        let shown = |x: f64| match key {
            "max_leverage" => (x * 10.0).round(),
            "max_day_usd" => x.round(),
            _ => (x * 100.0).round(),
        };
        if let Some(o) = old.filter(|o| *o >= floor && shown(value) > shown(*o) && self.live()) {
            let today = day_key(self.tz.date(self.now));
            let mk = format!("record_day:{key}");
            if self.meta(&mk)?.as_deref() != Some(today.as_str()) {
                self.set_meta(&mk, &today)?;
                self.pending.push(Highlight::Record { key: key.to_string(), new: value, old: o });
                self.ceremony("mid", "record", key)?;
            }
        }
        Ok(())
    }

    fn ceremony(&mut self, level: &str, kind: &str, r: &str) -> Result<()> {
        let id = format!("cer_{kind}_{r}_{}", self.now);
        self.conn.execute(
            "INSERT OR IGNORE INTO ceremonies (id, level, kind, ref, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![id, level, kind, r, self.now],
        )?;
        if level == "grand" {
            self.set_meta("last_grand_day", &day_key(self.tz.date(self.now)))?;
        }
        Ok(())
    }

    fn eval(&mut self, kind: &str, fields: HashMap<String, Val>, sc: &Scopes) -> Result<()> {
        let found = achievements::evaluate(self.cat, &Ctx { kind, fields: &fields, scopes: sc }, self);
        let mut any = !found.is_empty();
        self.apply_unlocks(found)?;
        // Sets depend on other unlocks and on role cards (moved by turn_end).
        if any || kind == "turn_end" {
            for _ in 0..3 {
                let f = self.unlock_fields();
                let found = achievements::evaluate(self.cat, &Ctx { kind: "unlocks", fields: &f, scopes: sc }, self);
                any = !found.is_empty();
                self.apply_unlocks(found)?;
                if !any {
                    break;
                }
            }
        }
        Ok(())
    }

    fn eval_day(&mut self, ts: i64) -> Result<()> {
        let d = self.tz.date(ts);
        let sc = self.scopes(ts, None);
        let mut f = self.time_fields(ts);
        let streak = self.streak()?.as_of(d);
        f.insert("streak".into(), Val::Num(streak.current as f64));
        let first = self.meta_day("first_active_day")?;
        let from = (d - Duration::days(29)).max(first.unwrap_or(d));
        let (active_days, pd30): (i64, f64) = self.conn.query_row(
            "SELECT COALESCE(SUM(is_active), 0), COALESCE(SUM(person_days), 0) FROM daily WHERE day >= ?1 AND day <= ?2",
            params![day_key(from), day_key(d)],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let span = (d - from).num_days() + 1;
        f.insert("rest_days_30".into(), Val::Num((span - active_days).max(0) as f64));
        f.insert("person_days_30".into(), Val::Num(pd30));
        let installed = self.meta("installed_at")?.and_then(|v| v.parse::<i64>().ok()).map(|ms| self.tz.date(ms));
        f.insert(
            "days_since_install".into(),
            Val::Num(installed.map_or(0, |i| (d - i).num_days().max(0)) as f64),
        );
        let quiet_since = self.meta_day("last_grand_day")?.or(first);
        f.insert("days_since_grand".into(), Val::Num(quiet_since.map_or(0, |q| (d - q).num_days()) as f64));
        let monday = d - Duration::days(d.weekday().num_days_from_monday() as i64);
        let (sat, sun) = (monday - Duration::days(2), monday - Duration::days(1));
        let weekend = self.ctr("sessions", &format!("day:{}", day_key(sat))) + self.ctr("sessions", &format!("day:{}", day_key(sun)));
        f.insert("weekend_sessions_prev".into(), Val::Num(weekend));
        f.insert("active_before_weekend".into(), Val::Bool(first.is_some_and(|x| x < sat)));
        let wk = self.ctr("turns", &sc.key("week").unwrap());
        let dy = self.ctr("turns", &sc.key("day").unwrap());
        f.insert("week_first_day".into(), Val::Bool(dy > 0.0 && wk == dy));
        f.insert("day.turns".into(), Val::Num(dy));
        f.insert("day.person_days".into(), Val::Num(self.ctr("person_days", &sc.key("day").unwrap())));
        let total = self.ctr("person_days", "all");
        f.insert("employees".into(), Val::Num(stage_for(total).employees as f64));
        self.eval("day", f, &sc)
    }

    fn unlock_fields(&mut self) -> HashMap<String, Val> {
        let mut f = HashMap::new();
        let mut count = 0;
        let map = self.unlocked_map().clone();
        for a in &self.cat.achievements {
            let t = map.get(&a.id).copied().unwrap_or(0);
            f.insert(format!("unlocked.{}", a.id), Val::Num(t as f64));
            if t > 0 && a.category != Category::Set {
                count += 1;
            }
        }
        f.insert("achievements_unlocked".into(), Val::Num(count as f64));
        let (mut t1, mut t3) = (0, 0);
        for r in Role::ALL {
            let tier = self.cat.role_tier(self.ctr(&format!("role:{}", r.as_str()), "all"));
            t1 += (tier >= 1) as u32;
            t3 += (tier >= 3) as u32;
        }
        f.insert("role_cards_t1".into(), Val::Num(t1 as f64));
        f.insert("role_cards_t3".into(), Val::Num(t3 as f64));
        f
    }

    fn apply_unlocks(&mut self, found: Vec<achievements::NewUnlock>) -> Result<()> {
        for u in found {
            if self.unlocked_tier(&u.id) >= u.tier {
                continue;
            }
            let Some(a) = self.cat.get(&u.id) else { continue };
            let Some(t) = a.tier(u.tier) else { continue };
            let backfilled = match self.mode {
                Mode::Backfill => true,
                Mode::Rebuild => self.source == Source::Backfill,
                Mode::Live => false,
            };
            let grand = a.category == Category::Set || t.rarity.is_grand();
            let celebrated = match self.mode {
                Mode::Live => !grand,
                Mode::Backfill => false,
                Mode::Rebuild => true,
            };
            self.conn.execute(
                "INSERT OR IGNORE INTO unlocks (achievement_id, tier, unlocked_at, backfilled, celebrated) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![u.id, u.tier, self.now, backfilled as i64, celebrated as i64],
            )?;
            let m = self.unlocked_map();
            let e = m.entry(u.id.clone()).or_insert(0);
            *e = (*e).max(u.tier);
            let src = format!("reward:{}", u.id);
            if let Some(item) = &t.reward.item {
                self.conn.execute(
                    "INSERT OR IGNORE INTO inventory (item_id, acquired_at, source) VALUES (?1, ?2, ?3)",
                    params![item, self.now, src],
                )?;
            }
            if let Some(title) = &t.reward.title {
                self.conn.execute(
                    "INSERT OR IGNORE INTO inventory (item_id, acquired_at, source) VALUES (?1, ?2, ?3)",
                    params![format!("title:{title}"), self.now, src],
                )?;
            }
            if let Some(n) = t.reward.freeze_tokens {
                let mut s = self.streak()?;
                s.add_tokens(n);
                self.save_streak(&s)?;
            }
            self.give_coins(t.coins())?;
            if self.live() {
                self.pending.push(Highlight::Unlock { id: u.id.clone(), tier: u.tier });
                if grand {
                    self.ceremony("grand", "unlock", &format!("{}:{}", u.id, u.tier))?;
                } else if t.rarity == Rarity::Rare {
                    self.ceremony("mid", "unlock", &format!("{}:{}", u.id, u.tier))?;
                }
            }
        }
        Ok(())
    }

    fn highlight_rank(&self, h: &Highlight) -> u32 {
        match h {
            Highlight::Unlock { id, tier } => {
                let r = self.cat.get(id).and_then(|a| a.tier(*tier)).map(|t| t.rarity).unwrap_or(Rarity::Common);
                40 + 15 * r as u32
            }
            Highlight::Ring { .. } => 50,
            Highlight::Record { .. } => 45,
        }
    }

    /// The single line-4 text for the box: the most important thing that
    /// happened since the last box, plus how many others.
    fn take_highlight(&mut self) -> Option<String> {
        let lang = self.cfg.lang();
        let mut all = std::mem::take(&mut self.pending);
        all.sort_by_key(|h| std::cmp::Reverse(self.highlight_rank(h)));
        let best = all.first()?.clone();
        let mut text = match best {
            Highlight::Unlock { id, tier } => {
                let a = self.cat.get(&id)?;
                let mut t = format!("{} 解锁", display_name(a, tier));
                if let Some(next) = a.next_tier(tier) {
                    match achievements::progress(a, self) {
                        Some((cur, th)) if a.cumulative() => {
                            t += &format!(" · 还差 {} {}到 {}", fmt_short((th - cur).max(0.0)), a.unit, roman(next.tier))
                        }
                        _ => t += &format!(" · 下一档 {}：{} {}", roman(next.tier), fmt_short(next.threshold), a.unit),
                    }
                }
                t
            }
            Highlight::Ring { pd, target } => lang.f("本周合环 {} / {} 人日", "Weekly ring closed {} / {} person-days", &[&fmt_short(pd), &fmt_short(target)]),
            Highlight::Record { key, new, old } => {
                let fmt = |x: f64| match key.as_str() {
                    "max_leverage" => format!("{x:.1}x"),
                    "max_streak" => format!("{x} {}", lang.t("天", "days")),
                    "max_day_usd" => dango_core::render::fmt_usd(x),
                    _ => fmt_pd(x),
                };
                lang.f("新纪录：{} {}（之前 {}）", "New record: {} {} (was {})", &[progress::record_label_in(&key, lang), &fmt(new), &fmt(old)])
            }
        };
        let more = if lang == dango_core::i18n::Lang::Zh { format!(" 等 {} 项", all.len()) } else { lang.f("", " +{} more", &[&(all.len() - 1).to_string()]) };
        if all.len() > 1 && width(&text) + width(&more) <= HIGHLIGHT_WIDTH {
            text += &more;
        }
        Some(text)
    }
}
