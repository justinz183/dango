//! Terminal text: the end-of-turn box (SPEC 8.3), the grand badge, the status
//! line (SPEC 4.2) and the pages behind `stats` / `badges` (SPEC 10.6).
//! Copy follows SPEC 8.5: talk output, never savings, tokens or cost.

use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::pricing::fmt_leverage;

/// Total box width in terminal cells, borders included.
pub const BOX_WIDTH: usize = 44;
const INNER: usize = BOX_WIDTH - 2;

pub fn width(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

/// Cuts `s` to `max` cells, ending with "…" when something was dropped.
pub fn truncate(s: &str, max: usize) -> String {
    if width(s) <= max {
        return s.to_string();
    }
    let mut out = String::new();
    let mut w = 0;
    for ch in s.chars() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if w + cw + 1 > max {
            break;
        }
        out.push(ch);
        w += cw;
    }
    out.push('…');
    out
}

pub fn pad(s: &str, w: usize) -> String {
    let s = truncate(s, w);
    let fill = w.saturating_sub(width(&s));
    format!("{s}{}", " ".repeat(fill))
}

pub fn center(s: &str, w: usize) -> String {
    let s = truncate(s, w);
    let total = w.saturating_sub(width(&s));
    let left = total / 2;
    format!("{}{s}{}", " ".repeat(left), " ".repeat(total - left))
}

/// "▓▓▓░░" — filled cells for progress toward a target.
pub fn ring_bar(value: f64, target: f64, cells: usize) -> String {
    // Rounded, but only a closed ring shows every cell.
    let filled = if target <= 0.0 || value >= target {
        cells
    } else {
        ((value / target) * cells as f64).round().clamp(0.0, (cells - 1) as f64) as usize
    };
    format!("{}{}", "▓".repeat(filled), "░".repeat(cells - filled))
}

/// Person-days, two decimals.
pub fn fmt_pd(x: f64) -> String {
    format!("{x:.2}")
}

/// Trims trailing zeros: 5 → "5", 3.6 → "3.6", 3.25 → "3.2".
pub fn fmt_short(x: f64) -> String {
    let s = format!("{x:.1}");
    s.strip_suffix(".0").map(str::to_string).unwrap_or(s)
}

pub fn fmt_int(n: i64) -> String {
    let s = n.abs().to_string();
    let mut out = String::new();
    for (i, ch) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    if n < 0 {
        format!("-{out}")
    } else {
        out
    }
}

fn row(content: &str) -> String {
    format!("│{}│", pad(&format!("  {content}"), INNER))
}

fn cols(left: &str, right: &str) -> String {
    format!("{}{right}", pad(left, 13))
}

/// Room for line 4's text after "✦ ".
pub const HIGHLIGHT_WIDTH: usize = INNER - 4;

/// What the end-of-turn box shows: what this turn would have cost to hire
/// out and to whom, the running totals, how today stands against the best
/// day so far, and one optional line for whatever just moved.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TurnSummary {
    pub usd: f64,
    pub hours: f64,
    /// Occupation names, most minutes first.
    pub jobs: Vec<String>,
    pub files: u32,
    pub test_passed: Option<bool>,
    pub committed: bool,
    pub today_usd: f64,
    pub week_usd: f64,
    pub total_usd: f64,
    /// The best day so far, today included.
    pub record_usd: f64,
    pub leverage: Option<f64>,
    pub highlight: Option<String>,
}

/// "$4.3" under ten dollars, "$1,240" above.
pub fn fmt_usd(x: f64) -> String {
    if x.abs() < 10.0 {
        format!("${x:.1}")
    } else {
        format!("${}", fmt_int(x.round() as i64))
    }
}

/// "25 分钟" under an hour, "3.4h" under a hundred, "123h" above.
pub fn fmt_hours(h: f64) -> String {
    if h < 1.0 {
        format!("{} 分钟", (h * 60.0).round() as i64)
    } else if h < 100.0 {
        format!("{h:.1}h")
    } else {
        format!("{}h", fmt_int(h.round() as i64))
    }
}

pub fn settlement_box(s: &TurnSummary) -> String {
    let title = "─ 产出 ";
    let top = format!("┌{title}{}┐", "─".repeat(INNER.saturating_sub(width(title))));
    // Tags shown in this order; when they do not all fit, the lowest
    // priority ones are dropped whole rather than cut.
    let mut tags: Vec<(u8, String)> = vec![(0, fmt_hours(s.hours))];
    for (i, j) in s.jobs.iter().take(2).enumerate() {
        tags.push((if i == 0 { 1 } else { 2 }, j.clone()));
    }
    if s.files > 0 {
        tags.push((5, format!("{} 个文件", s.files)));
    }
    match s.test_passed {
        Some(true) => tags.push((3, "测试通过".into())),
        Some(false) => tags.push((3, "测试未过".into())),
        None => {}
    }
    if s.committed {
        tags.push((4, "已提交".into()));
    }
    let room = INNER - 2 - 13;
    let join = |t: &[(u8, String)]| t.iter().map(|(_, x)| x.as_str()).collect::<Vec<_>>().join(" · ");
    while tags.len() > 1 && width(&join(&tags)) > room {
        let lowest = tags.iter().enumerate().max_by_key(|(_, (p, _))| *p).map(|(i, _)| i).unwrap();
        tags.remove(lowest);
    }
    let what = join(&tags);
    // Today against the best day: a full bar and "单日新高" once it is beaten.
    let record = if s.record_usd > 0.0 && s.today_usd + 1e-9 >= s.record_usd && s.today_usd > 0.0 {
        format!("{} 单日新高", ring_bar(1.0, 1.0, 5))
    } else {
        format!("{} 单日纪录 {}", ring_bar(s.today_usd, s.record_usd, 5), fmt_usd(s.record_usd))
    };
    let mut lines = vec![
        top,
        row(&cols(&format!("+{}", fmt_usd(s.usd)), &what)),
        row(&cols(
            &format!("今日 {}", fmt_usd(s.today_usd)),
            &format!("本周 {} · 杠杆 {}", fmt_usd(s.week_usd), fmt_leverage(s.leverage)),
        )),
        row(&cols(&format!("累计 {}", fmt_usd(s.total_usd)), &record)),
    ];
    if let Some(h) = &s.highlight {
        lines.push(row(&format!("✦ {h}")));
    }
    lines.push(format!("└{}┘", "─".repeat(INNER)));
    lines.join("\n")
}

/// The terminal stand-in for the grand full-screen ceremony (SPEC 10.6).
pub fn grand_badge(heading: &str, name: &str, line: &str, reward: &str) -> String {
    let r = |s: &str| format!("║{}║", center(s, INNER));
    let mut out = vec![
        format!("╔{}╗", "═".repeat(INNER)),
        r(heading),
        r(""),
        r(name),
        r(&format!("「{line}」")),
    ];
    if !reward.is_empty() {
        out.push(r(reward));
    }
    out.push(format!("╚{}╝", "═".repeat(INNER)));
    out.join("\n")
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct StatusInfo {
    pub total_usd: f64,
    pub today_usd: f64,
    pub week_usd: f64,
    pub leverage: Option<f64>,
}

pub fn status_line(s: &StatusInfo) -> String {
    let mut parts = vec![
        format!("▮ {}", fmt_usd(s.total_usd)),
        format!("今日 {}", fmt_usd(s.today_usd)),
        format!("本周 {}", fmt_usd(s.week_usd)),
    ];
    if s.leverage.is_some() {
        parts.push(format!("杠杆 {}", fmt_leverage(s.leverage)));
    }
    parts.join(" · ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn box_is_44_columns_wide() {
        let s = TurnSummary {
            usd: 212.4,
            hours: 3.36,
            jobs: vec!["程序员".into()],
            files: 6,
            test_passed: Some(true),
            committed: false,
            today_usd: 327.0,
            week_usd: 1_240.0,
            total_usd: 11_724.0,
            record_usd: 1_742.0,
            leverage: Some(7.1),
            highlight: Some("晋级 黄金 II".into()),
        };
        let b = settlement_box(&s);
        for line in b.lines() {
            assert_eq!(width(line), BOX_WIDTH, "{line}");
        }
        assert!(b.contains("+$212        3.4h · 程序员 · 测试通过  "), "files give way first: {b}");
        assert!(b.contains("今日 $327    本周 $1,240 · 杠杆 7.1x"), "{b}");
        assert!(b.contains("累计 $11,724 ▓░░░░ 单日纪录 $1,742"), "{b}");
        assert!(b.contains("✦ 晋级 黄金 II"));
        assert_eq!(b.lines().count(), 6);
        let without = settlement_box(&TurnSummary { highlight: None, ..s.clone() });
        assert_eq!(without.lines().count(), 5);
        let two = settlement_box(&TurnSummary { jobs: vec!["程序员".into(), "测试工程师".into()], committed: true, ..s.clone() });
        assert!(two.contains("3.4h · 程序员 · 测试工程师"), "{two}");
        assert!(!two.contains("已提交"), "extras give way: {two}");
        let short = settlement_box(&TurnSummary { usd: 6.3, hours: 0.17, jobs: vec!["研究员".into()], ..s.clone() });
        assert!(short.contains("+$6.3        10 分钟 · 研究员"), "{short}");
        let best = settlement_box(&TurnSummary { today_usd: 1_800.0, ..s });
        assert!(best.contains("▓▓▓▓▓ 单日新高"), "{best}");
    }

    #[test]
    fn long_content_is_cut() {
        let s = TurnSummary { jobs: vec!["很长".repeat(30)], ..Default::default() };
        for line in settlement_box(&s).lines() {
            assert_eq!(width(line), BOX_WIDTH);
        }
        let g = grand_badge("★ 晋级 ★", "黄金 IV", "一千个人日，灯火通明。", "+2,000 金币 · 霓虹招牌");
        for line in g.lines() {
            assert_eq!(width(line), BOX_WIDTH, "{line}");
        }
    }

    #[test]
    fn status() {
        let s = StatusInfo {
            total_usd: 11_724.0,
            today_usd: 327.0,
            week_usd: 1_240.0,
            leverage: Some(6.8),
        };
        assert_eq!(status_line(&s), "▮ $11,724 · 今日 $327 · 本周 $1,240 · 杠杆 6.8x");
        assert_eq!(fmt_hours(0.5), "30 分钟");
        assert_eq!(fmt_hours(16.53), "16.5h");
        assert_eq!(fmt_hours(1234.0), "1,234h");
        assert_eq!(fmt_usd(4.26), "$4.3");
        assert_eq!(fmt_usd(0.0), "$0.0");
        assert_eq!(fmt_usd(1234.5), "$1,235");
    }

    #[test]
    fn numbers() {
        assert_eq!(fmt_int(1234567), "1,234,567");
        assert_eq!(fmt_int(42), "42");
        assert_eq!(fmt_short(5.0), "5");
        assert_eq!(ring_bar(6.4, 5.0, 5), "▓▓▓▓▓");
        assert_eq!(ring_bar(0.0, 5.0, 5), "░░░░░");
        assert_eq!(ring_bar(4.9, 5.0, 5), "▓▓▓▓░");
    }
}
