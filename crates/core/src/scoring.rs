//! Person-days and leverage (SPEC 5.3, 5.4). Constants live in
//! assets/scoring.toml so they can be versioned.

use std::collections::HashMap;
use std::sync::OnceLock;

use serde::Deserialize;

use crate::event::TaskClass;

pub const BUILTIN_TOML: &str = include_str!("../../../assets/scoring.toml");

/// Leverage below this many active minutes is not shown (SPEC 5.4).
pub const LEVERAGE_MIN_ACTIVE: f64 = 5.0;
pub const LEVERAGE_DISPLAY_CAP: f64 = 50.0;
/// Gaps between turns shorter than this count as active time (SPEC 2).
pub const ACTIVE_GAP_MINUTES: f64 = 10.0;

#[derive(Debug, Clone, Deserialize)]
pub struct ScoringConstants {
    pub version: String,
    pub base: HashMap<String, f64>,
    pub weights: Weights,
    pub caps: Caps,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Weights {
    pub file: f64,
    pub line_coef: f64,
    pub line_exp: f64,
    pub test: f64,
    pub subagent: f64,
    pub merge: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Caps {
    pub turn_min: f64,
    pub turn_max: f64,
    pub minutes_per_day: f64,
    pub daily_person_days: f64,
    pub weekly_person_days: f64,
}

impl ScoringConstants {
    pub fn parse(src: &str) -> Result<ScoringConstants, String> {
        let k: ScoringConstants = toml::from_str(src).map_err(|e| e.to_string())?;
        for c in TaskClass::ALL {
            if !k.base.contains_key(c.as_str()) {
                return Err(format!("scoring.toml: missing base for {}", c.as_str()));
            }
        }
        Ok(k)
    }

    pub fn builtin() -> &'static ScoringConstants {
        static K: OnceLock<ScoringConstants> = OnceLock::new();
        K.get_or_init(|| ScoringConstants::parse(BUILTIN_TOML).expect("built-in scoring.toml"))
    }

    pub fn base_for(&self, c: TaskClass) -> f64 {
        self.base[c.as_str()]
    }
}

/// The per-turn inputs of the formula.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TurnSignals {
    pub class: TaskClass,
    pub files: u32,
    /// Lines added + removed.
    pub lines: u32,
    pub test_run: bool,
    pub subagents: u32,
    /// A commit or merge happened in the turn.
    pub merged: bool,
}

/// H: human-equivalent minutes for one turn (SPEC 5.3).
pub fn human_minutes(k: &ScoringConstants, s: &TurnSignals) -> f64 {
    let w = &k.weights;
    let h = k.base_for(s.class)
        + w.file * s.files as f64
        + w.line_coef * (s.lines as f64).powf(w.line_exp)
        + w.test * s.test_run as u8 as f64
        + w.subagent * s.subagents as f64
        + w.merge * s.merged as u8 as f64;
    h.clamp(k.caps.turn_min, k.caps.turn_max)
}

/// Person-days a turn adds after the daily and weekly caps. The part above a
/// cap is simply not counted (SPEC 5.3).
pub fn credit(k: &ScoringConstants, h_minutes: f64, day_so_far: f64, week_so_far: f64) -> f64 {
    let pd = h_minutes / k.caps.minutes_per_day;
    let day_room = (k.caps.daily_person_days - day_so_far).max(0.0);
    let week_room = (k.caps.weekly_person_days - week_so_far).max(0.0);
    pd.min(day_room).min(week_room)
}

pub fn leverage(human_minutes: f64, active_minutes: f64) -> Option<f64> {
    if active_minutes < LEVERAGE_MIN_ACTIVE {
        None
    } else {
        Some(human_minutes / active_minutes)
    }
}

pub fn fmt_leverage(l: Option<f64>) -> String {
    match l {
        None => "—".to_string(),
        Some(x) if x > LEVERAGE_DISPLAY_CAP => format!("{}x+", LEVERAGE_DISPLAY_CAP as u32),
        Some(x) => format!("{x:.1}x"),
    }
}

/// Minutes of the gap between two turns that count as active.
pub fn active_gap(gap_minutes: f64) -> f64 {
    if gap_minutes > 0.0 && gap_minutes < ACTIVE_GAP_MINUTES {
        gap_minutes
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize)]
    struct Golden {
        case: Vec<Case>,
    }

    #[derive(Deserialize)]
    struct Case {
        name: String,
        class: String,
        #[serde(default)]
        files: u32,
        #[serde(default)]
        lines: u32,
        #[serde(default)]
        test: bool,
        #[serde(default)]
        subagents: u32,
        #[serde(default)]
        merged: bool,
        h: f64,
    }

    #[test]
    fn golden_cases() {
        let g: Golden = toml::from_str(include_str!("../../../fixtures/scoring/golden.toml")).unwrap();
        assert!(g.case.len() >= 24);
        let k = ScoringConstants::builtin();
        for c in g.case {
            let s = TurnSignals {
                class: TaskClass::parse(&c.class).unwrap(),
                files: c.files,
                lines: c.lines,
                test_run: c.test,
                subagents: c.subagents,
                merged: c.merged,
            };
            let h = human_minutes(k, &s);
            assert!((h - c.h).abs() < 0.5, "{}: got {h:.2}, want {}", c.name, c.h);
        }
    }

    #[test]
    fn caps() {
        let k = ScoringConstants::builtin();
        assert_eq!(credit(k, 360.0, 0.0, 0.0), 0.75);
        assert!((credit(k, 360.0, 5.5, 0.0) - 0.5).abs() < 1e-9);
        assert_eq!(credit(k, 360.0, 6.0, 0.0), 0.0);
        assert!((credit(k, 360.0, 0.0, 29.9) - 0.1).abs() < 1e-9);
        assert_eq!(credit(k, 360.0, 0.0, 30.0), 0.0);
    }

    #[test]
    fn leverage_needs_five_active_minutes() {
        assert_eq!(leverage(100.0, 4.9), None);
        assert_eq!(leverage(100.0, 10.0), Some(10.0));
        assert_eq!(fmt_leverage(Some(7.14)), "7.1x");
        assert_eq!(fmt_leverage(Some(51.0)), "50x+");
        assert_eq!(fmt_leverage(None), "—");
        assert_eq!(active_gap(9.0), 9.0);
        assert_eq!(active_gap(10.0), 0.0);
    }

    #[test]
    fn rejects_incomplete_constants() {
        assert!(ScoringConstants::parse("version='x'\n[base]\nfeature=1\n[weights]\nfile=1\nline_coef=1\nline_exp=1\ntest=1\nsubagent=1\nmerge=1\n[caps]\nturn_min=1\nturn_max=2\nminutes_per_day=3\ndaily_person_days=4\nweekly_person_days=5").is_err());
    }
}
