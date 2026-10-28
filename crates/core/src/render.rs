//! Terminal text: the end-of-turn box (SPEC 8.3), the grand badge, the status
//! line (SPEC 4.2) and the pages behind `stats` / `badges` (SPEC 10.6).
//! Copy follows SPEC 8.5: talk output, never savings, tokens or cost.

use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::scoring::fmt_leverage;

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

/// What the end-of-turn box shows: this turn's value, the rank, the
/// running totals, and one optional line for whatever just moved.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TurnSummary {
    pub value_usd: f64,
    pub person_days: f64,
    pub class_name: String,
    pub files: u32,
    pub test_passed: Option<bool>,
    pub committed: bool,
    pub rank_label: String,
    pub xp: u64,
    /// 0‥1 through the current division.
    pub rank_progress: f64,
    /// None in the top rank.
    pub xp_to_next: Option<u64>,
    pub today_usd: f64,
    pub week_usd: f64,
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

pub fn settlement_box(s: &TurnSummary) -> String {
    let title = "─ 产出 ";
    let top = format!("┌{title}{}┐", "─".repeat(INNER.saturating_sub(width(title))));
    // Tags shown in this order; when they do not all fit, the lowest
    // priority ones are dropped whole rather than cut.
    let mut tags: Vec<(u8, String)> = vec![(0, format!("{} 人日", fmt_pd(s.person_days))), (1, s.class_name.clone())];
    if s.files > 0 {
        tags.push((3, format!("{} 个文件", s.files)));
    }
    match s.test_passed {
        Some(true) => tags.push((2, "测试通过".into())),
        Some(false) => tags.push((2, "测试未过".into())),
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
    let rank_right = match s.xp_to_next {
        Some(n) => format!("{} XP {} 还差 {}", fmt_int(s.xp as i64), ring_bar(s.rank_progress, 1.0, 5), fmt_int(n as i64)),
        None => format!("{} XP · 已是最高段位", fmt_int(s.xp as i64)),
    };
    let mut lines = vec![
        top,
        row(&cols(&format!("+{}", fmt_usd(s.value_usd)), &what)),
        row(&cols(&s.rank_label, &rank_right)),
        row(&cols(
            &format!("今日 {}", fmt_usd(s.today_usd)),
            &format!("本周 {} · 杠杆 {}", fmt_usd(s.week_usd), fmt_leverage(s.leverage)),
        )),
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
    pub rank_label: String,
    pub xp: u64,
    pub rank_progress: f64,
    pub today_usd: f64,
    pub week_usd: f64,
    pub leverage: Option<f64>,
}

pub fn status_line(s: &StatusInfo) -> String {
    let mut parts = vec![
        format!("▮ {} · {} XP {}", s.rank_label, fmt_int(s.xp as i64), ring_bar(s.rank_progress, 1.0, 5)),
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
            value_usd: 268.8,
            person_days: 0.42,
            class_name: "重构".into(),
            files: 6,
            test_passed: Some(true),
            committed: false,
            rank_label: "黄金 II".into(),
            xp: 8_920,
            rank_progress: 0.57,
            xp_to_next: Some(1_080),
            today_usd: 312.0,
            week_usd: 1_240.0,
            leverage: Some(7.1),
            highlight: Some("晋级 黄金 II".into()),
        };
        let b = settlement_box(&s);
        for line in b.lines() {
            assert_eq!(width(line), BOX_WIDTH, "{line}");
        }
        assert!(b.contains("+$269        0.42 人日 · 重构 · 测试通过"), "{b}");
        assert!(!b.contains("6 个文件"), "files give way before the test result: {b}");
        assert!(b.contains("黄金 II      8,920 XP ▓▓▓░░ 还差 1,080"), "{b}");
        assert!(b.contains("今日 $312    本周 $1,240 · 杠杆 7.1x"), "{b}");
        assert!(b.contains("✦ 晋级 黄金 II"));
        assert_eq!(b.lines().count(), 6);
        let without = settlement_box(&TurnSummary { highlight: None, ..s.clone() });
        assert_eq!(without.lines().count(), 5);
        let crowded = settlement_box(&TurnSummary { class_name: "新功能".into(), committed: true, ..s.clone() });
        assert!(crowded.contains("0.42 人日 · 新功能") && !crowded.contains("已提交"), "extras give way: {crowded}");
        let top = settlement_box(&TurnSummary { xp_to_next: None, rank_label: "王者".into(), ..s });
        assert!(top.contains("已是最高段位"));
    }

    #[test]
    fn long_content_is_cut() {
        let s = TurnSummary { class_name: "很长".repeat(30), ..Default::default() };
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
            rank_label: "黄金 II".into(),
            xp: 8_920,
            rank_progress: 0.57,
            today_usd: 312.0,
            week_usd: 1_240.0,
            leverage: Some(6.8),
        };
        assert_eq!(status_line(&s), "▮ 黄金 II · 8,920 XP ▓▓▓░░ · 今日 $312 · 本周 $1,240 · 杠杆 6.8x");
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
