//! Data-driven achievement engine (SPEC 7). The catalog is
//! assets/achievements.json; adding an achievement needs no code change.
//!
//! Every trigger reduces to a number compared with each tier's threshold:
//! - `counter`: a counter's value in a scope (all | session | day | week);
//! - `event` / `calendar` / `window` / `set`: evaluated in contexts named by
//!   `on`. With `where` alone the value is how many times it matched; with
//!   `value` it is that expression (gated by `where` when both are given).

use std::collections::HashMap;
use std::sync::OnceLock;

use serde::Deserialize;

use crate::expr::{self, Expr, Val};

pub const BUILTIN_JSON: &str = include_str!("../../../assets/achievements.json");

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Rarity {
    Common,
    Rare,
    Epic,
    Legendary,
}

impl Rarity {
    pub fn base_coins(self) -> i64 {
        match self {
            Rarity::Common => 50,
            Rarity::Rare => 150,
            Rarity::Epic => 500,
            Rarity::Legendary => 2000,
        }
    }

    pub fn name_zh(self) -> &'static str {
        match self {
            Rarity::Common => "普通",
            Rarity::Rare => "稀有",
            Rarity::Epic => "史诗",
            Rarity::Legendary => "传说",
        }
    }

    /// Every colour meaning also has an icon (SPEC 15, accessibility).
    pub fn icon(self) -> &'static str {
        match self {
            Rarity::Common => "○",
            Rarity::Rare => "◇",
            Rarity::Epic => "◆",
            Rarity::Legendary => "★",
        }
    }

    pub fn is_grand(self) -> bool {
        self >= Rarity::Epic
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    Milestone,
    Leverage,
    Moment,
    Style,
    Rhythm,
    Social,
    Hidden,
    Set,
}

impl Category {
    pub const ORDER: [Category; 8] = [
        Category::Milestone,
        Category::Leverage,
        Category::Moment,
        Category::Style,
        Category::Rhythm,
        Category::Social,
        Category::Hidden,
        Category::Set,
    ];

    pub fn name_zh(self) -> &'static str {
        match self {
            Category::Milestone => "里程碑",
            Category::Leverage => "杠杆",
            Category::Moment => "时刻",
            Category::Style => "工程风格",
            Category::Rhythm => "连续与休息",
            Category::Social => "跨工具与社交",
            Category::Hidden => "隐藏",
            Category::Set => "套装",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TriggerType {
    Counter,
    Event,
    Window,
    Calendar,
    Set,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Trigger {
    #[serde(rename = "type")]
    pub kind: TriggerType,
    #[serde(default)]
    pub metric: Option<String>,
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub on: Vec<String>,
    #[serde(default, rename = "where")]
    pub cond: Option<String>,
    #[serde(default)]
    pub value: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Reward {
    #[serde(default)]
    pub coins: Option<i64>,
    #[serde(default)]
    pub item: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub freeze_tokens: Option<u32>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TierDef {
    pub tier: u32,
    pub threshold: f64,
    pub rarity: Rarity,
    #[serde(default)]
    pub reward: Reward,
}

impl TierDef {
    pub fn coins(&self) -> i64 {
        self.reward.coins.unwrap_or_else(|| self.rarity.base_coins())
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct AchievementDef {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub name_en: String,
    pub category: Category,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub hint: Option<String>,
    #[serde(default)]
    pub hint_en: Option<String>,
    pub unlock_line: String,
    #[serde(default)]
    pub unlock_line_en: String,
    pub codex_line: String,
    #[serde(default)]
    pub codex_line_en: String,
    /// Unit for "还差 N<unit>" (次, 人日, 天…).
    #[serde(default)]
    pub unit: String,
    /// Design-time share of founders who own it, until opt-in stats exist.
    #[serde(default)]
    pub global_pct: Option<f64>,
    pub trigger: Trigger,
    pub tiers: Vec<TierDef>,
}

impl AchievementDef {
    pub fn tier(&self, n: u32) -> Option<&TierDef> {
        self.tiers.iter().find(|t| t.tier == n)
    }

    pub fn next_tier(&self, unlocked: u32) -> Option<&TierDef> {
        self.tiers.iter().find(|t| t.tier > unlocked)
    }

    /// Whether progress is a running count that can be shown as "还差 N".
    pub fn cumulative(&self) -> bool {
        match self.trigger.kind {
            TriggerType::Counter => self.trigger.scope.as_deref().unwrap_or("all") == "all",
            TriggerType::Event => self.trigger.value.is_none(),
            _ => false,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct RoleCardDef {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub name_en: String,
    pub face: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ItemDef {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub name_en: String,
}

#[derive(Debug, Deserialize)]
struct RawCatalog {
    version: String,
    role_card_tiers: Vec<f64>,
    role_cards: Vec<RoleCardDef>,
    items: Vec<ItemDef>,
    achievements: Vec<AchievementDef>,
}

pub struct Catalog {
    pub version: String,
    pub role_card_tiers: Vec<f64>,
    pub role_cards: Vec<RoleCardDef>,
    pub items: Vec<ItemDef>,
    pub achievements: Vec<AchievementDef>,
    conds: Vec<Option<Expr>>,
    values: Vec<Option<Expr>>,
}

impl Catalog {
    pub fn parse(src: &str) -> Result<Catalog, String> {
        let raw: RawCatalog = serde_json::from_str(src).map_err(|e| e.to_string())?;
        let mut conds = Vec::new();
        let mut values = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for a in &raw.achievements {
            if !seen.insert(a.id.clone()) {
                return Err(format!("duplicate achievement {}", a.id));
            }
            let t = &a.trigger;
            let ctx = |what: &str, e: String| format!("{} {what}: {e}", a.id);
            conds.push(t.cond.as_deref().map(expr::parse).transpose().map_err(|e| ctx("where", e))?);
            values.push(t.value.as_deref().map(expr::parse).transpose().map_err(|e| ctx("value", e))?);
            match t.kind {
                TriggerType::Counter if t.metric.is_none() => return Err(ctx("trigger", "counter needs metric".into())),
                TriggerType::Counter => {}
                _ if t.on.is_empty() => return Err(ctx("trigger", "needs `on`".into())),
                _ if t.cond.is_none() && t.value.is_none() => {
                    return Err(ctx("trigger", "needs `where` or `value`".into()))
                }
                _ => {}
            }
            if a.tiers.is_empty() || a.tiers.windows(2).any(|w| w[1].tier <= w[0].tier || w[1].threshold < w[0].threshold) {
                return Err(ctx("tiers", "must be non-empty and ascending".into()));
            }
            for tier in &a.tiers {
                if let Some(item) = &tier.reward.item {
                    if !raw.items.iter().any(|i| &i.id == item) {
                        return Err(ctx("reward", format!("unknown item {item}")));
                    }
                }
            }
        }
        Ok(Catalog {
            version: raw.version,
            role_card_tiers: raw.role_card_tiers,
            role_cards: raw.role_cards,
            items: raw.items,
            achievements: raw.achievements,
            conds,
            values,
        })
    }

    pub fn builtin() -> &'static Catalog {
        static C: OnceLock<Catalog> = OnceLock::new();
        C.get_or_init(|| Catalog::parse(BUILTIN_JSON).expect("built-in achievements.json"))
    }

    pub fn get(&self, id: &str) -> Option<&AchievementDef> {
        self.achievements.iter().find(|a| a.id == id)
    }

    pub fn item_name(&self, id: &str) -> String {
        self.items.iter().find(|i| i.id == id).map(|i| i.name.clone()).unwrap_or_else(|| id.to_string())
    }

    pub fn role_card(&self, id: &str) -> Option<&RoleCardDef> {
        self.role_cards.iter().find(|r| r.id == id)
    }

    /// Role card tier (0..=3) for a number of turns in that role.
    pub fn role_tier(&self, turns: f64) -> u32 {
        self.role_card_tiers.iter().filter(|t| turns >= **t).count() as u32
    }
}

/// Counter metric where an event trigger's match count is kept.
pub fn match_metric(id: &str) -> String {
    format!("ach:{id}")
}

/// Engine state the caller owns (SQLite in the daemon, a map in tests).
pub trait Store {
    fn counter(&mut self, metric: &str, scope: &str) -> f64;
    fn add(&mut self, metric: &str, scope: &str, by: f64);
    fn unlocked_tier(&mut self, id: &str) -> u32;
}

/// The scope keys of the activity being evaluated.
#[derive(Debug, Clone, Default)]
pub struct Scopes {
    pub session: Option<String>,
    pub day: String,
    pub week: String,
}

impl Scopes {
    pub fn key(&self, scope: &str) -> Option<String> {
        match scope {
            "all" => Some("all".to_string()),
            "session" => self.session.as_ref().map(|s| format!("session:{s}")),
            "day" => Some(format!("day:{}", self.day)),
            "week" => Some(format!("week:{}", self.week)),
            _ => None,
        }
    }
}

pub struct Ctx<'a> {
    pub kind: &'a str,
    pub fields: &'a HashMap<String, Val>,
    pub scopes: &'a Scopes,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NewUnlock {
    pub id: String,
    pub tier: u32,
}

/// Evaluates every achievement that listens to `ctx.kind` (counter triggers
/// listen everywhere) and returns tiers that are newly reached. The caller
/// records them; the engine does not mark anything unlocked itself.
pub fn evaluate(cat: &Catalog, ctx: &Ctx, store: &mut dyn Store) -> Vec<NewUnlock> {
    let get = |k: &str| ctx.fields.get(k).cloned().unwrap_or(Val::Null);
    let mut out = Vec::new();
    for (i, a) in cat.achievements.iter().enumerate() {
        let t = &a.trigger;
        let value = match t.kind {
            TriggerType::Counter => {
                let Some(scope) = ctx.scopes.key(t.scope.as_deref().unwrap_or("all")) else { continue };
                store.counter(t.metric.as_deref().unwrap_or_default(), &scope)
            }
            _ => {
                if !t.on.iter().any(|o| o == ctx.kind) {
                    continue;
                }
                match (&cat.conds[i], &cat.values[i]) {
                    (Some(c), None) => {
                        let m = match_metric(&a.id);
                        if c.eval(&get).truthy() {
                            store.add(&m, "all", 1.0);
                        }
                        store.counter(&m, "all")
                    }
                    (None, Some(v)) => v.eval(&get).num(),
                    (Some(c), Some(v)) => {
                        if !c.eval(&get).truthy() {
                            continue;
                        }
                        v.eval(&get).num()
                    }
                    (None, None) => continue,
                }
            }
        };
        let have = store.unlocked_tier(&a.id);
        for tier in &a.tiers {
            if tier.tier > have && value + 1e-9 >= tier.threshold {
                out.push(NewUnlock { id: a.id.clone(), tier: tier.tier });
            }
        }
    }
    out
}

/// Progress toward the next tier, for cumulative achievements only.
pub fn progress(a: &AchievementDef, store: &mut dyn Store) -> Option<(f64, f64)> {
    if !a.cumulative() {
        return None;
    }
    let next = a.next_tier(store.unlocked_tier(&a.id))?;
    let current = match a.trigger.kind {
        TriggerType::Counter => store.counter(a.trigger.metric.as_deref()?, "all"),
        _ => store.counter(&match_metric(&a.id), "all"),
    };
    Some((current, next.threshold))
}

pub fn roman(n: u32) -> &'static str {
    match n {
        1 => "I",
        2 => "II",
        3 => "III",
        4 => "IV",
        _ => "",
    }
}

/// "夜猫子 II" — tier suffix only for multi-tier achievements.
pub fn display_name(a: &AchievementDef, tier: u32) -> String {
    if a.tiers.len() > 1 {
        format!("{} {}", a.name, roman(tier))
    } else {
        a.name.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct MapStore {
        c: HashMap<(String, String), f64>,
        u: HashMap<String, u32>,
    }

    impl Store for MapStore {
        fn counter(&mut self, m: &str, s: &str) -> f64 {
            *self.c.get(&(m.into(), s.into())).unwrap_or(&0.0)
        }
        fn add(&mut self, m: &str, s: &str, by: f64) {
            *self.c.entry((m.into(), s.into())).or_default() += by;
        }
        fn unlocked_tier(&mut self, id: &str) -> u32 {
            *self.u.get(id).unwrap_or(&0)
        }
    }

    #[test]
    fn builtin_catalog_is_valid() {
        let c = Catalog::builtin();
        assert_eq!(c.role_cards.len(), 12);
        assert!(c.achievements.len() >= 52);
        for a in &c.achievements {
            assert!(a.unlock_line.chars().count() <= 18, "{} unlock_line too long", a.id);
            assert!(a.codex_line.chars().count() <= 30, "{} codex_line too long", a.id);
            assert!(!a.name_en.is_empty() && !a.unlock_line_en.is_empty() && !a.codex_line_en.is_empty(), "{} needs _en", a.id);
            if a.hidden {
                assert!(a.hint.is_some(), "{} hidden needs hint", a.id);
            }
        }
    }

    #[test]
    fn counter_tiers_unlock_together_when_jumped() {
        let c = Catalog::builtin();
        let mut s = MapStore::default();
        s.add("person_days", "all", 23.0);
        let fields = HashMap::new();
        let scopes = Scopes { session: None, day: "2026-10-28".into(), week: "2026-W44".into() };
        let got = evaluate(c, &Ctx { kind: "turn_end", fields: &fields, scopes: &scopes }, &mut s);
        let ids: Vec<_> = got.iter().map(|u| u.id.as_str()).collect();
        assert!(ids.contains(&"M01") && ids.contains(&"M02") && ids.contains(&"M03"));
        assert!(!ids.contains(&"M04"));
    }

    #[test]
    fn event_counts_matches() {
        let c = Catalog::builtin();
        let mut s = MapStore::default();
        let scopes = Scopes { session: Some("s".into()), day: "d".into(), week: "w".into() };
        let mut fields = HashMap::new();
        fields.insert("test_first_pass".to_string(), Val::Bool(true));
        let ctx = Ctx { kind: "turn_end", fields: &fields, scopes: &scopes };
        let got = evaluate(c, &ctx, &mut s);
        assert!(got.iter().any(|u| u.id == "T07" && u.tier == 1));
        assert_eq!(s.counter("ach:T07", "all"), 1.0);
        s.u.insert("T07".into(), 1);
        for _ in 0..8 {
            evaluate(c, &ctx, &mut s);
        }
        assert!(evaluate(c, &ctx, &mut s).iter().any(|u| u.id == "T07" && u.tier == 2));
        let a = c.get("T07").unwrap();
        assert_eq!(progress(a, &mut s), Some((10.0, 10.0)));
    }
}
