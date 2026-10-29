//! Company stages, coins, the weekly ring and streaks (SPEC 6).

use chrono::{Datelike, NaiveDate, Weekday};
use serde::{Deserialize, Serialize};

pub struct Stage {
    pub level: u8,
    pub name: &'static str,
    pub threshold: f64,
    pub employees: u32,
    pub title: &'static str,
}

pub const STAGES: [Stage; 7] = [
    Stage { level: 1, name: "车库", threshold: 0.0, employees: 1, title: "车库创客" },
    Stage { level: 2, name: "工作室", threshold: 5.0, employees: 2, title: "工作室主理人" },
    Stage { level: 3, name: "创业公司", threshold: 22.0, employees: 4, title: "创业公司 CEO" },
    Stage { level: 4, name: "成长期", threshold: 100.0, employees: 8, title: "成长期 CEO" },
    Stage { level: 5, name: "独角兽", threshold: 250.0, employees: 12, title: "独角兽创始人" },
    Stage { level: 6, name: "集团", threshold: 1000.0, employees: 20, title: "集团董事长" },
    Stage { level: 7, name: "帝国", threshold: 5000.0, employees: 30, title: "帝国缔造者" },
];

pub fn stage_for(total_pd: f64) -> &'static Stage {
    STAGES.iter().rev().find(|s| total_pd + 1e-9 >= s.threshold).unwrap_or(&STAGES[0])
}

pub fn next_stage(total_pd: f64) -> Option<&'static Stage> {
    STAGES.iter().find(|s| s.threshold > total_pd + 1e-9)
}

pub const COINS_PER_PERSON_DAY: f64 = 100.0;

/// Coins earned when the lifetime total moves from `old` to `new`. Whole coins
/// only; the fraction carries over to the next turn.
pub fn coins_for_pd(old_total: f64, new_total: f64) -> i64 {
    let c = |x: f64| (x * COINS_PER_PERSON_DAY + 1e-9).floor() as i64;
    (c(new_total) - c(old_total)).max(0)
}

pub const DEFAULT_WEEKLY_TARGET: f64 = 5.0;
/// A day counts as active at this many person-days (SPEC 2).
pub const ACTIVE_DAY_PD: f64 = 0.1;

/// clamp(round(1.2 × median of the last 4 weeks), 2, 20) (SPEC 6.3).
pub fn auto_weekly_target(last_weeks: &[f64]) -> f64 {
    if last_weeks.is_empty() {
        return DEFAULT_WEEKLY_TARGET;
    }
    let mut v = last_weeks.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = v.len();
    let median = if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 };
    (1.2 * median).round().clamp(2.0, 20.0)
}

pub fn is_weekend(d: NaiveDate) -> bool {
    matches!(d.weekday(), Weekday::Sat | Weekday::Sun)
}

pub const MAX_FREEZE_TOKENS: u32 = 3;
pub const TOKEN_EVERY_DAYS: u32 = 30;

/// Streak of active weekdays. Weekends neither count nor break it; a missed
/// weekday spends a freeze token if one is left (SPEC 6.4).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Streak {
    pub current: u32,
    pub longest: u32,
    /// Length of the run before the current one, for "上一段 N 天".
    pub previous: u32,
    pub tokens: u32,
    /// Every day up to and including this one has been accounted for.
    pub settled_through: Option<NaiveDate>,
    pub last_counted: Option<NaiveDate>,
}

impl Streak {
    /// Records that `day` became active. Returns true when `current` grew.
    /// Days must arrive in order; a day already settled is ignored.
    pub fn mark_active(&mut self, day: NaiveDate) -> bool {
        if self.settled_through.is_some_and(|s| day <= s) {
            return false;
        }
        self.settle_before(day);
        self.settled_through = Some(day);
        if is_weekend(day) {
            return false;
        }
        self.current += 1;
        self.last_counted = Some(day);
        if self.current % TOKEN_EVERY_DAYS == 0 {
            self.add_tokens(1);
        }
        self.longest = self.longest.max(self.current);
        true
    }

    pub fn add_tokens(&mut self, n: u32) {
        self.tokens = (self.tokens + n).min(MAX_FREEZE_TOKENS);
    }

    /// Spends tokens (or ends the run) for weekdays missed before `day`.
    fn settle_before(&mut self, day: NaiveDate) {
        let Some(mut d) = self.settled_through.and_then(|s| s.succ_opt()) else { return };
        while d < day {
            if !is_weekend(d) {
                if self.tokens > 0 {
                    self.tokens -= 1;
                } else if self.current > 0 {
                    self.previous = self.current;
                    self.current = 0;
                }
            }
            d = match d.succ_opt() {
                Some(n) => n,
                None => break,
            };
        }
    }

    /// The streak as it stands on `today`, settling any missed weekdays
    /// before today without mutating the stored state.
    pub fn as_of(&self, today: NaiveDate) -> Streak {
        let mut s = self.clone();
        if s.settled_through.is_some_and(|t| t < today) {
            s.settle_before(today);
        }
        s
    }
}

/// Personal records (SPEC 6.5).
pub const RECORD_KEYS: [(&str, &str); 5] = [
    ("max_day_usd", "单日最高产出"),
    ("max_day", "单日最高人日"),
    ("max_session", "单会话最高人日"),
    ("max_leverage", "单会话最高时间杠杆"),
    ("max_streak", "最长连续天数"),
];

pub fn record_label(key: &str) -> &'static str {
    RECORD_KEYS.iter().find(|(k, _)| *k == key).map(|(_, l)| *l).unwrap_or("纪录")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    #[test]
    fn stages() {
        assert_eq!(stage_for(0.0).level, 1);
        assert_eq!(stage_for(4.99).level, 1);
        assert_eq!(stage_for(5.0).level, 2);
        assert_eq!(stage_for(250.0).name, "独角兽");
        assert_eq!(stage_for(1e9).level, 7);
        assert_eq!(next_stage(23.0).unwrap().level, 4);
        assert!(next_stage(6000.0).is_none());
    }

    #[test]
    fn coins_carry_fractions() {
        assert_eq!(coins_for_pd(0.0, 0.42), 42);
        assert_eq!(coins_for_pd(0.425, 0.435), 1);
        assert_eq!(coins_for_pd(0.29, 0.29), 0);
        assert_eq!(coins_for_pd(0.0, 0.29), 29);
    }

    #[test]
    fn weekly_target() {
        assert_eq!(auto_weekly_target(&[4.0, 6.0, 8.0, 10.0]), 8.0);
        assert_eq!(auto_weekly_target(&[0.1, 0.2, 0.1, 0.0]), 2.0);
        assert_eq!(auto_weekly_target(&[40.0, 40.0, 40.0, 40.0]), 20.0);
    }

    #[test]
    fn weekends_neither_count_nor_break() {
        let mut s = Streak::default();
        assert!(s.mark_active(d("2026-10-23"))); // Fri
        assert!(!s.mark_active(d("2026-10-24"))); // Sat, does not count
        assert!(s.mark_active(d("2026-10-26"))); // Mon
        assert_eq!(s.current, 2);
        assert!(!s.mark_active(d("2026-10-26")));
    }

    #[test]
    fn missed_weekday_ends_run_without_tokens() {
        let mut s = Streak::default();
        s.mark_active(d("2026-10-26")); // Mon
        s.mark_active(d("2026-10-27")); // Tue
        s.mark_active(d("2026-10-29")); // Thu, Wed missed
        assert_eq!(s.current, 1);
        assert_eq!(s.previous, 2);
        assert_eq!(s.longest, 2);
    }

    #[test]
    fn tokens_cover_missed_days_and_cap_at_three() {
        let mut s = Streak::default();
        s.add_tokens(5);
        assert_eq!(s.tokens, 3);
        s.mark_active(d("2026-10-26"));
        s.mark_active(d("2026-10-29")); // Tue, Wed missed → 2 tokens
        assert_eq!((s.current, s.tokens), (2, 1));
        assert_eq!(s.as_of(d("2026-11-04")).current, 0); // Fri..Tue missed
        assert_eq!(s.current, 2, "as_of does not mutate");
    }

    #[test]
    fn a_token_every_thirty_days() {
        let mut s = Streak::default();
        let mut day = d("2026-01-05");
        while s.current < 30 {
            s.mark_active(day);
            day = day.succ_opt().unwrap();
        }
        assert_eq!(s.tokens, 1);
    }
}
