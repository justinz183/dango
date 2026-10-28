//! "Who you would have hired" (docs/DESIGN.md v3). Each step an agent takes
//! is attributed to one occupation with the minutes a person in that job
//! would need for it; occupations are priced from assets/occupations.toml.
//! Pure: callers pass in what they observed and keep only the result.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::Deserialize;

pub const BUILTIN_TOML: &str = include_str!("../../../assets/occupations.toml");

/// Minutes added to a turn's main occupation for reading the ask and
/// reporting back.
pub const TURN_BASE_MINUTES: f64 = 5.0;
/// Minutes per subagent, added to the turn's main occupation.
pub const SUBAGENT_MINUTES: f64 = 12.0;
/// A turn that did nothing observable is a short consult.
pub const CONSULT: (&str, f64) = ("research", 5.0);
/// Professional drafting-and-editing pace for prose.
pub const WORDS_PER_HOUR: f64 = 500.0;

#[derive(Debug, Clone, Deserialize)]
pub struct Occupation {
    pub id: String,
    pub name: String,
    pub name_en: String,
    pub soc: String,
    /// US$ per hour.
    pub rate: f64,
    pub color: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Table {
    pub source: String,
    /// The source, said on cards and the dashboard.
    pub label: String,
    pub as_of: String,
    pub occupation: Vec<Occupation>,
}

impl Table {
    pub fn parse(src: &str) -> Result<Table, String> {
        let t: Table = toml::from_str(src).map_err(|e| e.to_string())?;
        for id in REQUIRED {
            if !t.occupation.iter().any(|o| o.id == id) {
                return Err(format!("occupations.toml: missing {id}"));
            }
        }
        Ok(t)
    }

    pub fn builtin() -> &'static Table {
        static T: OnceLock<Table> = OnceLock::new();
        T.get_or_init(|| Table::parse(BUILTIN_TOML).expect("built-in occupations.toml"))
    }

    pub fn get(&self, id: &str) -> Option<&Occupation> {
        self.occupation.iter().find(|o| o.id == id)
    }

    pub fn rate(&self, id: &str) -> f64 {
        self.get(id).map(|o| o.rate).unwrap_or(0.0)
    }

    pub fn name(&self, id: &str) -> &str {
        self.get(id).map(|o| o.name.as_str()).unwrap_or("其他")
    }

    /// US$ for a set of minutes per occupation.
    pub fn usd(&self, work: &BTreeMap<String, f64>) -> f64 {
        work.iter().map(|(id, m)| m / 60.0 * self.rate(id)).sum()
    }
}

/// Every id the attribution rules can return.
const REQUIRED: [&str; 12] = ["swe", "web", "qa", "ops", "data", "fin", "research", "writer", "translator", "designer", "video", "entry"];

fn ext(path: &str) -> String {
    let name = path.rsplit(['/', '\\']).next().unwrap_or("");
    match name.rsplit_once('.') {
        Some((stem, e)) if !stem.is_empty() => e.to_lowercase(),
        _ => String::new(),
    }
}

/// Words in prose: each CJK character counts as one, as do Latin words.
pub fn word_count(text: &str) -> u32 {
    let mut n = 0;
    let mut in_word = false;
    for ch in text.chars() {
        if ('\u{4e00}'..='\u{9fff}').contains(&ch) || ('\u{3040}'..='\u{30ff}').contains(&ch) {
            n += 1;
            in_word = false;
        } else if ch.is_ascii_alphanumeric() {
            if !in_word {
                n += 1;
            }
            in_word = true;
        } else {
            in_word = false;
        }
    }
    n
}

/// One file edit. `lines` = lines added + removed, `words` = words added.
pub fn for_edit(path: &str, lines: u32, words: u32) -> (&'static str, f64) {
    let e = ext(path);
    // A leading "/" so relative paths match the directory patterns too.
    let low = format!("/{}", path.to_lowercase());
    match e.as_str() {
        "md" | "mdx" | "txt" | "rst" | "docx" | "tex" | "adoc" => ("writer", (words as f64 / WORDS_PER_HOUR * 60.0).max(3.0)),
        "toml" | "yaml" | "yml" | "json" | "plist" | "ini" | "env" | "conf" | "lock" => ("ops", 5.0),
        "svg" | "png" | "jpg" | "jpeg" | "webp" | "gif" | "psd" | "ai" | "fig" => ("designer", 30.0),
        _ => {
            // The code part of SPEC §5.3: a file touched plus lines changed.
            let m = 2.5 + 0.45 * (lines.max(1) as f64).powf(0.8);
            let test = ["/test/", "/tests/", "/spec/", "__tests__", "_test.", ".test.", ".spec."].iter().any(|t| low.contains(t))
                || low.rsplit('/').next().is_some_and(|n| n.starts_with("test_"));
            if test {
                ("qa", m)
            } else if matches!(e.as_str(), "html" | "htm" | "css" | "scss" | "sass" | "less" | "tsx" | "jsx" | "vue" | "svelte") {
                ("web", m)
            } else {
                ("swe", m)
            }
        }
    }
}

/// One shell command. None when it is plumbing nobody would be paid for
/// (ls, cd, cat, …). Data and research steps come back as `data`; a turn
/// about markets turns them into `fin` later (see `remap`).
pub fn for_command(cmd: &str) -> Option<(&'static str, f64)> {
    let c = cmd.to_lowercase();
    let has = |k: &str| c.contains(k);
    let info = crate::classify::analyze_command(cmd);
    Some(if has("ffmpeg") || has("moviepy") || has("remotion") || has("melt ") {
        ("video", 15.0)
    } else if has("whisper") {
        ("video", 20.0)
    } else if has("edge-tts") || has("say -") || has(" tts") {
        ("video", 15.0)
    } else if has("yt-dlp") || has("youtube-dl") {
        ("video", 5.0)
    } else if has("tesseract") || has("ocrmypdf") || has(" ocr") || has("_ocr") || has("ocr.") {
        ("entry", 15.0)
    } else if has("magick") || has("convert ") || has("inkscape") || has("rsvg") {
        ("designer", 15.0)
    } else if info.test {
        ("qa", 10.0)
    } else if matches!(info.git, Some(crate::event::GitAction::Commit | crate::event::GitAction::Merge)) {
        ("swe", 20.0)
    } else if has("pip install") || has("brew ") || has("launchctl") || has("npm install") || has("pnpm install") || has("rustup") || has("docker ") || has("systemctl") {
        ("ops", 5.0)
    } else if has("curl ") || has("wget ") || has("sqlite3") || has("psql") || has("duckdb") || has("pandas") {
        ("data", 6.0)
    } else if has("python") || has("jupyter") || has("rscript") {
        ("data", 4.0)
    } else if has("cargo build") || has("npm run build") || has("swiftc") || has("make") || has("tsc") {
        ("swe", 2.0)
    } else {
        return None;
    })
}

/// A non-shell tool call: web research, connectors, browsing.
pub fn for_tool(name: &str) -> Option<(&'static str, f64)> {
    Some(match name {
        "WebSearch" => ("research", 5.0),
        "WebFetch" => ("research", 10.0),
        _ if name.starts_with("mcp__") => {
            let server = name.split("__").nth(1).unwrap_or("");
            let action = name.rsplit("__").next().unwrap_or("");
            if is_finance_server(server) {
                ("fin", 10.0)
            } else if server.contains("Browser") || server.contains("chrome") {
                if ["get_page_text", "read_page", "navigate"].iter().any(|a| action.contains(a)) {
                    ("research", 5.0)
                } else {
                    return None;
                }
            } else if ["dune", "postgres", "bigquery", "snowflake", "sql"].iter().any(|s| server.to_lowercase().contains(s)) {
                ("data", 10.0)
            } else {
                return None;
            }
        }
        _ => return None,
    })
}

pub fn is_finance_server(server: &str) -> bool {
    let s = server.to_lowercase();
    ["financial", "finance", "fmp", "stock", "market", "defillama", "rootdata"].iter().any(|k| s.contains(k))
}

/// Prompt words that make research and data work count as a financial
/// analyst's.
pub fn is_finance_prompt(prompt: &str) -> bool {
    let p = prompt.to_lowercase();
    const ZH: [&str; 10] = ["股票", "财报", "估值", "美股", "港股", "个股", "持仓", "基金", "投资", "交易"];
    const EN: [&str; 8] = ["stock", "ticker", "earnings", "valuation", "10-k", "dcf", "portfolio", "equity"];
    ZH.iter().any(|k| p.contains(k)) || {
        let words: Vec<&str> = p.split(|c: char| !c.is_ascii_alphanumeric() && c != '-').collect();
        EN.iter().any(|k| words.contains(k))
    }
}

pub fn is_translate_prompt(prompt: &str) -> bool {
    let p = prompt.to_lowercase();
    p.contains("翻译") || p.contains("translate") || p.contains("translation")
}

/// Applies a turn's context: research and data work in a turn about markets
/// is a financial analyst's; writing in a turn asking for a translation is
/// a translator's.
pub fn remap(work: &mut BTreeMap<String, f64>, finance: bool, translate: bool) {
    let mut moves = Vec::new();
    if finance {
        moves.push(("research", "fin"));
        moves.push(("data", "fin"));
    }
    if translate {
        moves.push(("writer", "translator"));
    }
    for (from, to) in moves {
        if let Some(m) = work.remove(from) {
            *work.entry(to.to_string()).or_default() += m;
        }
    }
}

/// The occupation with the most minutes (ties broken by id).
pub fn main(work: &BTreeMap<String, f64>) -> Option<String> {
    work.iter().max_by(|a, b| a.1.partial_cmp(b.1).unwrap().then(b.0.cmp(a.0))).map(|(k, _)| k.clone())
}

/// A finished turn's minutes per occupation: its steps, plus subagents and
/// the per-turn base on the main occupation, scaled down together when the
/// turn exceeds `cap` minutes.
pub fn finish(mut work: BTreeMap<String, f64>, subagents: u32, cap: f64) -> BTreeMap<String, f64> {
    work.retain(|_, m| *m > 0.0);
    if work.is_empty() {
        work.insert(CONSULT.0.to_string(), CONSULT.1 + SUBAGENT_MINUTES * subagents as f64);
    } else if let Some(m) = main(&work) {
        *work.get_mut(&m).unwrap() += TURN_BASE_MINUTES + SUBAGENT_MINUTES * subagents as f64;
    }
    let total: f64 = work.values().sum();
    if total > cap {
        let k = cap / total;
        work.values_mut().for_each(|m| *m *= k);
    }
    work
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_is_complete_and_sourced() {
        let t = Table::builtin();
        assert_eq!(t.occupation.len(), 12);
        assert!(t.source.contains("BLS"));
        assert_eq!(t.rate("swe"), 65.38);
        assert_eq!(t.name("video"), "视频剪辑");
        for o in &t.occupation {
            assert!(o.rate > 10.0 && o.rate < 100.0, "{}", o.id);
            assert!(o.color.starts_with('#') && o.color.len() == 7, "{}", o.id);
        }
    }

    #[test]
    fn words() {
        assert_eq!(word_count("你好，世界"), 4);
        assert_eq!(word_count("Hello brave new world"), 4);
        assert_eq!(word_count("Claude 写了 3 段"), 5);
    }

    #[test]
    fn edits_by_file_kind() {
        assert_eq!(for_edit("src/main.rs", 10, 0).0, "swe");
        assert_eq!(for_edit("web/App.tsx", 10, 0).0, "web");
        assert_eq!(for_edit("tests/test_api.py", 10, 0).0, "qa");
        assert_eq!(for_edit("config.toml", 3, 0), ("ops", 5.0));
        assert_eq!(for_edit("poster.svg", 300, 0), ("designer", 30.0));
        assert_eq!(for_edit("notes.md", 40, 1000), ("writer", 120.0));
        assert_eq!(for_edit("notes.md", 1, 10), ("writer", 3.0), "a floor for tiny edits");
        let (_, m) = for_edit("a.rs", 252, 0);
        assert!((m - (2.5 + 0.45 * 252f64.powf(0.8))).abs() < 1e-9);
    }

    #[test]
    fn commands() {
        assert_eq!(for_command("ffmpeg -i a.mp4 -vf scale=720:-2 b.mp4"), Some(("video", 15.0)));
        assert_eq!(for_command("whisper talk.m4a --language zh"), Some(("video", 20.0)));
        assert_eq!(for_command("edge-tts --text hi --write-media a.mp3"), Some(("video", 15.0)));
        assert_eq!(for_command("yt-dlp https://example.com/v"), Some(("video", 5.0)));
        assert_eq!(for_command("python3 run_ocr.py page1.png"), Some(("entry", 15.0)));
        assert_eq!(for_command("cargo test --workspace"), Some(("qa", 10.0)));
        assert_eq!(for_command("git commit -m x"), Some(("swe", 20.0)));
        assert_eq!(for_command("pip install pandas"), Some(("ops", 5.0)));
        assert_eq!(for_command("curl -s https://api.example.com/x"), Some(("data", 6.0)));
        assert_eq!(for_command("python3 analyze.py"), Some(("data", 4.0)));
        assert_eq!(for_command("ls -la"), None);
        assert_eq!(for_command("cat README.md | head"), None);
    }

    #[test]
    fn tools() {
        assert_eq!(for_tool("WebSearch"), Some(("research", 5.0)));
        assert_eq!(for_tool("WebFetch"), Some(("research", 10.0)));
        assert_eq!(for_tool("mcp__financial-datasets__get_income_statement"), Some(("fin", 10.0)));
        assert_eq!(for_tool("mcp__Claude_Browser__get_page_text"), Some(("research", 5.0)));
        assert_eq!(for_tool("mcp__Claude_Browser__computer"), None);
        assert_eq!(for_tool("Read"), None);
    }

    #[test]
    fn context_moves_work() {
        let mut w: BTreeMap<String, f64> = [("research".into(), 10.0), ("data".into(), 4.0), ("writer".into(), 30.0)].into();
        remap(&mut w, true, true);
        assert_eq!(w.get("fin"), Some(&14.0));
        assert_eq!(w.get("translator"), Some(&30.0));
        assert!(!w.contains_key("research") && !w.contains_key("writer"));
        assert!(is_finance_prompt("帮我看看英伟达的财报"));
        assert!(is_finance_prompt("Compare NVDA earnings"));
        assert!(!is_finance_prompt("restock the fridge list"));
        assert!(is_translate_prompt("把这段翻译成英文"));
    }

    #[derive(serde::Deserialize)]
    struct Golden {
        case: Vec<Case>,
    }

    #[derive(serde::Deserialize)]
    struct Case {
        name: String,
        #[serde(default)]
        steps: Vec<Step>,
        #[serde(default)]
        subagents: u32,
        #[serde(default)]
        finance: bool,
        #[serde(default)]
        translate: bool,
        main: String,
        minutes: f64,
        usd: f64,
    }

    #[derive(serde::Deserialize)]
    struct Step {
        edit: Option<String>,
        #[serde(default)]
        lines: u32,
        #[serde(default)]
        words: u32,
        cmd: Option<String>,
        tool: Option<String>,
    }

    #[test]
    fn golden_turns() {
        let g: Golden = toml::from_str(include_str!("../../../fixtures/scoring/golden.toml")).unwrap();
        assert!(g.case.len() >= 12);
        for c in g.case {
            let mut work = BTreeMap::new();
            for s in &c.steps {
                let (occ, m) = match (&s.edit, &s.cmd, &s.tool) {
                    (Some(path), _, _) => for_edit(path, s.lines, s.words),
                    (_, Some(cmd), _) => for_command(cmd).unwrap_or_else(|| panic!("{}: {cmd} counts", c.name)),
                    (_, _, Some(tool)) => for_tool(tool).unwrap_or_else(|| panic!("{}: {tool} counts", c.name)),
                    _ => panic!("{}: empty step", c.name),
                };
                *work.entry(occ.to_string()).or_insert(0.0) += m;
            }
            remap(&mut work, c.finance, c.translate);
            let w = finish(work, c.subagents, 360.0);
            let minutes: f64 = w.values().sum();
            let usd = Table::builtin().usd(&w);
            assert_eq!(main(&w).as_deref(), Some(c.main.as_str()), "{}", c.name);
            assert!((minutes - c.minutes).abs() < 0.01, "{}: {minutes:.2} min, want {}", c.name, c.minutes);
            assert!((usd - c.usd).abs() < 0.01, "{}: ${usd:.2}, want {}", c.name, c.usd);
        }
    }

    #[test]
    fn finishing_a_turn() {
        let w = finish(BTreeMap::new(), 0, 360.0);
        assert_eq!(w.get("research"), Some(&5.0), "talk-only turn");
        let w = finish(BTreeMap::new(), 1, 360.0);
        assert_eq!(w.get("research"), Some(&17.0), "subagents still count");
        let w = finish([("video".into(), 30.0), ("swe".into(), 10.0)].into(), 2, 360.0);
        assert_eq!(w.get("video"), Some(&(30.0 + 5.0 + 24.0)));
        assert_eq!(w.get("swe"), Some(&10.0));
        let w = finish([("swe".into(), 600.0), ("qa".into(), 200.0)].into(), 0, 360.0);
        let total: f64 = w.values().sum();
        assert!((total - 360.0).abs() < 1e-9);
        assert!((w["swe"] / w["qa"] - 605.0 / 200.0).abs() < 1e-9, "scaled together");
        let t = Table::builtin();
        let usd = t.usd(&[("swe".to_string(), 60.0), ("video".to_string(), 30.0)].into());
        assert!((usd - (65.38 + 36.26 / 2.0)).abs() < 1e-9);
    }
}
