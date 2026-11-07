//! WorkBuddy (Tencent's desktop agent) without hooks. It keeps each
//! conversation as JSON lines, <home>/projects/<project>/<session>.jsonl, home
//! being ~/.workbuddy-ai (the "WorkBuddy AI" build) or ~/.workbuddy. The
//! lines are OpenAI-Agents-style items: `message` (the person's, with
//! `providerData.startsNewUserRequest`, and the model's), `function_call`
//! (Claude Code's tool names and arguments) and `function_call_result`; each
//! model step's first item carries its token usage (`providerData.rawUsage`,
//! read by usage.rs). Like Codex and DeepSeek Harness, the daemon reads the
//! files whole once for the history and then follows them; every event has a
//! stable id, so it counts once. A prompt is read only to classify its turn;
//! only numbers are kept. Subagent transcripts (<session>/subagents/) are not
//! read: the parent already counts the helper going out and coming back.

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

/// WorkBuddy's data folders under the home folder (the overseas build's first).
pub const HOMES: [&str; 2] = [".workbuddy-ai", ".workbuddy"];
/// A turn whose last item is the model's answer is over after this long.
const ANSWERED_MS: i64 = 20_000;
/// A session quiet this long is over (and a turn still waiting on a tool).
const OPEN_SESSION_MS: i64 = 30 * 60_000;
/// Transcripts written to within this long are followed.
const RECENT: Duration = Duration::from_secs(36 * 3600);

/// The Claude Code tool a WorkBuddy call is; None for its own bookkeeping.
fn claude_tool(name: &str) -> Option<&str> {
    match name {
        "Bash" | "Read" | "Write" | "Edit" | "MultiEdit" | "Glob" | "Grep" | "WebFetch" | "WebSearch" | "TodoWrite" | "Skill" | "NotebookEdit" => Some(name),
        "Task" | "Agent" => Some("Agent"),
        _ if name.starts_with("mcp__") => Some(name),
        _ => None,
    }
}

/// Every main transcript under `root`'s WorkBuddy folders, oldest path first.
pub fn files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for home in HOMES {
        let Ok(projects) = fs::read_dir(root.join(home).join("projects")) else { continue };
        for dir in projects.flatten().map(|e| e.path()).filter(|p| p.is_dir()) {
            let Ok(entries) = fs::read_dir(&dir) else { continue };
            out.extend(entries.flatten().map(|e| e.path()).filter(|p| p.is_file() && p.extension().is_some_and(|e| e == "jsonl")));
        }
    }
    out.sort();
    out
}

/// The transcript of session `sid` (the file is named after it).
pub fn session_file(root: &Path, sid: &str) -> Option<PathBuf> {
    if sid.is_empty() || !sid.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return None;
    }
    files(root).into_iter().find(|p| p.file_stem().and_then(|n| n.to_str()) == Some(sid))
}

/// The title WorkBuddy gave session `sid` and its folder's name, for the
/// report window only (titles.rs).
pub fn meta(root: &Path, sid: &str) -> Meta {
    let mut m = Meta::default();
    let Some(path) = session_file(root, sid) else { return m };
    for line in fs::read_to_string(path).unwrap_or_default().lines().filter(|l| l.contains("\"ai-title\"") || l.contains("\"cwd\"")) {
        let Ok(e) = serde_json::from_str::<Value>(line) else { continue };
        if m.project.is_none() {
            m.project = e.get("cwd").and_then(Value::as_str).and_then(|c| Path::new(c).file_name()?.to_str()).map(str::to_string);
        }
        if e.get("type").and_then(Value::as_str) == Some("ai-title") {
            m.title = e.get("aiTitle").and_then(Value::as_str).filter(|t| !t.trim().is_empty()).map(str::to_string);
        }
    }
    m
}

/// One transcript read as WorkBuddy writes it: whole for the history
/// (`file_events`) or followed (`WbTail`).
#[derive(Default)]
pub struct WbSession {
    sid: Option<String>,
    cwd: String,
    /// The open turn and whether its prompt event went out.
    turn: Option<(String, bool)>,
    /// Tool calls waiting for their result: name and arguments.
    pending: HashMap<String, (String, Value)>,
    first_ts: Option<i64>,
    last_ts: i64,
    /// The last item was the model's answer with nothing left to run.
    answered: bool,
    last_prompt: Option<(String, u32)>,
    ended: bool,
    /// The start of a line still being written.
    carry: String,
}

impl WbSession {
    fn event(seed: &str, ts: i64, kind: Kind, sid: &str) -> Event {
        let mut ev = bf_event(&format!("wb\0{seed}"), ts, kind, sid);
        ev.payload.origin = Some(Source::WorkBuddy);
        ev
    }

    /// The events in newly read text, none at or after `cutoff`.
    pub fn text(&mut self, text: &str, cutoff: i64, paths: &Paths) -> Vec<Event> {
        let mut buf = std::mem::take(&mut self.carry);
        buf.push_str(text);
        let mut out = Vec::new();
        let mut lines: Vec<&str> = buf.split('\n').collect();
        let last = lines.pop().unwrap_or("");
        for l in lines {
            out.extend(self.line(l, cutoff, paths));
        }
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
        if !matches!(ty.as_str(), "message" | "function_call" | "function_call_result") {
            return out;
        }
        if self.sid.is_none() {
            self.sid = e.get("sessionId").and_then(Value::as_str).map(str::to_string);
        }
        if self.cwd.is_empty() {
            self.cwd = s(&e, "cwd");
        }
        let Some(sid) = self.sid.clone() else { return out };
        let Some(ts) = e.get("timestamp").and_then(Value::as_i64) else { return out };
        if ts >= cutoff {
            return out;
        }
        if self.first_ts.is_none() {
            self.first_ts = Some(ts);
            let mut ev = WbSession::event(&format!("{sid}\0start"), ts, Kind::SessionStart, &sid);
            ev.payload.session_source = Some("startup".into());
            out.push(ev);
        }
        self.last_ts = self.last_ts.max(ts);
        let id = s(&e, "id");
        match ty.as_str() {
            "message" if s(&e, "role") == "user" => {
                if e.pointer("/providerData/startsNewUserRequest").and_then(Value::as_bool) != Some(true) {
                    return out;
                }
                self.close(ts, &mut out);
                self.turn = Some((format!("wb_{}", short_hash(&format!("{sid}\0{id}"))), false));
                let text: String = e
                    .get("content")
                    .and_then(Value::as_array)
                    .map(|c| c.iter().filter_map(|b| b.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n"))
                    .unwrap_or_default();
                self.prompt(&sid, ts, Some(&text), &mut out);
            }
            "message" => {
                self.prompt(&sid, ts, None, &mut out);
                self.answered = self.pending.is_empty();
            }
            "function_call" => {
                self.prompt(&sid, ts, None, &mut out);
                self.answered = false;
                let name = s(&e, "name");
                let args = e.get("arguments").and_then(Value::as_str).and_then(|a| serde_json::from_str(a).ok()).unwrap_or(Value::Null);
                if claude_tool(&name) == Some("Agent") {
                    let mut ev = WbSession::event(&format!("{sid}\0{id}\0substart"), ts, Kind::SubagentStart, &sid);
                    ev.turn_id = self.turn.as_ref().map(|t| t.0.clone());
                    out.push(ev);
                }
                self.pending.insert(s(&e, "callId"), (name, args));
            }
            _ => {
                let Some((name, args)) = self.pending.remove(&s(&e, "callId")) else { return out };
                let Some(tool) = claude_tool(&name).map(str::to_string) else { return out };
                let turn = self.turn.as_ref().map(|t| t.0.clone());
                if tool == "Agent" {
                    let mut ev = WbSession::event(&format!("{sid}\0{id}\0substop"), ts, Kind::SubagentStop, &sid);
                    ev.turn_id = turn.clone();
                    out.push(ev);
                }
                let failed = !matches!(s(&e, "status").as_str(), "completed" | "");
                let hook = json!({
                    "hook_event_name": if failed { "PostToolUseFailure" } else { "PostToolUse" },
                    "session_id": sid, "cwd": self.cwd, "tool_name": tool, "tool_input": args,
                });
                let env = CaptureEnv { paths, now_ms: 0, nonce: String::new(), git_lookup: false };
                if let Some(mut ev) = from_claude_hook(&hook, b"", &env) {
                    let fresh = WbSession::event(&format!("{sid}\0{id}\0tool"), ts, Kind::Tool, &sid);
                    ev.id = fresh.id;
                    ev.ts = fresh.ts;
                    ev.source = Source::Backfill;
                    ev.payload.origin = Some(Source::WorkBuddy);
                    ev.turn_id = turn;
                    out.push(ev);
                }
            }
        }
        out
    }

    /// The open turn's prompt event, once.
    fn prompt(&mut self, sid: &str, ts: i64, text: Option<&str>, out: &mut Vec<Event>) {
        let Some((tid, sent)) = self.turn.as_mut() else { return };
        if *sent {
            return;
        }
        *sent = true;
        let tid = tid.clone();
        let mut ev = WbSession::event(&format!("{tid}\0prompt"), ts, Kind::Prompt, sid);
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
                origin: Some(Source::WorkBuddy),
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
        self.answered = false;
        let (Some((tid, sent)), Some(sid)) = (self.turn.take(), self.sid.clone()) else { return };
        if sent {
            let mut ev = WbSession::event(&format!("{tid}\0end"), ts, Kind::TurnEnd, &sid);
            ev.turn_id = Some(tid);
            out.push(ev);
        }
        self.pending.clear();
    }

    /// What ends with nothing written before `now`: an answered turn after
    /// ANSWERED_MS, any turn and then the session after OPEN_SESSION_MS.
    pub fn finish(&mut self, now: i64) -> Vec<Event> {
        let mut out = Vec::new();
        let Some(sid) = self.sid.clone().filter(|_| self.first_ts.is_some()) else { return out };
        let quiet = now - self.last_ts;
        if (self.answered && quiet > ANSWERED_MS) || quiet > OPEN_SESSION_MS {
            self.close(self.last_ts, &mut out);
        }
        if quiet > OPEN_SESSION_MS && !self.ended {
            self.ended = true;
            let mut ev = WbSession::event(&format!("{sid}\0end"), self.last_ts, Kind::SessionEnd, &sid);
            ev.payload.reason = Some("other".into());
            out.push(ev);
        }
        out
    }
}

/// Events for one transcript, read whole.
pub fn file_events(path: &Path, cutoff: i64, paths: &Paths) -> Vec<Event> {
    let mut s = WbSession::default();
    let mut out = s.text(&fs::read_to_string(path).unwrap_or_default(), cutoff, paths);
    out.extend(s.finish(cutoff));
    out
}

/// Imports every transcript before `cutoff`, in one transaction.
pub fn import(p: &mut Processor, paths: &Paths, root: &Path, cutoff: i64) -> Result<Report> {
    let started = Instant::now();
    let logs = files(root);
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

/// Follows the transcripts WorkBuddy is writing.
pub struct WbTail {
    root: PathBuf,
    /// Each followed transcript: how far it has been read, and its reader.
    files: HashMap<PathBuf, (u64, WbSession)>,
}

impl WbTail {
    pub fn new(root: &Path) -> WbTail {
        WbTail { root: root.to_path_buf(), files: HashMap::new() }
    }

    /// The events in every line written since the last poll, oldest first.
    /// The first poll reads recent transcripts from the top; what already
    /// counted comes back with the same ids and is ignored.
    pub fn poll(&mut self, paths: &Paths, now_ms: i64) -> Vec<Event> {
        let horizon = SystemTime::now() - RECENT;
        let recent = |p: &Path| fs::metadata(p).and_then(|m| m.modified()).is_ok_and(|t| t >= horizon);
        for p in files(&self.root) {
            if !self.files.contains_key(&p) && recent(&p) {
                self.files.insert(p, (0, WbSession::default()));
            }
        }
        let mut out = Vec::new();
        for (path, (offset, s)) in self.files.iter_mut() {
            let len = fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            if len > *offset {
                let mut buf = Vec::new();
                let read = fs::File::open(path).and_then(|mut f| {
                    f.seek(SeekFrom::Start(*offset))?;
                    f.take(len - *offset).read_to_end(&mut buf)
                });
                // Whole lines only: WorkBuddy may be half way through one.
                if let (Ok(_), Some(last)) = (read, buf.iter().rposition(|&b| b == b'\n')) {
                    out.extend(s.text(&String::from_utf8_lossy(&buf[..=last]), i64::MAX, paths));
                    *offset += last as u64 + 1;
                }
            }
            out.extend(s.finish(now_ms));
        }
        self.files.retain(|p, _| recent(p));
        out.sort_by_key(|e| e.ts_ms().unwrap_or(0));
        out
    }
}
