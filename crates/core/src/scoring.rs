//! Person-days and leverage (SPEC 5.3, 5.4). How many minutes a turn is
//! worth comes from occupation.rs; the caps live in assets/scoring.toml so
//! they can be versioned.

use std::sync::OnceLock;

use serde::Deserialize;

pub const BUILTIN_TOML: &str = include_str!("../../../assets/scoring.toml");

/// Leverage below this many active minutes is not shown (SPEC 5.4).
pub const LEVERAGE_MIN_ACTIVE: f64 = 5.0;
pub const LEVERAGE_DISPLAY_CAP: f64 = 50.0;
/// Gaps between turns shorter than this count as active time (SPEC 2).
pub const ACTIVE_GAP_MINUTES: f64 = 10.0;

#[derive(Debug, Clone, Deserialize)]
pub struct ScoringConstants {
    pub version: String,
    pub units: Units,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Units {
    pub minutes_per_day: f64,
}

impl ScoringConstants {
    pub fn parse(src: &str) -> Result<ScoringConstants, String> {
        toml::from_str(src).map_err(|e| e.to_string())
    }

    pub fn builtin() -> &'static ScoringConstants {
        static K: OnceLock<ScoringConstants> = OnceLock::new();
        K.get_or_init(|| ScoringConstants::parse(BUILTIN_TOML).expect("built-in scoring.toml"))
    }
}

/// What a turn did, for badges and the settlement box.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TurnSignals {
    pub files: u32,
    /// Lines added + removed.
    pub lines: u32,
    pub test_run: bool,
    pub subagents: u32,
    /// A commit or merge happened in the turn.
    pub merged: bool,
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
        assert!(ScoringConstants::parse("version='x'\n[units]").is_err());
        assert_eq!(ScoringConstants::builtin().units.minutes_per_day, 480.0);
    }
}
