//! "Who you would have hired" (docs/DESIGN.md v3, v6). Each step an agent
//! takes is attributed to one occupation with the minutes a person in that
//! job would need for it, and a prompt's topic says who a talk-only turn
//! consulted; occupations, scenes, looks and topic keywords come from
//! assets/occupations.toml. Pure: callers pass in what they observed and
//! keep only the result.

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
    /// Where its character works in the office.
    pub scene: String,
    /// Minutes a talk-only turn about it is worth.
    pub consult: f64,
    /// Python / SQL steps in a turn about it are its work, not a data scientist's.
    pub absorbs_data: bool,
    /// What the widget draws on the character, by part name.
    pub look: Vec<String>,
    /// Topic keywords: 2 points and 1 point; a prompt needs 2 to be about it.
    pub strong: Vec<String>,
    pub weak: Vec<String>,
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

    pub fn consult(&self, id: &str) -> f64 {
        self.get(id).map(|o| o.consult).unwrap_or(CONSULT.1)
    }

    pub fn scene(&self, id: &str) -> &str {
        self.get(id).map(|o| o.scene.as_str()).unwrap_or("desk")
    }
}

/// What a prompt is about: the occupation whose keywords score highest
/// (strong 2, weak 1) once it reaches 2 points; ties go to the earlier
/// entry. ASCII keywords match whole words or phrases, others anywhere.
/// The text is read and dropped; only the id leaves.
pub fn topic(prompt: &str) -> Option<&'static str> {
    let p = prompt.to_lowercase();
    let padded: String = std::iter::once(' ')
        .chain(p.chars().map(|c| if c.is_ascii_alphanumeric() || matches!(c, '+' | '#' | '.' | '/' | '-') { c } else { ' ' }))
        .chain(std::iter::once(' '))
        .collect();
    let hit = |kw: &str| if kw.is_ascii() { padded.contains(&format!(" {} ", kw.trim())) } else { p.contains(kw) };
    let mut best: Option<(&'static str, usize)> = None;
    for o in &Table::builtin().occupation {
        // A keyword listed twice counts once.
        let score = 2 * o.strong.iter().filter(|k| hit(k)).count()
            + o.weak.iter().filter(|k| !o.strong.contains(k) && hit(k)).count();
        if score >= 2 && best.map_or(true, |(_, s)| score > s) {
            best = Some((o.id.as_str(), score));
        }
    }
    best.map(|b| b.0)
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

/// Applies a turn's topic: research in a turn about health is the doctor's
/// work, data steps in one about markets the financial analyst's, writing
/// in one asking for a translation the translator's.
pub fn remap(work: &mut BTreeMap<String, f64>, topic: Option<&str>) {
    let Some(tp) = topic else { return };
    let absorbs_data = Table::builtin().get(tp).is_some_and(|o| o.absorbs_data);
    let mut moves = vec![("research", tp)];
    if tp == "translator" {
        moves.push(("writer", tp));
    }
    if absorbs_data {
        moves.push(("data", tp));
    }
    for (from, to) in moves {
        if from == to {
            continue;
        }
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
/// turn exceeds `cap` minutes. A turn with no steps is a consult with the
/// topic's occupation (a researcher when there is none).
pub fn finish(mut work: BTreeMap<String, f64>, subagents: u32, cap: f64, topic: Option<&str>) -> BTreeMap<String, f64> {
    work.retain(|_, m| *m > 0.0);
    if work.is_empty() {
        let who = topic.unwrap_or(CONSULT.0);
        work.insert(who.to_string(), Table::builtin().consult(who) + SUBAGENT_MINUTES * subagents as f64);
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
        assert!(t.occupation.len() >= 49, "{}", t.occupation.len());
        assert!(t.occupation.iter().all(|o| !o.scene.is_empty() && o.consult > 0.0 && !o.strong.is_empty()));
        assert_eq!(t.scene("doctor"), "clinic");
        assert!(t.source.contains("BLS"));
        assert_eq!(t.rate("swe"), 65.38);
        assert_eq!(t.name("video"), "视频剪辑");
        for o in &t.occupation {
            assert!(o.rate > 10.0 && o.rate < 150.0, "{}", o.id);
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
        remap(&mut w, Some("fin"));
        assert_eq!((w.get("fin"), w.get("writer")), (Some(&14.0), Some(&30.0)), "markets absorb research and data");
        assert!(!w.contains_key("research") && !w.contains_key("data"));
        let mut w: BTreeMap<String, f64> = [("writer".into(), 30.0), ("research".into(), 5.0)].into();
        remap(&mut w, Some("translator"));
        assert_eq!(w.get("translator"), Some(&35.0));
        let mut w: BTreeMap<String, f64> = [("research".into(), 5.0)].into();
        remap(&mut w, None);
        assert_eq!(w.get("research"), Some(&5.0), "no topic, nothing moves");
        assert_eq!(topic("帮我看看英伟达的财报"), Some("fin"));
        assert_eq!(topic("Compare NVDA earnings"), Some("fin"));
        assert_eq!(topic("restock the fridge list"), None, "whole words only");
        assert_eq!(topic("把这段翻译成英文"), Some("translator"));
        assert_eq!(topic("最近老是头疼，要不要去医院看看"), Some("doctor"));
        assert_eq!(topic("帮我排一个深蹲和硬拉的训练计划"), Some("trainer"));
        assert_eq!(topic("番茄炒蛋怎么做才嫩"), Some("chef"));
        assert_eq!(topic("我最近焦虑得睡不着，压力大"), Some("counselor"));
        assert_eq!(topic("合同条款写了违约金，能起诉吗"), Some("lawyer"));
        assert_eq!(topic("房东不退押金，租房合同怎么签"), Some("realtor"));
        assert_eq!(topic("明天去东京玩三天，帮我安排行程"), Some("travel"));
        assert_eq!(topic("写个 python 脚本处理 csv"), Some("swe"));
        assert_eq!(topic("ok"), None);
        assert_eq!(topic("继续"), None);
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
        topic: Option<String>,
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
            remap(&mut work, c.topic.as_deref());
            let w = finish(work, c.subagents, 360.0, c.topic.as_deref());
            let minutes: f64 = w.values().sum();
            let usd = Table::builtin().usd(&w);
            assert_eq!(main(&w).as_deref(), Some(c.main.as_str()), "{}", c.name);
            assert!((minutes - c.minutes).abs() < 0.01, "{}: {minutes:.2} min, want {}", c.name, c.minutes);
            assert!((usd - c.usd).abs() < 0.01, "{}: ${usd:.2}, want {}", c.name, c.usd);
        }
    }

    #[test]
    fn finishing_a_turn() {
        let w = finish(BTreeMap::new(), 0, 360.0, None);
        assert_eq!(w.get("research"), Some(&5.0), "talk-only turn");
        let w = finish(BTreeMap::new(), 1, 360.0, None);
        assert_eq!(w.get("research"), Some(&17.0), "subagents still count");
        let w = finish(BTreeMap::new(), 0, 360.0, Some("doctor"));
        assert_eq!(w.get("doctor"), Some(&15.0), "a talk about health is a doctor's consult");
        let mut w: BTreeMap<String, f64> = [("research".into(), 10.0), ("data".into(), 4.0)].into();
        remap(&mut w, Some("doctor"));
        assert_eq!((w.get("doctor"), w.get("data")), (Some(&10.0), Some(&4.0)), "a doctor does not absorb data steps");
        let w = finish([("video".into(), 30.0), ("swe".into(), 10.0)].into(), 2, 360.0, None);
        assert_eq!(w.get("video"), Some(&(30.0 + 5.0 + 24.0)));
        assert_eq!(w.get("swe"), Some(&10.0));
        let w = finish([("swe".into(), 600.0), ("qa".into(), 200.0)].into(), 0, 360.0, None);
        let total: f64 = w.values().sum();
        assert!((total - 360.0).abs() < 1e-9);
        assert!((w["swe"] / w["qa"] - 605.0 / 200.0).abs() < 1e-9, "scaled together");
        let t = Table::builtin();
        let usd = t.usd(&[("swe".to_string(), 60.0), ("video".to_string(), 30.0)].into());
        assert!((usd - (65.38 + 36.26 / 2.0)).abs() < 1e-9);
    }
}
