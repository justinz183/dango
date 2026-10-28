//! History import (SPEC 4.3): replays Claude Code transcripts under
//! ~/.claude/projects into events, offline, with the same rules as the live
//! hooks. Only activity before the first live event is imported, so running
//! it again never double-counts. Transcript content stays in memory.

use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::Instant;

use chrono::DateTime;
use serde_json::{json, Value};
use shadowcorp_core::classify;
use shadowcorp_core::event::{Event, Kind, Payload, Source};

use crate::capture::{from_claude_hook, CaptureEnv};
use crate::ingest::{Processor, Result};
use crate::paths::{short_hash, Paths};

/// A session whose last entry is this recent may still be running; it gets
/// no session_end so live hooks can carry on with it.
const OPEN_SESSION_MS: i64 = 30 * 60_000;

#[derive(Debug, Default)]
pub struct Report {
    pub files: usize,
    pub events: usize,
    pub new_events: usize,
    pub secs: f64,
}

fn ts_of(e: &Value) -> Option<i64> {
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

fn bf_event(id_seed: &str, ts: i64, kind: Kind, session: &str) -> Event {
    let mut ev = Event::new(format!("bf_{}", short_hash(id_seed)), ts, Source::Backfill, kind);
    ev.session_id = Some(session.to_string());
    ev.payload.origin = Some(Source::ClaudeCode);
    ev
}

/// Events for one transcript file. `parent` is set for subagent files, whose
/// tool calls count toward the parent session's open turn.
pub fn file_events(path: &Path, parent: Option<&str>, cutoff: i64, paths: &Paths) -> Vec<Event> {
    let Ok(f) = fs::File::open(path) else { return Vec::new() };
    let env = CaptureEnv { paths, now_ms: 0, nonce: String::new(), git_lookup: false };
    let mut out = Vec::new();
    let mut session: Option<String> = parent.map(str::to_string);
    let mut cwd = String::new();
    let (mut first_ts, mut last_ts) = (None::<i64>, 0i64);
    let mut pending: HashMap<String, (String, Value)> = HashMap::new();
    let mut turn: Option<(String, i64, String)> = None; // (turn id, last assistant ts, seed)
    let mut last_prompt: Option<(String, u32)> = None;

    let close = |turn: &mut Option<(String, i64, String)>, out: &mut Vec<Event>, session: &str| {
        if let Some((tid, at, seed)) = turn.take() {
            let mut ev = bf_event(&format!("{seed}\0end"), at, Kind::TurnEnd, session);
            ev.turn_id = Some(tid);
            out.push(ev);
        }
    };

    for line in BufReader::new(f).lines().map_while(|l| l.ok()) {
        let Ok(e) = serde_json::from_str::<Value>(&line) else { continue };
        let ty = e.get("type").and_then(Value::as_str).unwrap_or("");
        if ty != "user" && ty != "assistant" {
            continue;
        }
        let Some(ts) = ts_of(&e) else { continue };
        if ts >= cutoff {
            continue;
        }
        if session.is_none() {
            session = e.get("sessionId").and_then(Value::as_str).map(str::to_string);
        }
        let Some(sid) = session.clone() else { continue };
        if cwd.is_empty() {
            cwd = e.get("cwd").and_then(Value::as_str).unwrap_or("").to_string();
        }
        if first_ts.is_none() && parent.is_none() {
            first_ts = Some(ts);
            let mut ev = bf_event(&format!("{sid}\0start"), ts, Kind::SessionStart, &sid);
            ev.payload.session_source = Some("startup".into());
            out.push(ev);
        }
        last_ts = ts;
        let uuid = e.get("uuid").and_then(Value::as_str).unwrap_or("").to_string();
        let blocks = e.get("message").and_then(|m| m.get("content")).and_then(Value::as_array).cloned().unwrap_or_default();

        if ty == "assistant" {
            for b in &blocks {
                if b.get("type").and_then(Value::as_str) == Some("tool_use") {
                    let id = b.get("id").and_then(Value::as_str).unwrap_or("").to_string();
                    let name = b.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                    pending.insert(id, (name, b.get("input").cloned().unwrap_or(Value::Null)));
                }
            }
            if let Some(t) = turn.as_mut() {
                t.1 = ts;
            }
            continue;
        }

        // user entry: tool results first
        let mut had_result = false;
        for b in &blocks {
            if b.get("type").and_then(Value::as_str) != Some("tool_result") {
                continue;
            }
            had_result = true;
            let id = b.get("tool_use_id").and_then(Value::as_str).unwrap_or("");
            let Some((name, input)) = pending.remove(id) else { continue };
            let failed = b.get("is_error").and_then(Value::as_bool).unwrap_or(false);
            let hook = json!({
                "hook_event_name": if failed { "PostToolUseFailure" } else { "PostToolUse" },
                "session_id": sid, "cwd": cwd, "tool_name": name, "tool_input": input,
                "tool_response": e.get("toolUseResult").cloned().unwrap_or(Value::Null),
            });
            if let Some(mut ev) = from_claude_hook(&hook, b"", &env) {
                let fresh = bf_event(&format!("{sid}\0{id}\0tool"), ts, Kind::Tool, &sid);
                ev.id = fresh.id;
                ev.ts = fresh.ts;
                ev.source = Source::Backfill;
                ev.payload.origin = Some(Source::ClaudeCode);
                ev.turn_id = if parent.is_none() { turn.as_ref().map(|t| t.0.clone()) } else { None };
                out.push(ev);
            }
        }
        if had_result || parent.is_some() || e.get("isSidechain").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(text) = prompt_text(&e) else { continue };
        close(&mut turn, &mut out, &sid);
        let tid = e.get("promptId").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| format!("bf_{uuid}"));
        let fp = text.trim().to_string();
        let repeat = match &last_prompt {
            Some((p, n)) if *p == fp => n + 1,
            _ => 1,
        };
        last_prompt = Some((fp, repeat));
        let seed = format!("{sid}\0{uuid}");
        let mut ev = bf_event(&format!("{seed}\0prompt"), ts, Kind::Prompt, &sid);
        ev.turn_id = Some(tid.clone());
        ev.payload = Payload {
            origin: Some(Source::ClaudeCode),
            task_class: Some(classify::classify_prompt(&text)),
            is_correction: Some(classify::is_correction(&text)),
            prompt_repeat: Some(repeat),
            ..Default::default()
        };
        ev.cwd_hash = (!cwd.is_empty()).then(|| short_hash(&cwd));
        out.push(ev);
        turn = Some((tid, ts, seed));
    }
    if let Some(sid) = session.filter(|_| parent.is_none()) {
        close(&mut turn, &mut out, &sid);
        if first_ts.is_some() && cutoff - last_ts > OPEN_SESSION_MS {
            let mut ev = bf_event(&format!("{sid}\0end"), last_ts, Kind::SessionEnd, &sid);
            ev.payload.reason = Some("other".into());
            out.push(ev);
        }
    }
    out
}

/// Imports everything before `cutoff` (ms). Runs in one transaction.
pub fn run(p: &mut Processor, paths: &Paths, claude_dir: &Path, cutoff: i64) -> Result<Report> {
    let started = Instant::now();
    let files = transcript_files(claude_dir);
    let mut events: Vec<Event> = Vec::new();
    for (f, parent) in &files {
        events.extend(file_events(f, parent.as_deref(), cutoff, paths));
    }
    // Stable sort keeps per-file order for equal timestamps.
    events.sort_by_key(|e| e.ts_ms().unwrap_or(0));
    let mut report = Report { files: files.len(), events: events.len(), ..Default::default() };
    p.begin()?;
    for ev in &events {
        match p.handle(ev) {
            Ok(true) => report.new_events += 1,
            Ok(false) => {}
            Err(e) => eprintln!("shadowcorp: skipped {}: {e}", ev.id),
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
