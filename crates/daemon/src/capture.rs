//! Turns a Claude Code or Codex hook's stdin JSON into spool events (SPEC
//! 4.1). Field names follow https://code.claude.com/docs/en/hooks (checked
//! 2026-10-28) and https://learn.chatgpt.com/docs/hooks (checked
//! 2026-10-29). Prompt text, commands, code and paths are read here and
//! reduced to derived values; none of them leaves this module.

use std::fs;
use std::path::Path;
use std::process::Command;

use serde_json::{json, Value};
use shadowcorp_core::{classify, occupation};
use shadowcorp_core::event::{Event, Kind, Payload, Source};

use crate::paths::{short_hash, write_private, Paths};

pub struct CaptureEnv<'a> {
    pub paths: &'a Paths,
    pub now_ms: i64,
    /// Mixed into event ids; empty for deterministic replays.
    pub nonce: String,
    /// Look up a file's last commit time for the archaeologist badge.
    pub git_lookup: bool,
}

fn s<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

pub fn line_count(text: &str) -> u32 {
    text.lines().count() as u32
}

/// Added/removed lines from a `structuredPatch` (hunks of "+", "-", " " lines).
pub fn patch_counts(patch: &Value) -> Option<(u32, u32)> {
    let hunks = patch.as_array()?;
    let (mut add, mut del) = (0, 0);
    for h in hunks {
        for l in h.get("lines")?.as_array()? {
            match l.as_str().and_then(|l| l.chars().next()) {
                Some('+') => add += 1,
                Some('-') => del += 1,
                _ => {}
            }
        }
    }
    Some((add, del))
}

/// Line-level change between two strings: common leading and trailing lines
/// are unchanged, the rest counts as removed/added.
pub fn diff_counts(old: &str, new: &str) -> (u32, u32) {
    let a: Vec<&str> = old.lines().collect();
    let b: Vec<&str> = new.lines().collect();
    let mut pre = 0;
    while pre < a.len() && pre < b.len() && a[pre] == b[pre] {
        pre += 1;
    }
    let mut suf = 0;
    while suf < a.len() - pre && suf < b.len() - pre && a[a.len() - 1 - suf] == b[b.len() - 1 - suf] {
        suf += 1;
    }
    ((b.len() - pre - suf) as u32, (a.len() - pre - suf) as u32)
}

/// Lines added/removed by an Edit, MultiEdit or Write tool call.
pub fn edit_counts(tool: &str, input: &Value, response: Option<&Value>) -> (u32, u32) {
    if let Some(c) = response.and_then(|r| r.get("structuredPatch")).and_then(patch_counts) {
        if c != (0, 0) || tool != "Write" {
            return c;
        }
    }
    match tool {
        "Edit" => diff_counts(s(input, "old_string").unwrap_or(""), s(input, "new_string").unwrap_or("")),
        "MultiEdit" => input
            .get("edits")
            .and_then(Value::as_array)
            .map(|edits| {
                edits.iter().fold((0, 0), |(a, d), e| {
                    let (x, y) = diff_counts(s(e, "old_string").unwrap_or(""), s(e, "new_string").unwrap_or(""));
                    (a + x, d + y)
                })
            })
            .unwrap_or((0, 0)),
        _ => (line_count(s(input, "content").unwrap_or("")), 0),
    }
}

/// The text an edit added, for counting words: the patch's "+" lines when
/// Claude Code reports them, else the new text itself.
pub fn added_text(tool: &str, input: &Value, response: Option<&Value>) -> String {
    if let Some(hunks) = response.and_then(|r| r.get("structuredPatch")).and_then(Value::as_array).filter(|h| !h.is_empty()) {
        return hunks
            .iter()
            .filter_map(|h| h.get("lines").and_then(Value::as_array))
            .flatten()
            .filter_map(Value::as_str)
            .filter_map(|l| l.strip_prefix('+'))
            .collect::<Vec<_>>()
            .join("\n");
    }
    match tool {
        "Write" => s(input, "content").unwrap_or("").to_string(),
        "MultiEdit" => input
            .get("edits")
            .and_then(Value::as_array)
            .map(|e| e.iter().filter_map(|x| s(x, "new_string")).collect::<Vec<_>>().join("\n"))
            .unwrap_or_default(),
        _ => s(input, "new_string").unwrap_or("").to_string(),
    }
}

/// Fills the per-file derived fields for one edited file.
pub fn file_signals(p: &mut Payload, cwd: &str, path: &str) {
    let rel = path
        .strip_prefix(cwd)
        .map(|r| r.trim_start_matches('/'))
        .filter(|r| !r.is_empty() && path != cwd)
        .unwrap_or(path);
    p.files_touched = Some(1);
    p.file_ids = vec![short_hash(path)];
    p.dir_ids = vec![short_hash(&format!("{cwd}\0{}", classify::top_dir(rel)))];
    p.roles = classify::role_for_path(rel).into_iter().collect();
    p.languages = classify::language_for_path(rel).map(str::to_string).into_iter().collect();
    if classify::is_migration_path(rel) {
        p.migration_path = Some(true);
    }
}

/// Days since a file was last committed, if it sits in a git repository.
fn file_age_days(path: &str, now_ms: i64) -> Option<u32> {
    let p = Path::new(path);
    let dir = p.parent()?;
    if !dir.ancestors().take(40).any(|a| a.join(".git").exists()) {
        return None;
    }
    let out = Command::new("git").arg("-C").arg(dir).args(["log", "-1", "--format=%ct", "--"]).arg(p).output().ok()?;
    let secs: i64 = String::from_utf8_lossy(&out.stdout).trim().parse().ok()?;
    Some(((now_ms / 1000 - secs).max(0) / 86_400) as u32)
}

/// Tracks consecutive identical prompts per session with a salted
/// fingerprint, so only a count is ever recorded.
fn prompt_repeat(paths: &Paths, session: &str, prompt: &str) -> u32 {
    let safe: String = session.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').take(64).collect();
    if safe.is_empty() {
        return 1;
    }
    let file = paths.state.join(format!("{safe}.prompt"));
    let fp = short_hash(&format!("{}\0{}", paths.salt(), prompt.trim()));
    let n = match fs::read_to_string(&file) {
        Ok(t) => match t.split_once(' ') {
            Some((old, n)) if old == fp => n.trim().parse::<u32>().unwrap_or(1) + 1,
            _ => 1,
        },
        Err(_) => 1,
    };
    let _ = paths.ensure().and_then(|_| write_private(&file, format!("{fp} {n}").as_bytes()));
    n
}

/// A shell command as text: Codex sometimes gives argv (["zsh", "-lc", "…"]).
pub fn command_text(v: &Value) -> String {
    match v {
        Value::Array(a) => {
            let parts: Vec<&str> = a.iter().filter_map(Value::as_str).collect();
            match parts.as_slice() {
                [_, flag, cmd] if flag.starts_with('-') && flag.ends_with('c') => cmd.to_string(),
                _ => parts.join(" "),
            }
        }
        v => v.as_str().unwrap_or("").to_string(),
    }
}

/// The exit code a shell tool's response reports, if it says.
fn exit_code(resp: Option<&Value>) -> Option<i64> {
    let r = resp?;
    if let Some(n) = r.get("exit_code").or_else(|| r.get("exitCode")).and_then(Value::as_i64) {
        return Some(n);
    }
    let text = r.as_str().or_else(|| r.get("output").and_then(Value::as_str))?;
    ["exited with code ", "Exit code: ", "exit_code: "].iter().find_map(|pat| {
        let rest = &text[text.find(pat)? + pat.len()..];
        rest.chars().take_while(|c| c.is_ascii_digit() || *c == '-').collect::<String>().parse().ok()
    })
}

/// One file of a Codex patch: its path, whether it is new, its "+"/"-" lines.
pub struct FilePatch {
    pub path: String,
    pub new: bool,
    pub lines: Vec<String>,
}

/// Splits a Codex apply_patch ("*** Begin Patch … *** End Patch") by file.
pub fn parse_patch(patch: &str) -> Vec<FilePatch> {
    let mut out: Vec<FilePatch> = Vec::new();
    for line in patch.lines() {
        let header = |p: &str| line.strip_prefix(p).map(|x| x.trim().to_string());
        if let Some(path) = header("*** Add File: ") {
            out.push(FilePatch { path, new: true, lines: Vec::new() });
        } else if let Some(path) = header("*** Update File: ").or_else(|| header("*** Delete File: ")) {
            out.push(FilePatch { path, new: false, lines: Vec::new() });
        } else if !line.starts_with("***") && (line.starts_with('+') || line.starts_with('-')) {
            if let Some(f) = out.last_mut() {
                f.lines.push(line.to_string());
            }
        }
    }
    out
}

/// A Claude Code-shaped PostToolUse for one edited file, so edits made by
/// Codex go through the same rules.
pub fn edit_hook(cwd: &str, path: &str, new: bool, lines: Vec<String>) -> Value {
    let abs = if path.starts_with('/') || cwd.is_empty() { path.to_string() } else { format!("{}/{path}", cwd.trim_end_matches('/')) };
    let content: Vec<&str> = lines.iter().filter_map(|l| l.strip_prefix('+')).collect();
    json!({
        "hook_event_name": "PostToolUse", "cwd": cwd, "tool_name": if new { "Write" } else { "Edit" },
        "tool_input": { "file_path": abs, "content": content.join("\n") },
        "tool_response": { "structuredPatch": [{ "lines": lines }] },
    })
}

/// Maps one Codex hook invocation to events (a patch gives one per file).
/// Codex uses Claude Code's field names plus `turn_id`; shell and unified
/// exec arrive as `Bash`, edits as `apply_patch` with the patch in
/// `tool_input.command`, and a failed command has no event of its own.
pub fn from_codex_hook(input: &Value, raw: &[u8], env: &CaptureEnv) -> Vec<Event> {
    let name = s(input, "hook_event_name").unwrap_or("");
    let tool = s(input, "tool_name").unwrap_or("");
    let mut hooks: Vec<Value> = Vec::new();
    match (name, tool) {
        ("PostToolUse", "apply_patch") => {
            let patch = input.get("tool_input").and_then(|t| t.get("command")).map(command_text).unwrap_or_default();
            for f in parse_patch(&patch) {
                hooks.push(edit_hook(s(input, "cwd").unwrap_or(""), &f.path, f.new, f.lines));
            }
        }
        ("PostToolUse", "Bash") => {
            let mut h = input.clone();
            h["tool_input"] = json!({ "command": input.get("tool_input").and_then(|t| t.get("command")).map(command_text).unwrap_or_default() });
            if exit_code(input.get("tool_response")).is_some_and(|c| c != 0) {
                h["hook_event_name"] = json!("PostToolUseFailure");
            }
            hooks.push(h);
        }
        ("SubagentStart", _) => hooks.push(json!({ "hook_event_name": "PostToolUse", "tool_name": "Agent" })),
        _ => hooks.push(input.clone()),
    }
    hooks
        .into_iter()
        .enumerate()
        .filter_map(|(i, mut h)| {
            h["session_id"] = input.get("session_id").cloned().unwrap_or(Value::Null);
            let env = CaptureEnv { paths: env.paths, now_ms: env.now_ms, nonce: format!("{}#{i}", env.nonce), git_lookup: env.git_lookup };
            let mut ev = from_claude_hook(&h, raw, &env)?;
            ev.source = Source::Codex;
            ev.turn_id = s(input, "turn_id").map(str::to_string);
            Some(ev)
        })
        .collect()
}

/// Maps one hook invocation to zero or one events.
pub fn from_claude_hook(input: &Value, raw: &[u8], env: &CaptureEnv) -> Option<Event> {
    let name = s(input, "hook_event_name")?;
    let cwd = s(input, "cwd").unwrap_or("");
    let mut p = Payload::default();
    let kind = match name {
        "SessionStart" => {
            p.session_source = s(input, "source").map(str::to_string);
            Kind::SessionStart
        }
        "UserPromptSubmit" => {
            let prompt = s(input, "prompt").unwrap_or("");
            p.task_class = Some(classify::classify_prompt(prompt));
            p.is_correction = Some(classify::is_correction(prompt));
            p.finance = occupation::is_finance_prompt(prompt).then_some(true);
            p.translate = occupation::is_translate_prompt(prompt).then_some(true);
            if let Some(sid) = s(input, "session_id") {
                p.prompt_repeat = Some(prompt_repeat(env.paths, sid, prompt));
            }
            Kind::Prompt
        }
        "PostToolUse" | "PostToolUseFailure" => {
            let ok = name == "PostToolUse";
            let tool = s(input, "tool_name")?;
            let ti = input.get("tool_input").cloned().unwrap_or(Value::Null);
            match tool {
                "Edit" | "MultiEdit" | "Write" => {
                    if !ok {
                        return None;
                    }
                    let path = s(&ti, "file_path")?;
                    let (add, del) = edit_counts(tool, &ti, input.get("tool_response"));
                    let words = occupation::word_count(&added_text(tool, &ti, input.get("tool_response")));
                    let (occ, minutes) = occupation::for_edit(path, add + del, words);
                    p.tool = Some(if tool == "Write" { "write" } else { "edit" }.to_string());
                    p.lines_added = Some(add);
                    p.lines_removed = Some(del);
                    p.words = (words > 0).then_some(words);
                    p.occupation = Some(occ.into());
                    p.minutes = Some(minutes);
                    file_signals(&mut p, cwd, path);
                    if env.git_lookup && tool != "Write" {
                        p.file_ages_days_max = file_age_days(path, env.now_ms);
                    }
                }
                "Bash" => {
                    let cmd = s(&ti, "command").unwrap_or("");
                    let info = classify::analyze_command(cmd);
                    // A failed run still took work (debugging); a failed commit did not happen.
                    let work = occupation::for_command(cmd).filter(|_| ok || info.test || info.git.is_none());
                    p.tool = Some("bash".into());
                    if let Some((occ, minutes)) = work {
                        p.occupation = Some(occ.into());
                        p.minutes = Some(minutes);
                    }
                    let interrupted = input.get("is_interrupt").and_then(Value::as_bool).unwrap_or(false);
                    if info.test && !interrupted {
                        p.test_cmd = Some(true);
                        p.test_passed = Some(ok);
                    }
                    if ok {
                        p.git_action = info.git;
                    }
                    if p.test_cmd.is_none() && p.git_action.is_none() && p.occupation.is_none() {
                        return None;
                    }
                }
                "Agent" | "Task" => {
                    p.tool = Some("agent".into());
                    p.subagents = Some(1);
                }
                other => {
                    // Research and connectors: web search, reading pages, data.
                    let (occ, minutes) = occupation::for_tool(other)?;
                    p.tool = Some(if other.starts_with("mcp__") { "mcp" } else { "web" }.into());
                    p.occupation = Some(occ.into());
                    p.minutes = Some(minutes);
                    if other.starts_with("mcp__") && occupation::is_finance_server(other.split("__").nth(1).unwrap_or("")) {
                        p.finance = Some(true);
                    }
                }
            }
            Kind::Tool
        }
        "SubagentStop" => Kind::SubagentStop,
        "Stop" => {
            p.stop_hook_active = input.get("stop_hook_active").and_then(Value::as_bool);
            Kind::TurnEnd
        }
        "Notification" => {
            p.notification_type = s(input, "notification_type").map(str::to_string);
            Kind::Notification
        }
        "PreCompact" => Kind::PreCompact,
        "SessionEnd" => {
            p.reason = s(input, "reason").map(str::to_string);
            Kind::SessionEnd
        }
        _ => return None,
    };
    let mut seed = env.nonce.clone().into_bytes();
    seed.extend_from_slice(raw);
    let id = format!("evt_{:013x}{}", env.now_ms, short_hash(&String::from_utf8_lossy(&seed)));
    let mut ev = Event::new(id, env.now_ms, Source::ClaudeCode, kind);
    ev.session_id = s(input, "session_id").map(str::to_string);
    ev.turn_id = s(input, "prompt_id").map(str::to_string);
    ev.cwd_hash = (!cwd.is_empty()).then(|| short_hash(cwd));
    ev.payload = p;
    Some(ev)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn env(paths: &Paths) -> CaptureEnv<'_> {
        CaptureEnv { paths, now_ms: 1_793_000_000_000, nonce: String::new(), git_lookup: false }
    }

    fn tmp() -> Paths {
        static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let d = std::env::temp_dir().join(format!("sc-capture-{}-{n}", std::process::id()));
        let p = Paths::at(d);
        p.ensure().unwrap();
        p
    }

    #[test]
    fn diffs() {
        assert_eq!(diff_counts("a\nb\nc", "a\nB\nc"), (1, 1));
        assert_eq!(diff_counts("", "x\ny"), (2, 0));
        assert_eq!(diff_counts("x\ny", ""), (0, 2));
        assert_eq!(diff_counts("same", "same"), (0, 0));
        let patch = json!([{ "lines": [" a", "-b", "+B", "+C", " c"] }]);
        assert_eq!(patch_counts(&patch), Some((2, 1)));
    }

    #[test]
    fn prompt_text_never_reaches_the_event() {
        let paths = tmp();
        let input = json!({
            "hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt_id": "p1",
            "cwd": "/Users/me/secret-repo", "prompt": "Fix the crash in /Users/me/secret-repo/src/main.rs"
        });
        let raw = serde_json::to_vec(&input).unwrap();
        let ev = from_claude_hook(&input, &raw, &env(&paths)).unwrap();
        let line = serde_json::to_string(&ev).unwrap();
        assert!(!line.contains("secret") && !line.contains("crash") && !line.contains("/Users"));
        assert_eq!(ev.payload.task_class.unwrap().as_str(), "bugfix");
        assert_eq!(ev.turn_id.as_deref(), Some("p1"));
    }

    #[test]
    fn same_prompt_counts_up() {
        let paths = tmp();
        let mk = |p: &str| json!({ "hook_event_name": "UserPromptSubmit", "session_id": "rep", "prompt": p });
        let r = |v: &Value| from_claude_hook(v, b"", &env(&paths)).unwrap().payload.prompt_repeat.unwrap();
        let _ = fs::remove_file(paths.state.join("rep.prompt"));
        assert_eq!(r(&mk("go")), 1);
        assert_eq!(r(&mk("go")), 2);
        assert_eq!(r(&mk("go")), 3);
        assert_eq!(r(&mk("other")), 1);
    }

    #[test]
    fn failed_tests_and_ignored_tools() {
        let paths = tmp();
        let fail = json!({
            "hook_event_name": "PostToolUseFailure", "session_id": "s", "tool_name": "Bash",
            "tool_input": { "command": "npm test" }, "error": "Exit code 1", "is_interrupt": false
        });
        let ev = from_claude_hook(&fail, b"", &env(&paths)).unwrap();
        assert_eq!(ev.payload.test_passed, Some(false));
        let ls = json!({ "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": { "command": "ls" } });
        assert!(from_claude_hook(&ls, b"", &env(&paths)).is_none());
        let read = json!({ "hook_event_name": "PostToolUse", "tool_name": "Read", "tool_input": {} });
        assert!(from_claude_hook(&read, b"", &env(&paths)).is_none());
        let failed_commit = json!({
            "hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "tool_input": { "command": "git commit -m x" }
        });
        assert!(from_claude_hook(&failed_commit, b"", &env(&paths)).is_none());
    }

    #[test]
    fn codex_hooks() {
        let paths = tmp();
        let e = |v: Value| from_codex_hook(&v, b"", &env(&paths));
        let patch = "*** Begin Patch\n*** Add File: docs/plan.md\n+第一段计划写在这里\n*** Update File: src/main.rs\n@@ fn main\n-old\n+new\n+more\n*** End Patch";
        let evs = e(json!({ "hook_event_name": "PostToolUse", "session_id": "cx", "turn_id": "t9", "cwd": "/w",
                            "tool_name": "apply_patch", "tool_input": { "command": patch } }));
        assert_eq!(evs.len(), 2, "one event per file");
        assert!(evs.iter().all(|ev| ev.source == Source::Codex && ev.turn_id.as_deref() == Some("t9") && ev.session_id.as_deref() == Some("cx")));
        assert_eq!(evs[0].id == evs[1].id, false);
        assert_eq!((evs[0].payload.occupation.as_deref(), evs[0].payload.words), (Some("writer"), Some(9)));
        assert_eq!((evs[1].payload.occupation.as_deref(), evs[1].payload.lines_added, evs[1].payload.lines_removed), (Some("swe"), Some(2), Some(1)));
        let line = serde_json::to_string(&evs).unwrap();
        assert!(!line.contains("计划") && !line.contains("main.rs"), "nothing of the patch is kept");

        let test = |resp: Value| e(json!({ "hook_event_name": "PostToolUse", "session_id": "cx", "turn_id": "t9",
                                         "tool_name": "Bash", "tool_input": { "command": "cargo test" }, "tool_response": resp }));
        assert_eq!(test(json!("Process exited with code 101\nOutput:\nfailed"))[0].payload.test_passed, Some(false));
        assert_eq!(test(json!({ "exit_code": 0 }))[0].payload.test_passed, Some(true));
        assert_eq!(test(json!("ok"))[0].payload.test_passed, Some(true), "no exit code means it ran");

        let sub = e(json!({ "hook_event_name": "SubagentStart", "session_id": "cx", "turn_id": "t9", "agent_id": "a" }));
        assert_eq!(sub[0].payload.subagents, Some(1));
        let prompt = e(json!({ "hook_event_name": "UserPromptSubmit", "session_id": "cx", "turn_id": "t10", "prompt": "做个海报" }));
        assert_eq!((prompt[0].kind, prompt[0].turn_id.as_deref()), (Kind::Prompt, Some("t10")));
        assert_eq!(command_text(&json!(["/bin/zsh", "-lc", "ls -la"])), "ls -la");
        assert_eq!(command_text(&json!(["git", "status"])), "git status");
    }

    #[test]
    fn occupations_from_tools_and_prompts() {
        let paths = tmp();
        let e = |v: Value| from_claude_hook(&v, b"", &env(&paths)).unwrap().payload;
        let p = e(json!({ "hook_event_name": "PostToolUse", "tool_name": "WebSearch", "tool_input": { "query": "secret query" } }));
        assert_eq!((p.occupation.as_deref(), p.minutes), (Some("research"), Some(5.0)));
        let p = e(json!({ "hook_event_name": "PostToolUse", "tool_name": "mcp__financial-datasets__get_news", "tool_input": {} }));
        assert_eq!((p.occupation.as_deref(), p.finance), (Some("fin"), Some(true)));
        let p = e(json!({ "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": { "command": "ffmpeg -i a.mp4 b.mp4" } }));
        assert_eq!((p.occupation.as_deref(), p.minutes), (Some("video"), Some(15.0)));
        let doc = "第一段文字。\nSecond paragraph here.";
        let p = e(json!({ "hook_event_name": "PostToolUse", "tool_name": "Write", "cwd": "/w",
                          "tool_input": { "file_path": "/w/notes.md", "content": doc }, "tool_response": { "type": "create", "structuredPatch": [] } }));
        assert_eq!((p.occupation.as_deref(), p.words), (Some("writer"), Some(8)));
        let line = serde_json::to_string(&p).unwrap();
        assert!(!line.contains("第一段") && !line.contains("paragraph"), "words counted, never kept");
        let p = e(json!({ "hook_event_name": "UserPromptSubmit", "session_id": "fx", "prompt": "帮我分析一下这只股票的财报" }));
        assert_eq!((p.finance, p.translate), (Some(true), None));
        let p = e(json!({ "hook_event_name": "UserPromptSubmit", "session_id": "tr", "prompt": "Translate this into Chinese" }));
        assert_eq!(p.translate, Some(true));
        let read = json!({ "hook_event_name": "PostToolUse", "tool_name": "mcp__Claude_Browser__computer", "tool_input": {} });
        assert!(from_claude_hook(&read, b"", &env(&paths)).is_none(), "clicking around is not research");
    }
}
