//! Read-side views for the CLI, status line and socket: the company page,
//! achievement progress and pending grand ceremonies. Reads the database the
//! processor has flushed; never writes progress.

use rusqlite::{params, Connection, OptionalExtension};
use dango_core::achievements::{self, display_name, Catalog, Category, Rarity, Store};
use dango_core::progress::{self, stage_for, Stage, Streak};
use dango_core::render::{fmt_int, fmt_short, grand_badge, StatusInfo};
use dango_core::pricing;
use dango_core::scoring::ScoringConstants;

use crate::db::{get_meta, set_meta};
use crate::ingest::{day_key, week_key, Result, Tz, PERMISSION_QUIET_MS};

/// Read-only Store over the counters table.
pub struct DbStore<'a>(pub &'a Connection);

impl Store for DbStore<'_> {
    fn counter(&mut self, metric: &str, scope: &str) -> f64 {
        counter(self.0, metric, scope)
    }
    fn add(&mut self, _: &str, _: &str, _: f64) {}
    fn unlocked_tier(&mut self, id: &str) -> u32 {
        self.0
            .query_row("SELECT COALESCE(MAX(tier), 0) FROM unlocks WHERE achievement_id = ?1", [id], |r| r.get(0))
            .unwrap_or(0)
    }
}

pub fn counter(conn: &Connection, metric: &str, scope: &str) -> f64 {
    conn.query_row("SELECT value FROM counters WHERE metric = ?1 AND scope = ?2", [metric, scope], |r| r.get(0))
        .optional()
        .ok()
        .flatten()
        .unwrap_or(0.0)
}

pub struct Company {
    pub total_pd: f64,
    pub stage: &'static Stage,
    pub next: Option<&'static Stage>,
    pub title: String,
    pub titles: Vec<String>,
    pub week_pd: f64,
    pub week_target: f64,
    pub week_leverage: Option<f64>,
    pub streak: Streak,
    pub coins: i64,
    pub freeze_tokens: i64,
    pub records: Vec<(String, f64)>,
    pub unlocked: usize,
    pub achievements: usize,
    /// (role card id, tier, turns)
    pub roles: Vec<(String, u32, f64)>,
    pub items: Vec<String>,
}

pub fn weekly_target(conn: &Connection, cfg_target: f64) -> f64 {
    if cfg_target > 0.0 {
        return cfg_target;
    }
    get_meta(conn, "weekly_target")
        .ok()
        .flatten()
        .and_then(|v| v.parse().ok())
        .unwrap_or(progress::DEFAULT_WEEKLY_TARGET)
}

pub fn company(conn: &Connection, tz: Tz, cfg_target: f64, now_ms: i64) -> Result<Company> {
    let cat = Catalog::builtin();
    let today = tz.date(now_ms);
    let wk = format!("week:{}", week_key(today));
    let total_pd = counter(conn, "person_days", "all");
    let stage = stage_for(total_pd);
    let streak: Streak = get_meta(conn, "streak")?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
    let (coins, freeze_tokens): (i64, i64) =
        conn.query_row("SELECT coins, freeze_tokens FROM wallet WHERE id = 1", [], |r| Ok((r.get(0)?, r.get(1)?)))?;
    let mut records = Vec::new();
    for (k, _) in progress::RECORD_KEYS {
        if let Some(v) = conn.query_row("SELECT value FROM records WHERE key = ?1", [k], |r| r.get::<_, f64>(0)).optional()? {
            records.push((k.to_string(), v));
        }
    }
    let unlocked: usize = conn.query_row("SELECT COUNT(DISTINCT achievement_id) FROM unlocks", [], |r| r.get::<_, i64>(0))? as usize;
    let roles = cat
        .role_cards
        .iter()
        .map(|r| {
            let n = counter(conn, &format!("role:{}", r.id), "all");
            (r.id.clone(), cat.role_tier(n), n)
        })
        .collect();
    let mut titles: Vec<String> = progress::STAGES
        .iter()
        .filter(|s| total_pd + 1e-9 >= s.threshold)
        .map(|s| s.title.to_string())
        .collect();
    let mut items = Vec::new();
    let mut st = conn.prepare("SELECT item_id FROM inventory ORDER BY acquired_at")?;
    for id in st.query_map([], |r| r.get::<_, String>(0))?.flatten() {
        match id.strip_prefix("title:") {
            Some(t) => titles.push(t.to_string()),
            None => items.push(cat.item_name(&id)),
        }
    }
    let title = get_meta(conn, "display_title")?.filter(|t| titles.contains(t)).unwrap_or_else(|| stage.title.to_string());
    Ok(Company {
        total_pd,
        stage,
        next: progress::next_stage(total_pd),
        title,
        titles,
        week_pd: counter(conn, "person_days", &wk),
        week_target: weekly_target(conn, cfg_target),
        week_leverage: pricing::leverage(counter(conn, "usd", &wk), counter(conn, "cost", &wk)),
        streak: streak.as_of(today),
        coins,
        freeze_tokens,
        records,
        unlocked,
        achievements: cat.achievements.len(),
        roles,
        items,
    })
}

/// The closest cumulative achievement within 10% of its next tier.
pub fn near_hint(conn: &Connection) -> Option<String> {
    let cat = Catalog::builtin();
    let mut store = DbStore(conn);
    let mut best: Option<(f64, String)> = None;
    for a in &cat.achievements {
        if a.hidden || a.category == Category::Set {
            continue;
        }
        let Some((cur, th)) = achievements::progress(a, &mut store) else { continue };
        let left = th - cur;
        if left <= 0.0 || th <= 0.0 || left / th > 0.10 {
            continue;
        }
        let tier = store.unlocked_tier(&a.id) + 1;
        let text = format!("{} 还差 {}{}", display_name(a, tier), fmt_short(left), a.unit);
        if best.as_ref().map_or(true, |(b, _)| left / th < *b) {
            best = Some((left / th, text));
        }
    }
    best.map(|(_, t)| t)
}

/// The numbers the widget, status line and box share.
pub struct Output {
    pub total_pd: f64,
    pub today_pd: f64,
    pub week_pd: f64,
    pub total_hours: f64,
    pub today_hours: f64,
    pub week_hours: f64,
    pub total_usd: f64,
    pub today_usd: f64,
    pub week_usd: f64,
    /// What the models cost at API prices.
    pub total_cost: f64,
    pub today_cost: f64,
    pub week_cost: f64,
    /// This week's dollars of work per dollar of model.
    pub week_leverage: Option<f64>,
    /// The best day so far, in dollars.
    pub record_day_usd: f64,
}

/// A record's value (records table), 0 when none.
pub fn record(conn: &Connection, key: &str) -> f64 {
    conn.query_row("SELECT value FROM records WHERE key = ?1", [key], |r| r.get::<_, f64>(0)).unwrap_or(0.0)
}

/// The best day in dollars: the record, or the day counters for data
/// scored before the record existed.
pub fn best_day_usd(conn: &Connection) -> f64 {
    let days: f64 = conn
        .query_row("SELECT COALESCE(MAX(value), 0) FROM counters WHERE metric = 'usd' AND scope LIKE 'day:%'", [], |r| r.get(0))
        .unwrap_or(0.0);
    record(conn, "max_day_usd").max(days)
}

pub fn output(conn: &Connection, tz: Tz, now_ms: i64) -> Output {
    let k = ScoringConstants::builtin();
    let d = tz.date(now_ms);
    let (dk, wk) = (format!("day:{}", day_key(d)), format!("week:{}", week_key(d)));
    let (total_pd, today_pd, week_pd) =
        (counter(conn, "person_days", "all"), counter(conn, "person_days", &dk), counter(conn, "person_days", &wk));
    Output {
        total_pd,
        today_pd,
        week_pd,
        total_hours: total_pd * k.caps.minutes_per_day / 60.0,
        today_hours: today_pd * k.caps.minutes_per_day / 60.0,
        week_hours: week_pd * k.caps.minutes_per_day / 60.0,
        total_usd: counter(conn, "usd", "all"),
        today_usd: counter(conn, "usd", &dk),
        week_usd: counter(conn, "usd", &wk),
        total_cost: counter(conn, "cost", "all"),
        today_cost: counter(conn, "cost", &dk),
        week_cost: counter(conn, "cost", &wk),
        week_leverage: pricing::leverage(counter(conn, "usd", &wk), counter(conn, "cost", &wk)),
        record_day_usd: best_day_usd(conn),
    }
}

/// Agents at work right now: open turns with activity in the last 20
/// minutes, how many subagents they have running, and the last live event.
pub fn activity(conn: &Connection, now_ms: i64) -> Result<(i64, i64, Option<i64>)> {
    const WORKING_WINDOW_MS: i64 = 20 * 60_000;
    let mut working = 0;
    let mut subagents = 0;
    let mut st = conn.prepare(
        "SELECT json_extract(t.agg, '$.last_activity'), json_extract(t.agg, '$.agent_calls'),
                json_extract(t.agg, '$.subagent_stops')
         FROM sessions s JOIN turns t ON t.id = json_extract(s.state, '$.open_turn') WHERE t.ended_at IS NULL",
    )?;
    let rows = st.query_map([], |r| {
        Ok((r.get::<_, Option<i64>>(0)?.unwrap_or(0), r.get::<_, Option<i64>>(1)?.unwrap_or(0), r.get::<_, Option<i64>>(2)?.unwrap_or(0)))
    })?;
    for (last, calls, stops) in rows.flatten() {
        if now_ms - last < WORKING_WINDOW_MS {
            working += 1;
            subagents += (calls - stops).max(0);
        }
    }
    let last_event: Option<i64> =
        conn.query_row("SELECT MAX(ts) FROM events WHERE source != 'backfill'", [], |r| r.get(0)).unwrap_or(None);
    Ok((working, subagents, last_event))
}

/// One status line: the total, today's and this week's value, and the
/// economic leverage (this session's, else this week's).
pub fn status(conn: &Connection, tz: Tz, now_ms: i64, session: Option<&str>, lang: dango_core::i18n::Lang) -> Result<String> {
    let o = output(conn, tz, now_ms);
    let lev = session
        .and_then(|s| {
            let k = format!("session:{s}");
            pricing::leverage(counter(conn, "usd", &k), counter(conn, "cost", &k))
        })
        .or(o.week_leverage);
    Ok(dango_core::render::status_line(&StatusInfo {
        total_usd: o.total_usd,
        today_usd: o.today_usd,
        week_usd: o.week_usd,
        leverage: lev,
        lang,
    }))
}

fn reward_text(cat: &Catalog, t: &achievements::TierDef) -> String {
    let mut parts = vec![format!("+{} 金币", fmt_int(t.coins()))];
    if let Some(i) = &t.reward.item {
        parts.push(cat.item_name(i));
    }
    if let Some(title) = &t.reward.title {
        parts.push(format!("称号「{title}」"));
    }
    if let Some(n) = t.reward.freeze_tokens {
        parts.push(format!("冻结券 +{n}"));
    }
    parts.join(" · ")
}

/// The terminal badge for one ceremony row (kind, ref).
pub fn grand_text(kind: &str, r: &str) -> Option<String> {
    let cat = Catalog::builtin();
    match kind {
        "stage_up" => {
            let level: usize = r.parse().ok()?;
            let s = progress::STAGES.get(level.checked_sub(1)?)?;
            Some(grand_badge("★ 公司升阶 ★", &format!("Lv.{} {}", s.level, s.name), &format!("新称号：{}", s.title), ""))
        }
        "unlock" => {
            let (id, tier) = r.split_once(':')?;
            let tier: u32 = tier.parse().ok()?;
            let a = cat.get(id)?;
            let t = a.tier(tier)?;
            let kind = if a.category == Category::Set { "套装完成" } else { "成就解锁" };
            let heading = format!("{} {}{} {}", t.rarity.icon(), t.rarity.name_zh(), kind, t.rarity.icon());
            Some(grand_badge(&heading, &display_name(a, tier), &a.unlock_line, &reward_text(cat, t)))
        }
        _ => None,
    }
}

fn rank(kind: &str, r: &str) -> u32 {
    if kind == "stage_up" {
        return 100;
    }
    let cat = Catalog::builtin();
    r.split_once(':')
        .and_then(|(id, t)| cat.get(id)?.tier(t.parse().ok()?).map(|t| t.rarity))
        .map(|x| match x {
            Rarity::Legendary => 90,
            Rarity::Epic => 80,
            _ => 70,
        })
        .unwrap_or(0)
}

/// Shows at most one queued grand ceremony: stage-ups first, then by
/// rarity, at most one per cooldown and never right after a permission
/// prompt (SPEC 8.2). Marks it shown.
pub fn take_grand(conn: &Connection, now_ms: i64, cooldown_hours: f64) -> Result<Option<String>> {
    let last: i64 = get_meta(conn, "last_grand_shown")?.and_then(|v| v.parse().ok()).unwrap_or(0);
    if last > 0 && (now_ms - last) as f64 <= cooldown_hours * 3_600_000.0 {
        return Ok(None);
    }
    let perm: i64 = get_meta(conn, "last_permission_ms")?.and_then(|v| v.parse().ok()).unwrap_or(0);
    if perm > 0 && now_ms - perm < PERMISSION_QUIET_MS {
        return Ok(None);
    }
    let mut st = conn.prepare("SELECT id, kind, ref, created_at FROM ceremonies WHERE level = 'grand' AND shown_at IS NULL")?;
    let mut rows: Vec<(String, String, String, i64)> =
        st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?.flatten().collect();
    rows.sort_by_key(|(_, k, r, at)| (std::cmp::Reverse(rank(k, r)), *at));
    let Some((id, kind, r, _)) = rows.into_iter().next() else { return Ok(None) };
    conn.execute("UPDATE ceremonies SET shown_at = ?2 WHERE id = ?1", params![id, now_ms])?;
    set_meta(conn, "last_grand_shown", &now_ms.to_string())?;
    if let Some((aid, tier)) = r.split_once(':') {
        conn.execute("UPDATE unlocks SET celebrated = 1 WHERE achievement_id = ?1 AND tier = ?2", params![aid, tier])?;
    }
    Ok(grand_text(&kind, &r))
}
