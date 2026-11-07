//! "Who you would have hired" (docs/DESIGN.md v3, v6). Each step an agent
//! takes is attributed to one occupation with the minutes a person in that
//! job would need for it, and a prompt's topic says who a talk-only turn
//! consulted; occupations, scenes, looks and topic keywords come from
//! assets/occupations.toml. Pure: callers pass in what they observed and
//! keep only the result.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

pub const BUILTIN_TOML: &str = include_str!("../../../assets/occupations.toml");

/// Minutes added to a turn's main occupation for reading the ask and
/// reporting back.
pub const TURN_BASE_MINUTES: f64 = 5.0;
/// Minutes per subagent, added to the turn's main occupation.
pub const SUBAGENT_MINUTES: f64 = 12.0;
/// A turn that did nothing observable is a short consult.
pub const CONSULT: (&str, f64) = ("research", 5.0);
/// Pace for prose, in words (a CJK character is one) an hour: the user's
/// pick (2026-10-29), at the fast end of what writers report.
pub const WORDS_PER_HOUR: f64 = 2000.0;

/// Minutes for `words` of prose, at least 3: a writer's, or a product
/// manager's when the file is a spec or a plan.
pub fn prose_minutes(words: u32) -> f64 {
    (words as f64 / WORDS_PER_HOUR * 60.0).max(3.0)
}
/// A prompt with no topic of its own ("继续", "好的") stays on the
/// session's last topic for this long.
pub const TOPIC_MEMORY_MINUTES: f64 = 60.0;

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
    /// Topic keywords: 2 points and 1 point, counted for the family.
    pub strong: Vec<String>,
    pub weak: Vec<String>,
    /// The topic family (see `Family`).
    pub family: String,
    /// Words that pick it over the family's default; the default has none.
    #[serde(default)]
    pub tell: Vec<String>,
}

/// A group of occupations a prompt is first placed in: the family whose
/// members' keywords score most, then the member whose tell words appear,
/// else `default`.
#[derive(Debug, Clone, Deserialize)]
pub struct Family {
    pub id: String,
    pub name: String,
    pub default: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Table {
    pub source: String,
    /// The source, said on cards and the dashboard.
    pub label: String,
    #[serde(default)]
    pub label_en: String,
    pub as_of: String,
    /// Merged occupations: old id → the representative it counts as.
    #[serde(default)]
    pub alias: BTreeMap<String, String>,
    pub family: Vec<Family>,
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

    /// The occupation's name in `lang`.
    pub fn name_in(&self, id: &str, lang: crate::i18n::Lang) -> &str {
        match (self.get(id), lang) {
            (Some(o), crate::i18n::Lang::En) => o.name_en.as_str(),
            (Some(o), _) => o.name.as_str(),
            (None, l) => l.t("其他", "Other"),
        }
    }

    /// Where the wages come from, in `lang`.
    pub fn label_in(&self, lang: crate::i18n::Lang) -> &str {
        if lang.en() && !self.label_en.is_empty() { &self.label_en } else { &self.label }
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

    /// The occupation an id counts as now (merged ones map to their representative).
    pub fn canon<'a>(&'a self, id: &'a str) -> &'a str {
        self.alias.get(id).map(String::as_str).unwrap_or(id)
    }

    pub fn family_of(&self, id: &str) -> Option<&Family> {
        let f = &self.get(id)?.family;
        self.family.iter().find(|x| &x.id == f)
    }
}

/// What a prompt is about, in two steps so that near occupations do not
/// split the evidence: the family whose members' keywords score most
/// (strong 2, weak 1; it takes a strong word or three weak ones; ties to
/// the earlier family), then within it the member with the most tell
/// words, else the family's default. ASCII keywords match whole words or
/// phrases, others anywhere. The text is read and dropped; only the id leaves.
pub fn topic(prompt: &str) -> Option<&'static str> {
    topic_candidates(prompt).first().copied()
}

/// The pick of every family tied for the top score, the usual winner
/// first: a session already on one of them stays there (ingest).
pub fn topic_candidates(prompt: &str) -> Vec<&'static str> {
    let p = prompt.to_lowercase();
    let padded: String = std::iter::once(' ')
        .chain(p.chars().map(|c| if c.is_ascii_alphanumeric() || matches!(c, '+' | '#' | '.' | '/' | '-') { c } else { ' ' }))
        .chain(std::iter::once(' '))
        .collect();
    let hit = |kw: &str| if kw.is_ascii() { padded.contains(&format!(" {} ", kw.trim())) } else { p.contains(kw) };
    let t = Table::builtin();
    // Per family: points, and whether any strong word hit.
    let mut by_family: BTreeMap<&str, (usize, bool)> = BTreeMap::new();
    for o in &t.occupation {
        // A keyword listed twice counts once.
        let strong = o.strong.iter().filter(|k| hit(k)).count();
        let score = 2 * strong + o.weak.iter().filter(|k| !o.strong.contains(k) && hit(k)).count();
        let e = by_family.entry(o.family.as_str()).or_default();
        e.0 += score;
        e.1 |= strong > 0;
    }
    let points = |f: &Family| by_family.get(f.id.as_str()).copied().unwrap_or((0, false));
    let qualifies = |f: &Family| matches!(points(f), (s, strong) if s >= 3 || (s >= 2 && strong));
    let Some(top) = t.family.iter().filter(|f| qualifies(f)).map(|f| points(f).0).max() else { return Vec::new() };
    let pick = |family: &'static Family| {
        let mut best: Option<(&'static str, usize)> = None;
        for o in t.occupation.iter().filter(|o| o.family == family.id) {
            let tells = o.tell.iter().filter(|k| hit(k)).count();
            if tells > 0 && best.map_or(true, |(_, n)| tells > n) {
                best = Some((o.id.as_str(), tells));
            }
        }
        best.map(|b| b.0).unwrap_or(family.default.as_str())
    };
    t.family.iter().filter(|f| points(f).0 == top && qualifies(f)).map(pick).collect()
}

/// Every id the attribution rules can return.
const REQUIRED: [&str; 12] = ["swe", "web", "qa", "ops", "data", "fin", "research", "writer", "pm", "designer", "video", "entry"];

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
        "md" | "mdx" | "txt" | "rst" | "docx" | "tex" | "adoc" => {
            let plan = ["prd", "roadmap", "需求", "规划", "排期"].iter().any(|k| low.rsplit('/').next().is_some_and(|n| n.contains(k)));
            (if plan { "pm" } else { "writer" }, prose_minutes(words))
        }
        "toml" | "yaml" | "yml" | "json" | "plist" | "ini" | "env" | "conf" | "lock" => ("ops", 5.0),
        "svg" | "png" | "jpg" | "jpeg" | "webp" | "gif" | "psd" | "ai" | "fig" => ("designer", 30.0),
        _ => {
            let m = code_minutes(lines);
            let test = ["/test/", "/tests/", "/spec/", "__tests__", "_test.", ".test.", ".spec."].iter().any(|t| low.contains(t))
                || low.rsplit('/').next().is_some_and(|n| n.starts_with("test_"));
            // Script in a UI folder is the front end's (2026-11-07).
            let ui = ["/components/", "/pages/", "/views/", "/ui/", "/public/", "/static/", "/frontend/", "/client/", "/www/"].iter().any(|d| low.contains(d));
            if test {
                ("qa", m)
            } else if matches!(e.as_str(), "html" | "htm" | "css" | "scss" | "sass" | "less" | "tsx" | "jsx" | "vue" | "svelte")
                || (ui && matches!(e.as_str(), "js" | "mjs" | "cjs" | "ts"))
            {
                ("web", m)
            } else if matches!(e.as_str(), "sh" | "bash" | "zsh") {
                // Shell scripts run machines: an ops engineer's (2026-11-07).
                ("ops", m)
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
/// work, data steps in one about markets the financial analyst's.
pub fn remap(work: &mut BTreeMap<String, f64>, topic: Option<&str>) {
    let Some(tp) = topic else { return };
    let absorbs_data = Table::builtin().get(tp).is_some_and(|o| o.absorbs_data);
    let mut moves = vec![("research", tp)];
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
/// the per-turn base shared out by each occupation's part of the steps
/// (until 2026-11-07 all on the main one, which made the catch-all software
/// engineer outgrow the rest). A turn with no steps is a consult with the
/// topic's occupation (a researcher when there is none).
pub fn finish(mut work: BTreeMap<String, f64>, subagents: u32, topic: Option<&str>) -> BTreeMap<String, f64> {
    work.retain(|_, m| *m > 0.0);
    if work.is_empty() {
        let who = topic.unwrap_or(CONSULT.0);
        work.insert(who.to_string(), Table::builtin().consult(who) + SUBAGENT_MINUTES * subagents as f64);
    } else {
        let total: f64 = work.values().sum();
        let extra = TURN_BASE_MINUTES + SUBAGENT_MINUTES * subagents as f64;
        for m in work.values_mut() {
            *m += extra * *m / total;
        }
    }
    work
}

/// Minutes for a file's code change: a file touched plus lines changed
/// (SPEC §5.3), concave so a long change is not paid by the line.
pub fn code_minutes(lines: u32) -> f64 {
    2.5 + 0.45 * (lines.max(1) as f64).powf(0.8)
}

/// How an edit is priced: code by its lines, prose by its words, or a flat
/// price for the file (a config, an image).
#[derive(Debug, Clone, Copy)]
pub enum EditPrice {
    Code(u32),
    Prose(u32),
    Flat(f64),
}

/// What a turn's steps have added up to so far, so the next step adds only
/// what is new (2026-11-07, user: 「记分太通货膨胀了」): a person does a
/// turn's work once, not as many times as the agent tried.
/// - A file is one piece of work per turn: its lines (or words) are summed
///   and priced once, so ten small edits cost what one edit of them all
///   does; a flat-priced file counts once.
/// - The k-th command or lookup of one occupation in a turn is worth 1/√k
///   of its price: the twentieth render of the evening is not another
///   fifteen minutes.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct TurnSteps {
    /// Per file: lines or words so far this turn.
    pub files: BTreeMap<String, u32>,
    /// Per occupation: commands and lookups so far this turn.
    pub runs: BTreeMap<String, u32>,
}

impl TurnSteps {
    /// Minutes an edit of `file` adds.
    pub fn edit(&mut self, file: &str, price: EditPrice) -> f64 {
        let before = self.files.get(file).copied();
        let n = |x: u32| before.unwrap_or(0) + x;
        match price {
            EditPrice::Code(lines) => {
                self.files.insert(file.to_string(), n(lines));
                code_minutes(n(lines)) - before.map(code_minutes).unwrap_or(0.0)
            }
            EditPrice::Prose(words) => {
                self.files.insert(file.to_string(), n(words));
                prose_minutes(n(words)) - before.map(prose_minutes).unwrap_or(0.0)
            }
            EditPrice::Flat(m) => {
                self.files.insert(file.to_string(), 0);
                if before.is_some() { 0.0 } else { m }
            }
        }
    }

    /// Minutes a command or lookup worth `minutes` adds for `occupation`.
    pub fn run(&mut self, occupation: &str, minutes: f64) -> f64 {
        let k = self.runs.entry(occupation.to_string()).or_default();
        *k += 1;
        minutes / (*k as f64).sqrt()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Recognised by their steps only, never as a prompt's topic.
    const STEP_ONLY: [&str; 4] = ["web", "qa", "ops", "entry"];

    #[test]
    fn table_is_complete_and_sourced() {
        let t = Table::builtin();
        assert_eq!(t.occupation.len(), 20, "one representative per field (the sciences one scientist), the programmer's three step roles, writer and product manager");
        assert!(t.occupation.iter().all(|o| !o.scene.is_empty() && o.consult > 0.0 && (!o.strong.is_empty() || STEP_ONLY.contains(&o.id.as_str()))));
        assert_eq!(t.scene("doctor"), "clinic");
        // Families: every occupation in one, every default a member of its
        // own family with no tells, every other member with some.
        assert!(t.family.len() >= 13);
        for f in &t.family {
            let d = t.get(&f.default).unwrap_or_else(|| panic!("{}: default {}", f.id, f.default));
            assert_eq!(d.family, f.id, "{}", f.id);
            assert!(d.tell.is_empty(), "{}: the default has no tells", f.id);
        }
        for o in &t.occupation {
            let f = t.family_of(&o.id).unwrap_or_else(|| panic!("{}: family {}", o.id, o.family));
            assert!(f.default == o.id || !o.tell.is_empty() || STEP_ONLY.contains(&o.id.as_str()), "{}: a specialty needs tells", o.id);
        }
        assert_eq!(t.family_of("trainer").unwrap().default, "doctor");
        for (from, to) in &t.alias {
            assert!(t.get(from).is_none() && t.get(to).is_some(), "alias {from} → {to}");
        }
        assert_eq!((t.canon("vet"), t.canon("hr"), t.canon("doctor")), ("doctor", "research", "doctor"));
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
        assert_eq!(for_edit("notes.md", 40, 1000), ("writer", 30.0));
        assert_eq!(for_edit("notes.md", 1, 10), ("writer", 3.0), "a floor for tiny edits");
        assert_eq!(for_edit("docs/PRD-v2.md", 40, 1000), ("pm", 30.0), "a spec is the product manager's");
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
        let mut w: BTreeMap<String, f64> = [("research".into(), 10.0), ("data".into(), 4.0), ("swe".into(), 30.0)].into();
        remap(&mut w, Some("fin"));
        assert_eq!((w.get("fin"), w.get("swe")), (Some(&14.0), Some(&30.0)), "markets absorb research and data");
        assert!(!w.contains_key("research") && !w.contains_key("data"));
        let mut w: BTreeMap<String, f64> = [("research".into(), 5.0)].into();
        remap(&mut w, None);
        assert_eq!(w.get("research"), Some(&5.0), "no topic, nothing moves");
        assert_eq!(topic("帮我看看英伟达的财报"), Some("fin"));
        assert_eq!(topic("Compare NVDA earnings"), Some("fin"));
        assert_eq!(topic("restock the fridge list"), None, "whole words only");
        assert_eq!(topic("把这段翻译成英文"), Some("writer"));
        assert_eq!(topic("帮我写一份 PRD，排一下下个版本的需求优先级"), Some("pm"));
        assert_eq!(topic("最近老是头疼，要不要去医院看看"), Some("doctor"));
        assert_eq!(topic("帮我排一个深蹲和硬拉的训练计划"), Some("trainer"));
        assert_eq!(topic("番茄炒蛋怎么做才嫩"), Some("chef"));
        assert_eq!(topic("我最近焦虑得睡不着，压力大"), Some("counselor"));
        assert_eq!(topic("合同条款写了违约金，能起诉吗"), Some("lawyer"));
        assert!(topic("房东不退押金，租房合同怎么签").map_or(true, |x| x == "research"));
        assert!(topic("明天去东京玩三天，帮我安排行程").map_or(true, |x| x == "research"));
        assert_eq!(topic("写个 python 脚本处理 csv"), Some("swe"));
        assert_eq!(topic("ok"), None);
        assert_eq!(topic("继续"), None);
    }

    /// Talk about the product, the repo or the UI is nobody's specialty:
    /// a naming question once came out as a vet ("叫什么名字" hit "叫").
    #[test]
    fn tied_families_are_all_offered() {
        // 创伤 (health) and 视频 (video): one strong word each; 版权 is only weak.
        let c = topic_candidates("我想要用真实的照片，不需要管版权问题，这个视频的题目就叫：爱，拥抱与创伤");
        assert_eq!(c, vec!["doctor", "video"]);
        assert_eq!(topic("我想要用真实的照片，不需要管版权问题，这个视频的题目就叫：爱，拥抱与创伤"), Some("doctor"));
        assert_eq!(topic_candidates("帮我把这段视频剪辑一下，加字幕"), vec!["video"]);
        assert!(topic_candidates("继续").is_empty());
    }

    #[test]
    fn everyday_prompts_have_no_topic() {
        for p in [
            "然后日报月报年报的导出你也给我优化下", "你可以帮我写一个 total war 二战题材的版本吗，需要我提供给你什么",
            "中文英文各做一个版本，请你先做个 mvp 看看", "是不是可以直接把一个手机改成录音设备，一直连着充电器",
            "请你把 vpn 协议的隐秘性做好一些", "我想让你设计得更有意思一些，比如拟人化，提供更多的情绪价值",
            "你觉得我这个叫什么名字好，我这个产品",
            "我觉得可以再想想用什么名字",
            "请问这个上传到github了吗",
            "建私有仓库并推送",
            "开始做导出优化，目前只能导出日报",
            "我们可以做个界面，变成一个办公室，然后谁在干活谁就在这个办公室里面在干活",
            "睡着了眼睛应该闭起来的",
            "今天的产出的数据没有了啊，你查查这个",
            "请你帮我做个测试，这个产品",
            "这个杠杆可以是经济收益的杠杆，不是时间的杠杆",
            "一间屋 + 舞台 + 茶水间轮换",
        ] {
            // Research is what a talk-only turn is paid as anyway.
            assert!(topic(p).map_or(true, |t| t == "research"), "{p} → {:?}", topic(p));
        }
        // Developer talk may be a developer's topic, never a tradesman's.
        let tech = ["swe", "data", "research"];
        for p in [
            "服务炸了，看一下日志", "npm 包升级后编译不过", "语法树解析有问题", "装一下依赖然后跑测试", "树形结构怎么存",
            "解释一下这段代码", "这个函数是什么意思", "帮我设计一下数据库结构", "设计方案出一下", "语法错误在哪", "把这个按钮改成绿色，然后加个动画",
            "学习一下这个库怎么用", "这个接口的原理讲一下", "经济杠杆怎么算", "弹性伸缩怎么配",
        ] {
            assert!(topic(p).map_or(true, |t| tech.contains(&t)), "{p} → {:?}", topic(p));
        }
    }

    /// Chinese keywords match anywhere in the prompt, so a single character
    /// fires on every word containing it; only a few specific ones are allowed.
    #[test]
    fn no_single_character_keywords() {
        let allowed = ["猫", "狗", "癌", "肾", "苯", "酶", "熵", "泵", "锯", "臀", "娃", "诗", "钙", "炖", "腌"];
        for o in &Table::builtin().occupation {
            for k in o.strong.iter().chain(&o.weak).chain(&o.tell) {
                assert!(k.is_ascii() || k.chars().count() > 1 || allowed.contains(&k.as_str()), "{}: {k:?}", o.id);
            }
        }
    }

    /// Labelled prompts, a few per field: the representative, or one of the
    /// three specialties (data, trainer, counselor) when a tell word names it.
    #[test]
    fn families_then_specialties() {
        let cases = [
            // health
            ("最近老是头疼，要不要去医院看看", "doctor"), ("体检报告说转氨酶偏高，严重吗", "doctor"), ("发烧 38 度，要不要吃退烧药", "doctor"),
            ("我家猫一直叫，是不是发情了", "doctor"), ("狗狗拉稀两天了怎么办", "doctor"),
            ("帮我排一个深蹲和硬拉的训练计划", "trainer"), ("想增肌，一周练几次合适", "trainer"),
            ("减脂期一天吃多少卡路里", "doctor"), ("帮我做个一周的饮食计划，控制热量", "doctor"),
            ("布洛芬和感冒药能不能一起吃", "doctor"), ("这个药的剂量成人一天吃几次", "doctor"),
            ("我最近焦虑得睡不着，压力大", "counselor"), ("分手之后情绪很差，怎么调整", "counselor"),
            // money
            ("帮我看看英伟达的财报", "fin"), ("Compare NVDA earnings", "fin"), ("炒股软件怎么做", "fin"), ("这只股票的估值贵不贵", "fin"),
            ("英伟达下个季度的指引怎么看", "fin"),
            ("个人所得税怎么报税，有哪些专项扣除", "fin"), ("公司这笔费用怎么做账，发票怎么开", "fin"),
            ("美联储加息对房贷利率有什么影响", "fin"), ("最近 CPI 数据说明通胀怎么样", "fin"),
            // writing
            ("帮我写一篇公众号文章，讲远程办公", "writer"), ("这段文案润色一下，更有感染力", "writer"), ("帮我写一封辞职信", "writer"),
            ("把这段翻译成英文", "writer"), ("这封邮件帮我翻成日语", "writer"),
            // design and images
            ("帮我设计一张海报，主题是周年庆", "designer"), ("logo 配色用什么好", "designer"),
            ("人像摄影光圈开多大，镜头怎么选", "designer"), ("客厅装修选什么地板，吊顶要不要做", "designer"),
            ("这个注册流程的交互太绕了，用户体验怎么改", "designer"),
            ("帮我把这段视频剪辑一下，加字幕", "video"), ("视频转场怎么做更自然", "video"),
            ("视频帧率用 30 还是 60，导出 mp4 会不会太大", "video"),
            // An app's frame rate and its skins are not a video job.
            ("桌宠的帧率降一点，干活时卡顿，cpu 占用太高", "swe"), ("团子的自定义皮肤怎么设计比较好，颜色和贴图都能换", "designer"),
            // Generic words (提供给, 查查, 协议, 情绪, 宠物, mvp) decide nothing alone.
            ("帮我查查海力士的财报", "fin"), ("最近情绪低落，什么都不想做", "counselor"), ("签协议前要注意哪些条款", "lawyer"),
            ("这首歌的和弦进行怎么编", "musician"), ("吉他怎么扫弦，节奏型怎么练", "musician"),
            ("面试穿什么合适，衬衫配什么裤子", "research"), ("圆脸适合什么发型，妆容怎么画", "research"),
            // education and science
            ("帮我制定一个雅思备考计划", "research"), ("孩子的数学作业，这道应用题怎么讲", "research"),
            ("这个微分方程怎么解，求导过程写一下", "scientist"), ("证明一下这个矩阵可逆", "scientist"),
            ("量子纠缠到底是什么，通俗讲讲", "scientist"), ("为什么相对论说时间会变慢", "scientist"),
            ("这个化学反应的方程式怎么配平", "scientist"), ("细胞分裂时 DNA 是怎么复制的", "scientist"),
            // home and engineering
            ("家里突然跳闸了，是不是插座短路", "research"), ("灯不亮了，电线怎么接", "research"),
            ("水管漏了，水压也小", "research"), ("马桶堵了怎么疏通", "research"),
            ("想自己做个书架，木板怎么选，用什么钉子", "research"), ("多肉黄叶烂根了，浇水是不是太多", "research"),
            ("自建房的户型图和承重墙怎么设计", "architect"), ("齿轮传动的扭矩怎么算", "scientist"), ("stm32 的 pcb 电路图怎么画", "scientist"),
            // life
            ("番茄炒蛋怎么做才嫩", "chef"), ("红烧肉的做法，火候怎么掌握", "chef"),
            ("宝宝八个月了，辅食怎么加", "research"), ("孩子上幼儿园分离焦虑哭闹怎么办", "research"),
            ("明天去东京玩三天，帮我安排行程", "research"), ("去日本的签证和机票怎么订便宜", "research"), ("周末想去杭州，两天怎么安排", "research"),
            ("房东不退押金，租房合同怎么签", "research"), ("首付三成，房贷选哪种划算", "research"),
            ("车子启动有异响，刹车也软，去 4s店 要多少钱", "research"),
            // law and business
            ("合同条款写了违约金，能起诉吗", "lawyer"), ("劳动仲裁要准备什么材料", "lawyer"),
            ("团队绩效怎么定目标，okr 怎么拆", "research"), ("帮我写需求文档，这个功能的用户故事", "pm"),
            ("招聘后端工程师的 jd 怎么写，面试问什么", "research"), ("客户嫌报价高，怎么谈判成交", "research"),
            // tech
            ("写个 python 脚本处理 csv", "swe"), ("这个页面的 css 布局怎么居中", "swe"), ("给这个函数写单元测试", "swe"),
            ("docker 部署到服务器上，nginx 怎么配", "swe"), ("用 pandas 做个数据分析，输出表格", "data"), ("这个接口有 sql 注入漏洞吗", "swe"),
        ];
        // Web, test and ops work is told by its steps; a prompt never names them.
        for p in ["这个页面的 css 布局怎么居中", "给这个函数写单元测试", "docker 部署到服务器上，nginx 怎么配"] {
            assert_eq!(topic(p), Some("swe"), "{p}");
        }
        for o in STEP_ONLY {
            assert!(cases.iter().all(|(_, w)| *w != o));
        }
        for (p, want) in cases {
            // The researcher is also what no topic at all comes to.
            if want == "research" {
                assert!(topic(p).map_or(true, |x| x == "research"), "{p} → {:?}", topic(p));
            } else {
                assert_eq!(topic(p), Some(want), "{p}");
            }
        }
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
            // Priced as ingest does: a file once a turn, repeats less.
            let mut work = BTreeMap::new();
            let mut steps = TurnSteps::default();
            for s in &c.steps {
                let (occ, m) = match (&s.edit, &s.cmd, &s.tool) {
                    (Some(path), _, _) => {
                        let (occ, m) = for_edit(path, s.lines, s.words);
                        let price = match occ {
                            "writer" | "pm" => EditPrice::Prose(s.words),
                            "swe" | "web" | "qa" => EditPrice::Code(s.lines),
                            "ops" if path.ends_with(".sh") => EditPrice::Code(s.lines),
                            _ => EditPrice::Flat(m),
                        };
                        (occ, steps.edit(path, price))
                    }
                    (_, Some(cmd), _) => {
                        let (occ, m) = for_command(cmd).unwrap_or_else(|| panic!("{}: {cmd} counts", c.name));
                        (occ, steps.run(occ, m))
                    }
                    (_, _, Some(tool)) => {
                        let (occ, m) = for_tool(tool).unwrap_or_else(|| panic!("{}: {tool} counts", c.name));
                        (occ, steps.run(occ, m))
                    }
                    _ => panic!("{}: empty step", c.name),
                };
                *work.entry(occ.to_string()).or_insert(0.0) += m;
            }
            remap(&mut work, c.topic.as_deref());
            let w = finish(work, c.subagents, c.topic.as_deref());
            let minutes: f64 = w.values().sum();
            let usd = Table::builtin().usd(&w);
            assert_eq!(main(&w).as_deref(), Some(c.main.as_str()), "{}", c.name);
            assert!((minutes - c.minutes).abs() < 0.01, "{}: {minutes:.2} min, want {}", c.name, c.minutes);
            assert!((usd - c.usd).abs() < 0.01, "{}: ${usd:.2}, want {}", c.name, c.usd);
        }
    }

    #[test]
    fn a_turn_prices_a_file_once_and_repeats_less() {
        let mut t = TurnSteps::default();
        // Ten 10-line edits of one file cost what one 100-line edit does.
        let ten: f64 = (0..10).map(|_| t.edit("a", EditPrice::Code(10))).sum();
        assert!((ten - code_minutes(100)).abs() < 1e-9, "{ten}");
        assert!((t.edit("b", EditPrice::Code(10)) - code_minutes(10)).abs() < 1e-9, "another file starts afresh");
        assert_eq!((t.edit("c", EditPrice::Flat(5.0)), t.edit("c", EditPrice::Flat(5.0))), (5.0, 0.0), "a config once");
        assert!((t.edit("d", EditPrice::Prose(500)) + t.edit("d", EditPrice::Prose(500)) - prose_minutes(1000)).abs() < 1e-9);
        // The k-th run of one occupation is worth 1/√k.
        let runs: Vec<f64> = (0..4).map(|_| t.run("video", 16.0)).collect();
        assert_eq!(runs, vec![16.0, 16.0 / 2f64.sqrt(), 16.0 / 3f64.sqrt(), 8.0]);
        assert_eq!(t.run("qa", 10.0), 10.0, "each occupation counts its own");
    }

    #[test]
    fn finishing_a_turn() {
        let w = finish(BTreeMap::new(), 0, None);
        assert_eq!(w.get("research"), Some(&5.0), "talk-only turn");
        let w = finish(BTreeMap::new(), 1, None);
        assert_eq!(w.get("research"), Some(&17.0), "subagents still count");
        let w = finish(BTreeMap::new(), 0, Some("doctor"));
        assert_eq!(w.get("doctor"), Some(&15.0), "a talk about health is a doctor's consult");
        let mut w: BTreeMap<String, f64> = [("research".into(), 10.0), ("data".into(), 4.0)].into();
        remap(&mut w, Some("doctor"));
        assert_eq!((w.get("doctor"), w.get("data")), (Some(&10.0), Some(&4.0)), "a doctor does not absorb data steps");
        // The base and the subagents are shared out by each one's part.
        let w = finish([("video".into(), 30.0), ("swe".into(), 10.0)].into(), 2, None);
        assert_eq!(w.get("video"), Some(&(30.0 + 29.0 * 0.75)));
        assert_eq!(w.get("swe"), Some(&(10.0 + 29.0 * 0.25)));
        let w = finish([("swe".into(), 600.0), ("qa".into(), 200.0)].into(), 0, None);
        assert_eq!((w["swe"], w["qa"]), (603.75, 201.25), "no cap: a long turn counts in full");
        let t = Table::builtin();
        let usd = t.usd(&[("swe".to_string(), 60.0), ("video".to_string(), 30.0)].into());
        assert!((usd - (65.38 + 36.26 / 2.0)).abs() < 1e-9);
    }
}
