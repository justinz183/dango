//! History import (SPEC 4.3): replays Claude Code transcripts under
//! ~/.claude/projects and Codex rollouts under ~/.codex/sessions into
//! events, offline, with the same rules as the live hooks. Only activity
//! before each tool's first live event is imported, so running it again
//! never double-counts. Transcript content stays in memory.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::Instant;

use chrono::DateTime;
use serde_json::{json, Value};
use dango_core::{classify, occupation};
use dango_core::event::{Event, Kind, Payload, Source};

use crate::capture::{command_text, edit_hook, from_claude_hook, CaptureEnv};
use crate::ingest::{Processor, Result};
use crate::paths::{short_hash, Paths};

/// A session whose last entry is this recent may still be running; it gets
/// no session_end so live hooks can carry on with it.
const OPEN_SESSION_MS: i64 = 30 * 60_000;
/// A Claude Code turn still open this long after its last entry is over (an
/// interruption writes no end); one with a tool still running gets
/// OPEN_SESSION_MS.
const OPEN_TURN_MS: i64 = 10 * 60_000;
/// After Claude ends a turn (`end_turn`), how long to wait for it to carry
/// on (a hook asking for more) before the turn counts as done.
const END_GRACE_MS: i64 = 20_000;

#[derive(Debug, Default)]
pub struct Report {
    pub files: usize,
    pub events: usize,
    pub new_events: usize,
    pub secs: f64,
}

pub(crate) fn ts_of(e: &Value) -> Option<i64> {
    DateTime::parse_from_rfc3339(e.get("timestamp")?.as_str()?).ok().map(|d| d.timestamp_millis())
}

/// The human-typed text of a user entry, or None for tool results, meta
/// entries, slash-command echoes and interruption markers.
fn prompt_text(e: &Value) -> Option<String> {
    if e.get("isMeta").and_then(Value::as_bool) == Some(true) || e.get("toolUseResult").is_some() {
        return None;
    }
    let content = e.get("message")?.get("content")?;
    let text = match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => {
            if blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("tool_result")) {
                return None;
            }
            blocks
                .iter()
                .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|b| b.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        }
        _ => return None,
    };
    let t = text.trim_start();
    if t.is_empty() || t.starts_with('<') || t.starts_with("[Request interrupted") || t.starts_with("Caveat:") {
        return None;
    }
    Some(text)
}

pub fn transcript_files(claude_dir: &Path) -> Vec<(PathBuf, Option<String>)> {
    let mut out = Vec::new();
    let Ok(projects) = fs::read_dir(claude_dir.join("projects")) else { return out };
    for proj in projects.flatten().map(|e| e.path()).filter(|p| p.is_dir()) {
        let Ok(entries) = fs::read_dir(&proj) else { continue };
        for p in entries.flatten().map(|e| e.path()) {
            if p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                out.push((p, None));
            } else if p.is_dir() {
                // <session>/subagents/*.jsonl belong to the parent session.
                let parent = p.file_name().and_then(|n| n.to_str()).map(str::to_string);
                if let Ok(subs) = fs::read_dir(p.join("subagents")) {
                    for s in subs.flatten().map(|e| e.path()) {
                        if s.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                            out.push((s, parent.clone()));
                        }
                    }
                }
            }
        }
    }
    out.sort();
    out
}

pub(crate) fn bf_event(id_seed: &str, ts: i64, kind: Kind, session: &str) -> Event {
    let mut ev = Event::new(format!("bf_{}", short_hash(id_seed)), ts, Source::Backfill, kind);
    ev.session_id = Some(session.to_string());
    ev.payload.origin = Some(Source::ClaudeCode);
    ev
}

/// One Claude Code transcript read line by line: whole for backfill
/// (`file_events`), or as Claude Code writes it (claude_tail.rs). `parent`
/// is set for subagent files, whose tool calls count toward the parent
/// session's open turn.
#[derive(Default)]
pub struct Transcript {
    parent: Option<String>,
    session: Option<String>,
    cwd: String,
    first_ts: Option<i64>,
    last_ts: i64,
    pending: HashMap<String, (String, Value)>,
    /// The open turn: (turn id, last assistant ts, seed).
    turn: Option<(String, i64, String)>,
    /// Claude ended the open turn: `end_turn` with no tool calls.
    turn_done: bool,
    last_prompt: Option<(String, u32)>,
    ended: bool,
}

impl Transcript {
    pub fn new(parent: Option<&str>) -> Transcript {
        Transcript { parent: parent.map(str::to_string), session: parent.map(str::to_string), ..Default::default() }
    }

    /// The session this file belongs to, once a line has said.
    pub fn session(&self) -> Option<&str> {
        self.session.as_deref()
    }

    /// When the last line was written.
    pub fn last_ts(&self) -> i64 {
        self.last_ts
    }

    /// A turn is open (a main transcript only).
    pub fn turn_open(&self) -> bool {
        self.parent.is_none() && self.turn.is_some()
    }

    /// Ends the open turn now: Claude Code says the session is idle.
    pub fn end_turn(&mut self) -> Vec<Event> {
        let mut out = Vec::new();
        if self.turn_open() {
            self.close(&mut out);
        }
        out
    }

    fn close(&mut self, out: &mut Vec<Event>) {
        if let (Some((tid, at, seed)), Some(sid)) = (self.turn.take(), self.session.clone()) {
            let mut ev = bf_event(&format!("{seed}\0end"), at, Kind::TurnEnd, &sid);
            ev.turn_id = Some(tid);
            out.push(ev);
        }
        self.turn_done = false;
    }

    /// The events in one line of the file, none at or after `cutoff`.
    pub fn line(&mut self, line: &str, cutoff: i64, paths: &Paths) -> Vec<Event> {
        let mut out = Vec::new();
        let Ok(e) = serde_json::from_str::<Value>(line) else { return out };
        let ty = e.get("type").and_then(Value::as_str).unwrap_or("");
        if ty != "user" && ty != "assistant" {
            return out;
        }
        let Some(ts) = ts_of(&e) else { return out };
        if ts >= cutoff {
            return out;
        }
        if self.session.is_none() {
            self.session = e.get("sessionId").and_then(Value::as_str).map(str::to_string);
        }
        let Some(sid) = self.session.clone() else { return out };
        if self.cwd.is_empty() {
            self.cwd = e.get("cwd").and_then(Value::as_str).unwrap_or("").to_string();
        }
        if self.first_ts.is_none() && self.parent.is_none() {
            self.first_ts = Some(ts);
            let mut ev = bf_event(&format!("{sid}\0start"), ts, Kind::SessionStart, &sid);
            ev.payload.session_source = Some("startup".into());
            out.push(ev);
        }
        self.last_ts = ts;
        let uuid = e.get("uuid").and_then(Value::as_str).unwrap_or("").to_string();
        let blocks = e.get("message").and_then(|m| m.get("content")).and_then(Value::as_array).cloned().unwrap_or_default();

        if ty == "assistant" {
            let mut calls = false;
            for b in &blocks {
                if b.get("type").and_then(Value::as_str) == Some("tool_use") {
                    calls = true;
                    let id = b.get("id").and_then(Value::as_str).unwrap_or("").to_string();
                    let name = b.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                    // A subagent sets off: a helper at work until its call returns.
                    if is_subagent(&name) && self.parent.is_none() {
                        let mut ev = bf_event(&format!("{sid}\0{id}\0substart"), ts, Kind::SubagentStart, &sid);
                        ev.turn_id = self.turn.as_ref().map(|t| t.0.clone());
                        out.push(ev);
                    }
                    self.pending.insert(id, (name, b.get("input").cloned().unwrap_or(Value::Null)));
                }
            }
            if let Some(t) = self.turn.as_mut() {
                t.1 = ts;
            }
            let stop = e.get("message").and_then(|m| m.get("stop_reason")).and_then(Value::as_str);
            if calls {
                self.turn_done = false;
            } else if stop == Some("end_turn") {
                self.turn_done = true;
            }
            return out;
        }

        // user entry: tool results first
        let env = CaptureEnv { paths, now_ms: 0, nonce: String::new(), git_lookup: false };
        let mut had_result = false;
        for b in &blocks {
            if b.get("type").and_then(Value::as_str) != Some("tool_result") {
                continue;
            }
            had_result = true;
            self.turn_done = false;
            let id = b.get("tool_use_id").and_then(Value::as_str).unwrap_or("");
            let Some((name, input)) = self.pending.remove(id) else { continue };
            if is_subagent(&name) && self.parent.is_none() {
                let mut ev = bf_event(&format!("{sid}\0{id}\0substop"), ts, Kind::SubagentStop, &sid);
                ev.turn_id = self.turn.as_ref().map(|t| t.0.clone());
                out.push(ev);
            }
            let failed = b.get("is_error").and_then(Value::as_bool).unwrap_or(false);
            let hook = json!({
                "hook_event_name": if failed { "PostToolUseFailure" } else { "PostToolUse" },
                "session_id": sid, "cwd": self.cwd, "tool_name": name, "tool_input": input,
                "tool_response": e.get("toolUseResult").cloned().unwrap_or(Value::Null),
            });
            if let Some(mut ev) = from_claude_hook(&hook, b"", &env) {
                let fresh = bf_event(&format!("{sid}\0{id}\0tool"), ts, Kind::Tool, &sid);
                ev.id = fresh.id;
                ev.ts = fresh.ts;
                ev.source = Source::Backfill;
                ev.payload.origin = Some(Source::ClaudeCode);
                ev.turn_id = if self.parent.is_none() { self.turn.as_ref().map(|t| t.0.clone()) } else { None };
                out.push(ev);
            }
        }
        if had_result || self.parent.is_some() || e.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            return out;
        }
        let Some(text) = prompt_text(&e) else { return out };
        self.close(&mut out);
        let tid = e.get("promptId").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| format!("bf_{uuid}"));
        let fp = text.trim().to_string();
        let repeat = match &self.last_prompt {
            Some((p, n)) if *p == fp => n + 1,
            _ => 1,
        };
        self.last_prompt = Some((fp, repeat));
        let seed = format!("{sid}\0{uuid}");
        let mut ev = bf_event(&format!("{seed}\0prompt"), ts, Kind::Prompt, &sid);
        ev.turn_id = Some(tid.clone());
        ev.payload = Payload {
            origin: Some(Source::ClaudeCode),
            task_class: Some(classify::classify_prompt(&text)),
            is_correction: Some(classify::is_correction(&text)),
            prompt_repeat: Some(repeat),
            topic: occupation::topic(&text).map(str::to_string),
            ..Default::default()
        };
        ev.cwd_hash = (!self.cwd.is_empty()).then(|| short_hash(&self.cwd));
        out.push(ev);
        self.turn = Some((tid, ts, seed));
        out
    }

    /// What closes because nothing more was written before `now`: the open
    /// turn once Claude ended it and END_GRACE_MS passed (or the file went
    /// quiet: OPEN_TURN_MS, OPEN_SESSION_MS with a tool still running), and
    /// the session after OPEN_SESSION_MS. A session still in use keeps both
    /// open, for the follower or the hooks to carry on.
    pub fn finish(&mut self, now: i64) -> Vec<Event> {
        let mut out = Vec::new();
        if self.parent.is_some() || self.session.is_none() {
            return out;
        }
        let quiet = now.saturating_sub(self.last_ts);
        let over = if self.pending.is_empty() { (self.turn_done && quiet >= END_GRACE_MS) || quiet > OPEN_TURN_MS } else { quiet > OPEN_SESSION_MS };
        if self.turn.is_some() && over {
            self.close(&mut out);
        }
        if !self.ended && self.first_ts.is_some() && quiet > OPEN_SESSION_MS {
            self.ended = true;
            let sid = self.session.clone().unwrap_or_default();
            let mut ev = bf_event(&format!("{sid}\0end"), self.last_ts, Kind::SessionEnd, &sid);
            ev.payload.reason = Some("other".into());
            out.push(ev);
        }
        out
    }
}

/// Claude Code's tools that run a subagent.
fn is_subagent(tool: &str) -> bool {
    matches!(tool, "Task" | "Agent")
}

/// Events for one transcript file, read whole.
pub fn file_events(path: &Path, parent: Option<&str>, cutoff: i64, paths: &Paths) -> Vec<Event> {
    let Ok(f) = fs::File::open(path) else { return Vec::new() };
    let mut t = Transcript::new(parent);
    let mut out = Vec::new();
    for line in BufReader::new(f).lines().map_while(|l| l.ok()) {
        out.extend(t.line(&line, cutoff, paths));
    }
    out.extend(t.finish(cutoff));
    out
}

/// Every Codex rollout file (one per thread), live and archived.
pub fn codex_files(codex_dir: &Path) -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for p in entries.flatten().map(|e| e.path()) {
            if p.is_dir() {
                walk(&p, out);
            } else if p.extension().and_then(|e| e.to_str()) == Some("jsonl") {
                out.push(p);
            }
        }
    }
    let mut out = Vec::new();
    walk(&codex_dir.join("sessions"), &mut out);
    walk(&codex_dir.join("archived_sessions"), &mut out);
    out.sort();
    out
}

/// The Claude Code-shaped hooks for one Codex step (`item_completed`).
fn codex_step(item: &Value, cwd: &str) -> Vec<Value> {
    let s = |k: &str| item.get(k).and_then(Value::as_str).unwrap_or("");
    let tool = |name: &str| json!({ "hook_event_name": "PostToolUse", "tool_name": name, "tool_input": {} });
    match s("type") {
        "CommandExecution" => {
            let ok = item.get("exit_code").and_then(Value::as_i64).unwrap_or(0) == 0;
            let cmd = item.get("command").map(command_text).unwrap_or_default();
            vec![json!({ "hook_event_name": if ok { "PostToolUse" } else { "PostToolUseFailure" }, "tool_name": "Bash", "tool_input": { "command": cmd } })]
        }
        "FileChange" if s("status") == "completed" => item
            .get("changes")
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
            .map(|(path, ch)| {
                let text = |k: &str| ch.get(k).and_then(Value::as_str).unwrap_or("");
                let (new, lines): (bool, Vec<String>) = match text("type") {
                    "add" => (true, text("content").lines().map(|l| format!("+{l}")).collect()),
                    "delete" => (false, text("content").lines().map(|l| format!("-{l}")).collect()),
                    _ => (false, text("unified_diff").lines().filter(|l| !l.starts_with("+++") && !l.starts_with("---")).filter(|l| l.starts_with('+') || l.starts_with('-')).map(str::to_string).collect()),
                };
                edit_hook(cwd, path, new, lines)
            })
            .collect(),
        "McpToolCall" if s("status") == "completed" => vec![tool(&format!("mcp__{}__{}", s("server"), s("tool")))],
        "WebSearch" => vec![tool("WebSearch")],
        "Extension" if s("kind") == "web.search" => match item.get("action").and_then(|a| a.get("type")).and_then(Value::as_str) {
            Some("search") => vec![tool("WebSearch")],
            Some("openPage") => vec![tool("WebFetch")],
            _ => Vec::new(),
        },
        "SubAgentActivity" if s("kind") == "started" => vec![tool("Agent")],
        _ => Vec::new(),
    }
}

/// One Codex rollout read a line at a time: backfill reads a file whole and
/// the daemon follows a live one as Codex writes it (codex_tail). Either way
/// an event gets the same id, so it counts once. Each step is an
/// `item_completed` with its `turn_id`; turns end with `task_complete` or
/// `turn_aborted`. A spawned sub-agent's steps count toward the parent
/// session; Codex's own reviewer threads ("guardian") have no steps.
#[derive(Default)]
pub struct Rollout {
    path: String,
    sid: Option<String>,
    cwd: String,
    sub: bool,
    first_ts: Option<i64>,
    last_ts: i64,
    prompted: HashSet<String>,
    last_prompt: Option<(String, u32)>,
    n: usize,
    ended: bool,
}

impl Rollout {
    pub fn new(path: &Path) -> Rollout {
        Rollout { path: path.display().to_string(), ..Default::default() }
    }

    fn event(seed: &str, ts: i64, kind: Kind, sid: &str) -> Event {
        let mut ev = bf_event(&format!("codex\0{seed}"), ts, kind, sid);
        ev.payload.origin = Some(Source::Codex);
        ev
    }

    /// The events in one line of the file, none at or after `cutoff`.
    pub fn line(&mut self, line: &str, cutoff: i64, paths: &Paths) -> Vec<Event> {
        let mut out = Vec::new();
        let Ok(e) = serde_json::from_str::<Value>(line) else { return out };
        let Some(ts) = ts_of(&e) else { return out };
        let p = e.get("payload").cloned().unwrap_or(Value::Null);
        let ty = e.get("type").and_then(Value::as_str).unwrap_or("");
        if ty == "session_meta" && self.sid.is_none() {
            self.sid = p.get("session_id").or_else(|| p.get("id")).and_then(Value::as_str).map(str::to_string);
            self.cwd = p.get("cwd").and_then(Value::as_str).unwrap_or("").to_string();
            self.sub = p.get("source").and_then(|s| s.get("subagent")).is_some();
            return out;
        }
        let (Some(sid), "event_msg") = (self.sid.clone(), ty) else { return out };
        if ts >= cutoff {
            return out;
        }
        if self.first_ts.is_none() && !self.sub {
            self.first_ts = Some(ts);
            let mut ev = Rollout::event(&format!("{sid}\0{}\0start", self.path), ts, Kind::SessionStart, &sid);
            ev.payload.session_source = Some("startup".into());
            out.push(ev);
        }
        self.last_ts = ts;
        let turn = p.get("turn_id").and_then(Value::as_str).unwrap_or("").to_string();
        match p.get("type").and_then(Value::as_str).unwrap_or("") {
            "task_complete" | "turn_aborted" if !self.sub && !turn.is_empty() => {
                let mut ev = Rollout::event(&format!("{sid}\0{turn}\0end"), ts, Kind::TurnEnd, &sid);
                ev.turn_id = Some(turn);
                out.push(ev);
            }
            "item_completed" => {
                let item = p.get("item").cloned().unwrap_or(Value::Null);
                if item.get("type").and_then(Value::as_str) == Some("UserMessage") {
                    let text: String = item
                        .get("content")
                        .and_then(Value::as_array)
                        .map(|c| c.iter().filter_map(|b| b.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n"))
                        .unwrap_or_default();
                    let t = text.trim_start();
                    if self.sub || turn.is_empty() || t.is_empty() || t.starts_with('<') || !self.prompted.insert(turn.clone()) {
                        return out;
                    }
                    let fp = text.trim().to_string();
                    let repeat = match &self.last_prompt {
                        Some((q, n)) if *q == fp => n + 1,
                        _ => 1,
                    };
                    self.last_prompt = Some((fp, repeat));
                    let candidates = occupation::topic_candidates(&text);
                    let mut ev = Rollout::event(&format!("{sid}\0{turn}\0prompt"), ts, Kind::Prompt, &sid);
                    ev.turn_id = Some(turn);
                    ev.payload = Payload {
                        origin: Some(Source::Codex),
                        task_class: Some(classify::classify_prompt(&text)),
                        is_correction: Some(classify::is_correction(&text)),
                        prompt_repeat: Some(repeat),
                        topic: candidates.first().map(|t| t.to_string()),
                        topic_ties: (candidates.len() > 1).then(|| candidates[1..].iter().map(|t| t.to_string()).collect()),
                        ..Default::default()
                    };
                    ev.cwd_hash = (!self.cwd.is_empty()).then(|| short_hash(&self.cwd));
                    out.push(ev);
                    return out;
                }
                let env = CaptureEnv { paths, now_ms: 0, nonce: String::new(), git_lookup: false };
                let id = item.get("id").and_then(Value::as_str).unwrap_or("").to_string();
                for (i, mut hook) in codex_step(&item, &self.cwd).into_iter().enumerate() {
                    hook["session_id"] = json!(sid);
                    hook["cwd"] = json!(self.cwd);
                    let Some(mut ev) = from_claude_hook(&hook, b"", &env) else { continue };
                    self.n += 1;
                    let fresh = Rollout::event(&format!("{sid}\0{id}\0{i}\0{}\0tool", self.n), ts, Kind::Tool, &sid);
                    ev.id = fresh.id;
                    ev.ts = fresh.ts;
                    ev.source = Source::Backfill;
                    ev.payload.origin = Some(Source::Codex);
                    ev.turn_id = (!self.sub && !turn.is_empty()).then(|| turn.clone());
                    out.push(ev);
                }
            }
            _ => {}
        }
        out
    }

    /// The session's end, once it has been quiet for OPEN_SESSION_MS before
    /// `now` (a session still in use gets none). Given once.
    pub fn end(&mut self, now: i64) -> Option<Event> {
        let sid = self.sid.clone().filter(|_| !self.sub && !self.ended && self.first_ts.is_some() && now - self.last_ts > OPEN_SESSION_MS)?;
        self.ended = true;
        let mut ev = Rollout::event(&format!("{sid}\0{}\0end", self.path), self.last_ts, Kind::SessionEnd, &sid);
        ev.payload.reason = Some("other".into());
        Some(ev)
    }
}

/// Events for one Codex rollout, read whole.
pub fn codex_file_events(path: &Path, cutoff: i64, paths: &Paths) -> Vec<Event> {
    let Ok(f) = fs::File::open(path) else { return Vec::new() };
    let mut r = Rollout::new(path);
    let mut out = Vec::new();
    for line in BufReader::new(f).lines().map_while(|l| l.ok()) {
        out.extend(r.line(&line, cutoff, paths));
    }
    out.extend(r.end(cutoff));
    out
}

/// Imports Claude Code history before `cutoff` and, when `codex` is given
/// (its directory and cutoff), Codex history too. Runs in one transaction.
pub fn run(p: &mut Processor, paths: &Paths, claude_dir: &Path, cutoff: i64, codex: Option<(&Path, i64)>) -> Result<Report> {
    let started = Instant::now();
    let files = transcript_files(claude_dir);
    let mut events: Vec<Event> = Vec::new();
    for (f, parent) in &files {
        events.extend(file_events(f, parent.as_deref(), cutoff, paths));
    }
    let mut n_files = files.len();
    if let Some((dir, codex_cutoff)) = codex {
        let rollouts = codex_files(dir);
        n_files += rollouts.len();
        for f in &rollouts {
            events.extend(codex_file_events(f, codex_cutoff, paths));
        }
    }
    // Stable sort keeps per-file order for equal timestamps.
    events.sort_by_key(|e| e.ts_ms().unwrap_or(0));
    let mut report = Report { files: n_files, events: events.len(), ..Default::default() };
    p.begin()?;
    for ev in &events {
        match p.handle(ev) {
            Ok(true) => report.new_events += 1,
            Ok(false) => {}
            Err(e) => eprintln!("dango: skipped {}: {e}", ev.id),
        }
    }
    p.commit()?;
    report.secs = started.elapsed().as_secs_f64();
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_are_filtered() {
        let p = |v: Value| prompt_text(&v);
        assert!(p(json!({ "message": { "content": "Add a login page" } })).is_some());
        assert!(p(json!({ "message": { "content": "<command-name>/clear</command-name>" } })).is_none());
        assert!(p(json!({ "isMeta": true, "message": { "content": "x" } })).is_none());
        assert!(p(json!({ "message": { "content": [{ "type": "tool_result", "content": "ok" }] } })).is_none());
        assert!(p(json!({ "message": { "content": [{ "type": "text", "text": "fix it" }] } })).is_some());
        assert!(p(json!({ "message": { "content": "[Request interrupted by user]" } })).is_none());
    }
}
