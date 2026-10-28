//! XP and ranks. One XP is one human-equivalent minute of credited output
//! (after the daily and weekly caps), so XP only ever grows. Ranks run
//! 青铜 → 王者, each split into four divisions (IV up to I); the top rank
//! has no divisions.

pub struct Rank {
    pub name: &'static str,
    pub name_en: &'static str,
    /// XP where the rank starts.
    pub xp: u64,
    pub color: &'static str,
}

pub const RANKS: [Rank; 7] = [
    Rank { name: "青铜", name_en: "Bronze", xp: 0, color: "#b87333" },
    Rank { name: "白银", name_en: "Silver", xp: 1_000, color: "#a8a9ad" },
    Rank { name: "黄金", name_en: "Gold", xp: 5_000, color: "#d4af37" },
    Rank { name: "铂金", name_en: "Platinum", xp: 15_000, color: "#5fc9c9" },
    Rank { name: "钻石", name_en: "Diamond", xp: 40_000, color: "#7cc4ff" },
    Rank { name: "大师", name_en: "Master", xp: 100_000, color: "#a855f7" },
    Rank { name: "王者", name_en: "Grandmaster", xp: 250_000, color: "#ef5350" },
];

pub const DIVISIONS: u64 = 4;

#[derive(Debug, Clone, PartialEq)]
pub struct Standing {
    pub index: usize,
    /// 4 (lowest) … 1 (highest); 0 in the top rank.
    pub division: u64,
    pub xp: u64,
    /// XP where this division starts.
    pub floor: u64,
    /// XP where the next division (or rank) starts.
    pub next: Option<u64>,
    /// 0‥1 through the current division; 1 in the top rank.
    pub progress: f64,
}

pub fn roman(n: u64) -> &'static str {
    match n {
        1 => "I",
        2 => "II",
        3 => "III",
        4 => "IV",
        _ => "",
    }
}

impl Standing {
    pub fn rank(&self) -> &'static Rank {
        &RANKS[self.index]
    }

    /// "黄金 II", or "王者" at the top.
    pub fn label(&self) -> String {
        if self.division == 0 {
            self.rank().name.to_string()
        } else {
            format!("{} {}", self.rank().name, roman(self.division))
        }
    }

    pub fn label_en(&self) -> String {
        if self.division == 0 {
            self.rank().name_en.to_string()
        } else {
            format!("{} {}", self.rank().name_en, roman(self.division))
        }
    }

    pub fn next_label(&self) -> Option<String> {
        self.next.map(|n| standing(n).label())
    }

    pub fn xp_to_next(&self) -> Option<u64> {
        self.next.map(|n| n.saturating_sub(self.xp))
    }

    /// Strictly increases with every division climbed.
    pub fn level(&self) -> u64 {
        self.index as u64 * DIVISIONS + if self.division == 0 { DIVISIONS } else { DIVISIONS - self.division }
    }
}

pub fn xp_from_pd(person_days: f64, minutes_per_day: f64) -> u64 {
    (person_days * minutes_per_day + 1e-6).floor().max(0.0) as u64
}

pub fn standing(xp: u64) -> Standing {
    let index = RANKS.iter().rposition(|r| xp >= r.xp).unwrap_or(0);
    let Some(next_rank) = RANKS.get(index + 1) else {
        return Standing { index, division: 0, xp, floor: RANKS[index].xp, next: None, progress: 1.0 };
    };
    let (start, span) = (RANKS[index].xp, next_rank.xp - RANKS[index].xp);
    let step = ((xp - start) * DIVISIONS / span).min(DIVISIONS - 1);
    let floor = start + span * step / DIVISIONS;
    let next = start + span * (step + 1) / DIVISIONS;
    Standing {
        index,
        division: DIVISIONS - step,
        xp,
        floor,
        next: Some(next),
        progress: ((xp - floor) as f64 / (next - floor) as f64).clamp(0.0, 1.0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn divisions_and_boundaries() {
        let s = standing(0);
        assert_eq!((s.label(), s.next, s.progress), ("青铜 IV".into(), Some(250), 0.0));
        assert_eq!(standing(249).label(), "青铜 IV");
        assert_eq!(standing(250).label(), "青铜 III");
        assert_eq!(standing(999).label(), "青铜 I");
        assert_eq!(standing(1_000).label(), "白银 IV");
        let s = standing(3_922);
        assert_eq!((s.label(), s.next_label().as_deref(), s.xp_to_next()), ("白银 II".into(), Some("白银 I"), Some(78)));
        assert_eq!(standing(5_000).label(), "黄金 IV");
        assert_eq!(standing(14_999).label(), "黄金 I");
        let top = standing(300_000);
        assert_eq!((top.label(), top.next, top.progress), ("王者".into(), None, 1.0));
    }

    #[test]
    fn level_is_monotonic() {
        let mut last = 0;
        for xp in (0..260_000).step_by(37) {
            let l = standing(xp).level();
            assert!(l >= last, "xp {xp}");
            last = l;
        }
        assert_eq!(standing(250_000).level(), 6 * 4 + 4);
    }

    #[test]
    fn xp_is_whole_minutes() {
        assert_eq!(xp_from_pd(8.17, 480.0), 3_921);
        assert_eq!(xp_from_pd(0.0, 480.0), 0);
        assert_eq!(xp_from_pd(1.0, 480.0), 480);
    }
}
