//! `shadowcorp stats` and `shadowcorp badges` (SPEC 10.6, terminal mode).

use daemon::ingest::{Result, Tz};
use daemon::snapshot::{self, DbStore};
use rusqlite::Connection;
use shadowcorp_core::achievements::{self, display_name, roman, Catalog, Category, Store};
use shadowcorp_core::progress::record_label;
use daemon::config::Config;
use shadowcorp_core::render::{fmt_int, fmt_pd, fmt_short, fmt_usd, pad, ring_bar};
use shadowcorp_core::scoring::fmt_leverage;

fn fmt_record(key: &str, v: f64) -> String {
    match key {
        "max_leverage" => fmt_leverage(Some(v)),
        "max_streak" => format!("{v} 天"),
        _ => fmt_pd(v),
    }
}

pub fn stats(conn: &Connection, tz: Tz, cfg: &Config, now: i64) -> Result<String> {
    let c = snapshot::company(conn, tz, cfg.general.weekly_target, now)?;
    let o = snapshot::output(conn, tz, cfg, now);
    let cat = Catalog::builtin();
    let row = |k: &str, v: String| format!("  {}{v}", pad(k, 10));
    let mut out = vec![format!("产出 · {}", o.rank.label()), "─".repeat(44)];
    out.push(row("总产出", format!("{} · {} 人日 · 按 ${}/小时", fmt_usd(o.total_usd), fmt_pd(o.total_pd), fmt_short(o.hourly_rate))));
    let next = match (o.rank.xp_to_next(), o.rank.next_label()) {
        (Some(n), Some(l)) => format!(" · 还差 {} XP 升 {l}", fmt_int(n as i64)),
        _ => " · 已是最高段位".to_string(),
    };
    out.push(row("段位", format!("{} · {} XP{next}", o.rank.label(), fmt_int(o.rank.xp as i64))));
    out.push(row("今日", format!("{} · 本周 {}", fmt_usd(o.today_usd), fmt_usd(o.week_usd))));
    let mut stage = format!("Lv.{} {} · {} 位员工", c.stage.level, c.stage.name, c.stage.employees);
    if let Some(n) = c.next {
        stage += &format!(" · 距「{}」还差 {} 人日", n.name, fmt_pd(n.threshold - c.total_pd));
    }
    out.push(row("阶段", stage));
    out.push(row(
        "本周",
        format!(
            "{} / {} 人日 {} · 杠杆 {}",
            fmt_short(c.week_pd),
            fmt_short(c.week_target),
            ring_bar(c.week_pd, c.week_target, 5),
            fmt_leverage(c.week_leverage)
        ),
    ));
    let s = &c.streak;
    let streak = if s.current <= 1 && s.previous > 0 {
        format!("上一段 {} 天 · 新的一段从今天开始", s.previous)
    } else {
        format!("🔥 {} 天 · 最长 {} 天", s.current, s.longest)
    };
    out.push(row("连续", format!("{streak} · 冻结券 {}", c.freeze_tokens)));
    out.push(row("金币", fmt_int(c.coins)));
    if !c.records.is_empty() {
        let recs: Vec<String> = c.records.iter().map(|(k, v)| format!("{} {}", record_label(k), fmt_record(k, *v))).collect();
        out.push(row("纪录", recs.join(" · ")));
    }
    out.push(row("徽章", format!("{} / {}", c.unlocked, c.achievements)));
    let roles: Vec<String> = c
        .roles
        .iter()
        .filter(|(_, t, _)| *t > 0)
        .map(|(id, t, _)| format!("{} {}", cat.role_card(id).map(|r| r.name.as_str()).unwrap_or(id), roman(*t)))
        .collect();
    out.push(row("职业卡", if roles.is_empty() { "—".into() } else { roles.join(" · ") }));
    out.push(row("称号", c.titles.join(" · ")));
    if !c.items.is_empty() {
        out.push(row("装饰", c.items.join(" · ")));
    }
    Ok(out.join("\n"))
}

pub fn badges(conn: &Connection) -> Result<String> {
    let cat = Catalog::builtin();
    let mut store = DbStore(conn);
    let mut out = Vec::new();
    for cat_kind in Category::ORDER {
        let list: Vec<_> = cat.achievements.iter().filter(|a| a.category == cat_kind).collect();
        if list.is_empty() {
            continue;
        }
        out.push(format!("{}", cat_kind.name_zh()));
        for a in list {
            let have = store.unlocked_tier(&a.id);
            if have == 0 && a.hidden {
                out.push(format!("  ?  {}{}", pad("???", 18), a.hint.as_deref().unwrap_or("")));
                continue;
            }
            let shown_tier = if have == 0 { 1 } else { have };
            let icon = a.tier(shown_tier).map(|t| t.rarity.icon()).unwrap_or("○");
            let mark = if have > 0 { "✦" } else { "·" };
            let name = pad(&display_name(a, shown_tier), 16);
            let detail = match (achievements::progress(a, &mut store), a.next_tier(have)) {
                (Some((cur, th)), Some(next)) => {
                    let to = if a.tiers.len() > 1 { roman(next.tier) } else { "解锁" };
                    format!("[{}] {}/{} {} → {to}", ring_bar(cur, th, 10), fmt_short(cur.min(th)), fmt_short(th), a.unit)
                }
                (None, Some(next)) if have > 0 => format!("下一档 {}：{} {}", roman(next.tier), fmt_short(next.threshold), a.unit),
                (_, None) => {
                    let pct = match a.global_pct {
                        Some(p) if p < 10.0 => format!(" · 只有 {p}% 的创始人拥有"),
                        Some(p) => format!(" · {p}% 的创始人拥有"),
                        None => String::new(),
                    };
                    format!("已解锁{pct}")
                }
                _ => a.codex_line.clone(),
            };
            out.push(format!("  {mark} {icon} {name} {detail}"));
        }
        out.push(String::new());
    }
    out.push("职业图鉴".into());
    for r in &cat.role_cards {
        let n = snapshot::counter(conn, &format!("role:{}", r.id), "all");
        let tier = cat.role_tier(n);
        let face = match tier {
            0 => "未解锁",
            1 => "线稿",
            2 => "上色",
            _ => "金边",
        };
        out.push(format!("  {} {} {} 回合 · {}（{face}）", pad(&r.name, 10), pad(roman(tier), 3), n, r.face));
    }
    Ok(out.join("\n"))
}
