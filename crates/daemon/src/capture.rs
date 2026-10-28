//! Turns a Claude Code hook's stdin JSON into spool events (SPEC 4.1).
//! Field names follow https://code.claude.com/docs/en/hooks (checked
//! 2026-10-28). Prompt text, commands, code and paths are read here and
//! reduced to derived values; none of them leaves this module.

use std::fs;
use std::path::Path;
use std::process::Command;

use serde_json::Value;
use shadowcorp_core::classify;
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
                    p.tool = Some(if tool == "Write" { "write" } else { "edit" }.to_string());
                    p.lines_added = Some(add);
                    p.lines_removed = Some(del);
                    file_signals(&mut p, cwd, path);
                    if env.git_lookup && tool != "Write" {
                        p.file_ages_days_max = file_age_days(path, env.now_ms);
                    }
                }
                "Bash" => {
                    let info = classify::analyze_command(s(&ti, "command").unwrap_or(""));
                    if !info.test && info.git.is_none() {
                        return None;
                    }
                    p.tool = Some("bash".into());
                    let interrupted = input.get("is_interrupt").and_then(Value::as_bool).unwrap_or(false);
                    if info.test && !interrupted {
                        p.test_cmd = Some(true);
                        p.test_passed = Some(ok);
                    }
                    if ok {
                        p.git_action = info.git;
                    }
                    if p.test_cmd.is_none() && p.git_action.is_none() {
                        return None;
                    }
                }
                "Agent" | "Task" => {
                    p.tool = Some("agent".into());
                    p.subagents = Some(1);
                }
                _ => return None,
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
}
