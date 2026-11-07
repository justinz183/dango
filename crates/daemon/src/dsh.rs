//! DeepSeek Harness without hooks. The harness keeps each session as an
//! append-only event log, ~/.dsh/sessions/<project>/session-<id>/
//! session.v4.jsonl.zstd: a run of zstd frames holding JSON lines
//! (`turn/start`, `user/message`, `tool/call`, `tool/result`,
//! `assistant/message` with its token usage, `turn/end`, …). Like Codex,
//! the daemon reads it whole once for the history and then follows it while
//! the harness writes; every event has a stable id, so it counts once. The
//! harness's tools are Claude Code's under lower-case names with the same
//! arguments, so each step goes through the same hook reader. A prompt is
//! read only to classify its turn; only numbers are kept. Sessions the
//! harness runs as a subagent (`delegationDepth` > 0) are not read: nothing
//! in them says which turn of the parent they belong to, and the parent
//! already counts the helper going out and coming back.

use std::collections::HashMap;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use dango_core::event::{Event, Kind, Payload, Source};
use dango_core::{classify, occupation};
use serde_json::{json, Value};

use crate::backfill::{bf_event, Report};
use crate::capture::{from_claude_hook, CaptureEnv};
use crate::ingest::{Processor, Result};
use crate::paths::{short_hash, Paths};
use crate::titles::Meta;

/// A session quiet this long is over (and a turn the harness never ended).
const OPEN_SESSION_MS: i64 = 30 * 60_000;
/// Session logs written to within this long are followed.
const RECENT: Duration = Duration::from_secs(36 * 3600);

/// The harness's tools as Claude Code's; None for its own bookkeeping
/// (jobs, schedules, goals, plugins, …), which is no one's work.
fn claude_tool(name: &str) -> Option<&'static str> {
    Some(match name {
        "bash" => "Bash",
        "read" | "read_image" => "Read",
        "write" => "Write",
        "edit" => "Edit",
        "glob" => "Glob",
        "grep" => "Grep",
        "web_fetch" => "WebFetch",
        "web_search" => "WebSearch",
        "subagent" | "subagent_fork" => "Agent",
        "todo_write" => "TodoWrite",
        "skill" => "Skill",
        _ => return None,
    })
}

/// Every session log under `dsh_dir` (~/.dsh), oldest path first.
pub fn files(dsh_dir: &Path) -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for p in entries.flatten().map(|e| e.path()) {
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if p.is_dir() {
                walk(&p, out);
            } else if name.starts_with("session.v") && name.ends_with(".jsonl.zstd") {
                out.push(p);
            }
        }
    }
    let mut out = Vec::new();
    walk(&dsh_dir.join("sessions"), &mut out);
    out.sort();
    out
}

/// The log of session `sid` (its folder is named after it).
pub fn session_file(dsh_dir: &Path, sid: &str) -> Option<PathBuf> {
    if sid.is_empty() || !sid.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return None;
    }
    files(dsh_dir).into_iter().find(|p| p.parent().and_then(|d| d.file_name()).and_then(|n| n.to_str()) == Some(sid))
}

/// The text of the whole zstd frames in `path` from `offset` on, and the
/// offset after the last whole one: a frame still being written waits.
pub fn read_frames(path: &Path, offset: u64) -> (String, u64) {
    let mut text = String::new();
    let Ok(mut f) = fs::File::open(path) else { return (text, offset) };
    if f.seek(SeekFrom::Start(offset)).is_err() {
        return (text, offset);
    }
    let mut at = offset;
    loop {
        let Ok(mut d) = ruzstd::decoding::StreamingDecoder::new(&mut f) else { break };
        let mut part = Vec::new();
        if d.read_to_end(&mut part).is_err() {
            break;
        }
        drop(d);
        let Ok(p) = f.stream_position() else { break };
        at = p;
        text.push_str(&String::from_utf8_lossy(&part));
    }
    (text, at)
}

/// The title the harness gave session `sid` and its folder's name, for the
/// report window only (titles.rs).
pub fn meta(dsh_dir: &Path, sid: &str) -> Meta {
    let mut m = Meta::default();
    let Some(path) = session_file(dsh_dir, sid) else { return m };
    for line in read_frames(&path, 0).0.lines().filter(|l| l.contains("\"session\"") || l.contains("session/title")) {
        let Ok(e) = serde_json::from_str::<Value>(line) else { continue };
        match e.get("type").and_then(Value::as_str) {
            Some("session") => {
                let cwd = e.get("cwd").and_then(Value::as_str).unwrap_or("");
                m.project = Path::new(cwd).file_name().and_then(|n| n.to_str()).map(str::to_string);
            }
            Some("session/title") => {
                m.title = e.pointer("/data/title").and_then(Value::as_str).filter(|t| !t.trim().is_empty()).map(str::to_string);
            }
            _ => {}
        }
    }
    m
}

/// One session log read as the harness writes it: whole for the history
/// (`file_events`) or followed (`DshTail`).
#[derive(Default)]
pub struct DshSession {
    sid: Option<String>,
    cwd: String,
    child: bool,
    /// The open turn and whether its prompt event went out.
    turn: Option<(String, bool)>,
    /// Tool calls waiting for their result: name and arguments.
    pending: HashMap<String, (String, Value)>,
    first_ts: Option<i64>,
    last_ts: i64,
    last_prompt: Option<(String, u32)>,
    ended: bool,
    /// The start of a line whose end is in a later frame.
    carry: String,
}

impl DshSession {
    fn event(seed: &str, ts: i64, kind: Kind, sid: &str) -> Event {
        let mut ev = bf_event(&format!("dsh\0{seed}"), ts, kind, sid);
        ev.payload.origin = Some(Source::DeepSeek);
        ev
    }

    /// The events in newly decoded text, none at or after `cutoff`.
    pub fn text(&mut self, text: &str, cutoff: i64, paths: &Paths) -> Vec<Event> {
        let mut buf = std::mem::take(&mut self.carry);
        buf.push_str(text);
        let mut out = Vec::new();
        let mut lines: Vec<&str> = buf.split('\n').collect();
        let last = lines.pop().unwrap_or("");
        for l in lines {
            out.extend(self.line(l, cutoff, paths));
        }
        // A last line without its newline is whole if it parses.
        if serde_json::from_str::<Value>(last).is_ok() {
            out.extend(self.line(last, cutoff, paths));
        } else {
            self.carry = last.to_string();
        }
        out
    }

    fn line(&mut self, line: &str, cutoff: i64, paths: &Paths) -> Vec<Event> {
        let mut out = Vec::new();
        let Ok(e) = serde_json::from_str::<Value>(line) else { return out };
        let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let ty = s(&e, "type");
        if ty == "session" {
            if self.sid.is_none() {
                self.sid = e.get("id").and_then(Value::as_str).map(str::to_string);
                self.cwd = s(&e, "cwd");
                self.child = e.get("delegationDepth").and_then(Value::as_i64).unwrap_or(0) > 0;
            }
            return out;
        }
        let (Some(sid), false) = (self.sid.clone(), self.child) else { return out };
        let Some(ts) = e.get("time").and_then(Value::as_i64) else { return out };
        if ts >= cutoff {
            return out;
        }
        let seq = e.get("seq").and_then(Value::as_i64).unwrap_or(-1);
        let d = e.get("data").cloned().unwrap_or(Value::Null);
        if self.first_ts.is_none() {
            self.first_ts = Some(ts);
            let mut ev = DshSession::event(&format!("{sid}\0start"), ts, Kind::SessionStart, &sid);
            ev.payload.session_source = Some("startup".into());
            out.push(ev);
        }
        self.last_ts = ts;
        match ty.as_str() {
            "turn/start" => {
                self.close(ts, &mut out);
                let n = d.get("turn").and_then(Value::as_i64).unwrap_or(seq);
                self.turn = Some((format!("dsh_{}", short_hash(&format!("{sid}\0{n}"))), false));
            }
            "user/message" if d.pointer("/source/kind").and_then(Value::as_str) == Some("user") => {
                let text: String = d
                    .get("content")
                    .and_then(Value::as_array)
                    .map(|c| c.iter().filter(|b| b.get("type").and_then(Value::as_str) == Some("text")).filter_map(|b| b.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n"))
                    .unwrap_or_default();
                self.prompt(&sid, ts, Some(&text), &mut out);
            }
            "tool/call" => {
                self.prompt(&sid, ts, None, &mut out);
                let name = s(&d, "name");
                let args = d.get("arguments").and_then(Value::as_str).and_then(|a| serde_json::from_str(a).ok()).unwrap_or(Value::Null);
                if claude_tool(&name) == Some("Agent") {
                    let mut ev = DshSession::event(&format!("{sid}\0{seq}\0substart"), ts, Kind::SubagentStart, &sid);
                    ev.turn_id = self.turn.as_ref().map(|t| t.0.clone());
                    out.push(ev);
                }
                self.pending.insert(s(&d, "callId"), (name, args));
            }
            "tool/result" => {
                let m = d.get("message").cloned().unwrap_or(Value::Null);
                let Some((name, args)) = self.pending.remove(&s(&m, "toolCallId")) else { return out };
                let Some(tool) = claude_tool(&name) else { return out };
                let turn = self.turn.as_ref().map(|t| t.0.clone());
                if tool == "Agent" {
                    let mut ev = DshSession::event(&format!("{sid}\0{seq}\0substop"), ts, Kind::SubagentStop, &sid);
                    ev.turn_id = turn.clone();
                    out.push(ev);
                }
                // web_search takes a list of queries; Claude Code's one query.
                let input = match args.get("queries").and_then(Value::as_array) {
                    Some(q) if tool == "WebSearch" => json!({ "query": q.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ") }),
                    _ => args,
                };
                let failed = m.get("isError").and_then(Value::as_bool).unwrap_or(false);
                let hook = json!({
                    "hook_event_name": if failed { "PostToolUseFailure" } else { "PostToolUse" },
                    "session_id": sid, "cwd": self.cwd, "tool_name": tool, "tool_input": input,
                });
                let env = CaptureEnv { paths, now_ms: 0, nonce: String::new(), git_lookup: false };
                if let Some(mut ev) = from_claude_hook(&hook, b"", &env) {
                    let fresh = DshSession::event(&format!("{sid}\0{seq}\0tool"), ts, Kind::Tool, &sid);
                    ev.id = fresh.id;
                    ev.ts = fresh.ts;
                    ev.source = Source::Backfill;
                    ev.payload.origin = Some(Source::DeepSeek);
                    ev.turn_id = turn;
                    out.push(ev);
                }
            }
            "turn/end" => self.close(ts, &mut out),
            _ => {}
        }
        out
    }

    /// The open turn's prompt event, once: from the person's message, or
    /// unclassified when the harness starts work without one.
    fn prompt(&mut self, sid: &str, ts: i64, text: Option<&str>, out: &mut Vec<Event>) {
        let Some((tid, sent)) = self.turn.as_mut() else { return };
        if *sent {
            return;
        }
        *sent = true;
        let tid = tid.clone();
        let mut ev = DshSession::event(&format!("{tid}\0prompt"), ts, Kind::Prompt, sid);
        ev.turn_id = Some(tid);
        if let Some(text) = text.filter(|t| !t.trim().is_empty()) {
            let fp = text.trim().to_string();
            let repeat = match &self.last_prompt {
                Some((q, n)) if *q == fp => n + 1,
                _ => 1,
            };
            self.last_prompt = Some((fp, repeat));
            let candidates = occupation::topic_candidates(text);
            ev.payload = Payload {
                origin: Some(Source::DeepSeek),
                task_class: Some(classify::classify_prompt(text)),
                is_correction: Some(classify::is_correction(text)),
                prompt_repeat: Some(repeat),
                topic: candidates.first().map(|t| t.to_string()),
                topic_ties: (candidates.len() > 1).then(|| candidates[1..].iter().map(|t| t.to_string()).collect()),
                ..Default::default()
            };
        }
        ev.cwd_hash = (!self.cwd.is_empty()).then(|| short_hash(&self.cwd));
        out.push(ev);
    }

    fn close(&mut self, ts: i64, out: &mut Vec<Event>) {
        let (Some((tid, sent)), Some(sid)) = (self.turn.take(), self.sid.clone()) else { return };
        if sent {
            let mut ev = DshSession::event(&format!("{tid}\0end"), ts, Kind::TurnEnd, &sid);
            ev.turn_id = Some(tid);
            out.push(ev);
        }
        self.pending.clear();
    }

    /// What ends because nothing was written for OPEN_SESSION_MS before
    /// `now`: a turn the harness never closed, then the session. Given once.
    pub fn finish(&mut self, now: i64) -> Vec<Event> {
        let mut out = Vec::new();
        let Some(sid) = self.sid.clone().filter(|_| !self.child && self.first_ts.is_some()) else { return out };
        if now - self.last_ts > OPEN_SESSION_MS {
            self.close(self.last_ts, &mut out);
            if !self.ended {
                self.ended = true;
                let mut ev = DshSession::event(&format!("{sid}\0end"), self.last_ts, Kind::SessionEnd, &sid);
                ev.payload.reason = Some("other".into());
                out.push(ev);
            }
        }
        out
    }
}

/// Events for one session log, read whole.
pub fn file_events(path: &Path, cutoff: i64, paths: &Paths) -> Vec<Event> {
    let mut s = DshSession::default();
    let mut out = s.text(&read_frames(path, 0).0, cutoff, paths);
    out.extend(s.finish(cutoff));
    out
}

/// Imports every session log before `cutoff`, in one transaction.
pub fn import(p: &mut Processor, paths: &Paths, dsh_dir: &Path, cutoff: i64) -> Result<Report> {
    let started = Instant::now();
    let logs = files(dsh_dir);
    let mut events: Vec<Event> = logs.iter().flat_map(|f| file_events(f, cutoff, paths)).collect();
    events.sort_by_key(|e| e.ts_ms().unwrap_or(0));
    let mut report = Report { files: logs.len(), events: events.len(), ..Default::default() };
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

/// Follows the session logs the harness is writing.
pub struct DshTail {
    dir: PathBuf,
    /// Each followed log: how far its frames have been read, and its reader.
    files: HashMap<PathBuf, (u64, DshSession)>,
}

impl DshTail {
    pub fn new(dsh_dir: &Path) -> DshTail {
        DshTail { dir: dsh_dir.to_path_buf(), files: HashMap::new() }
    }

    /// The events in every frame written since the last poll, oldest first.
    /// The first poll reads recent logs from the top; what already counted
    /// comes back with the same ids and is ignored.
    pub fn poll(&mut self, paths: &Paths, now_ms: i64) -> Vec<Event> {
        let horizon = SystemTime::now() - RECENT;
        let recent = |p: &Path| fs::metadata(p).and_then(|m| m.modified()).is_ok_and(|t| t >= horizon);
        for p in files(&self.dir) {
            if !self.files.contains_key(&p) && recent(&p) {
                self.files.insert(p, (0, DshSession::default()));
            }
        }
        let mut out = Vec::new();
        for (path, (offset, s)) in self.files.iter_mut() {
            if fs::metadata(path).map(|m| m.len()).unwrap_or(0) > *offset {
                let (text, at) = read_frames(path, *offset);
                out.extend(s.text(&text, i64::MAX, paths));
                *offset = at;
            }
            out.extend(s.finish(now_ms));
        }
        self.files.retain(|p, _| recent(p));
        out.sort_by_key(|e| e.ts_ms().unwrap_or(0));
        out
    }
}
