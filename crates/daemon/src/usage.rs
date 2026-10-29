//! Model usage per turn, read from the agents' own logs (docs/DESIGN.md
//! v5): every Claude Code assistant message carries its model and token
//! usage, every Codex response a `token_usage_record`. Records are matched
//! to turns by time, so a session's sub-agents (and Codex's reviewer
//! threads) count toward the turn they ran in. Each finished turn gets one
//! `usage` event; only counts leave this module.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use rusqlite::Connection;
use serde_json::Value;
use shadowcorp_core::event::{Event, Kind, Source};
use shadowcorp_core::pricing::{price_key, Tokens};

use crate::backfill::{codex_files, ts_of};
use crate::ingest::{Processor, Result};
use crate::paths::short_hash;
use crate::titles;

/// A record this long after a turn's end still belongs to it (logs are
/// written a moment after the hook fires).
const GRACE_MS: i64 = 5_000;

/// A finished turn waiting for its usage.
#[derive(Debug, Clone)]
pub struct Pending {
    pub session: String,
    pub source: String,
    pub turn: String,
    pub start: i64,
    pub end: i64,
}

/// Finished turns without usage that ended before `before`, oldest first.
pub fn pending(conn: &Connection, before: i64, limit: usize) -> Result<Vec<Pending>> {
    let mut st = conn.prepare(
        "SELECT t.session_id, s.source, t.id, t.started_at, t.ended_at FROM turns t JOIN sessions s ON s.id = t.session_id
         WHERE t.ended_at IS NOT NULL AND t.ended_at < ?1 AND t.cost_done = 0 ORDER BY t.ended_at LIMIT ?2",
    )?;
    let rows = st.query_map(rusqlite::params![before, limit as i64], |r| {
        Ok(Pending { session: r.get(0)?, source: r.get(1)?, turn: r.get(2)?, start: r.get(3)?, end: r.get(4)? })
    })?;
    Ok(rows.flatten().collect())
}

/// The window a record at `ts` belongs to.
fn window(turns: &[&Pending], ts: i64) -> Option<usize> {
    turns.iter().position(|t| ts >= t.start && ts <= t.end + GRACE_MS)
}

fn lines(path: &Path) -> impl Iterator<Item = String> {
    fs::File::open(path).into_iter().flat_map(|f| BufReader::new(f).lines().map_while(|l| l.ok()))
}

fn n(v: &Value, k: &str) -> u64 {
    v.get(k).and_then(Value::as_u64).unwrap_or(0)
}

/// Claude Code: the session transcript and its sub-agents' transcripts.
fn claude(claude_dir: &Path, sid: &str, turns: &[&Pending], out: &mut [BTreeMap<String, Tokens>]) {
    let Some(main) = titles::transcript_for(claude_dir, sid) else { return };
    let mut files = vec![main.clone()];
    if let Ok(rd) = fs::read_dir(main.with_extension("").join("subagents")) {
        files.extend(rd.flatten().map(|e| e.path()).filter(|p| p.extension().and_then(|e| e.to_str()) == Some("jsonl")));
    }
    // One API response is written as several lines sharing its message id.
    let mut seen = HashSet::new();
    for f in files {
        for line in lines(&f).filter(|l| l.contains("\"usage\"")) {
            let Ok(e) = serde_json::from_str::<Value>(&line) else { continue };
            let Some(m) = e.get("message").filter(|_| e.get("type").and_then(Value::as_str) == Some("assistant")) else { continue };
            let (Some(model), Some(u)) = (m.get("model").and_then(Value::as_str), m.get("usage")) else { continue };
            if model.starts_with('<') || !seen.insert(m.get("id").and_then(Value::as_str).unwrap_or("").to_string()) {
                continue;
            }
            let Some(i) = ts_of(&e).and_then(|ts| window(turns, ts)) else { continue };
            let cc = u.get("cache_creation");
            let (w5, w1) = match cc {
                Some(c) => (n(c, "ephemeral_5m_input_tokens"), n(c, "ephemeral_1h_input_tokens")),
                None => (n(u, "cache_creation_input_tokens"), 0),
            };
            let t = Tokens { input: n(u, "input_tokens"), cache_write: w5, cache_write_long: w1, cache_read: n(u, "cache_read_input_tokens"), output: n(u, "output_tokens") };
            let mut key = price_key(model, t.input + w5 + w1 + t.cache_read);
            if u.get("speed").and_then(Value::as_str) == Some("fast") {
                key += "@fast";
            }
            out[i].entry(key).or_default().add(&t);
        }
    }
}

/// Codex rollout files by session id.
fn codex_index(codex_dir: &Path) -> HashMap<String, Vec<PathBuf>> {
    let mut idx: HashMap<String, Vec<PathBuf>> = HashMap::new();
    for f in codex_files(codex_dir) {
        let meta = lines(&f).take(5).find_map(|l| {
            let e: Value = serde_json::from_str(&l).ok()?;
            (e.get("type")?.as_str()? == "session_meta").then_some(e)
        });
        let sid = meta.as_ref().and_then(|e| {
            let p = e.get("payload")?;
            p.get("session_id").or_else(|| p.get("id"))?.as_str().map(str::to_string)
        });
        if let Some(sid) = sid {
            idx.entry(sid).or_default().push(f);
        }
    }
    idx
}

/// Codex: every rollout of the session, reviewer threads included. Newer
/// rollouts log a `token_usage_record` per response; older ones only a
/// `token_count` event whose `last_token_usage` is the same per-response
/// usage, used when a file has no records.
fn codex(files: &[PathBuf], turns: &[&Pending], out: &mut [BTreeMap<String, Tokens>]) {
    for f in files {
        let mut model = String::new();
        let (mut records, mut counts) = (Vec::new(), Vec::new());
        for line in lines(f).filter(|l| l.contains("token_usage_record") || l.contains("\"token_count\"") || l.contains("\"turn_context\"")) {
            let Ok(e) = serde_json::from_str::<Value>(&line) else { continue };
            let p = e.get("payload").cloned().unwrap_or(Value::Null);
            let usage = match (e.get("type").and_then(Value::as_str), p.get("type").and_then(Value::as_str)) {
                (Some("turn_context"), _) => {
                    model = p.get("model").and_then(Value::as_str).unwrap_or("").to_string();
                    continue;
                }
                (Some("token_usage_record"), _) => p.get("usage").cloned().map(|u| (true, u)),
                (Some("event_msg"), Some("token_count")) => p.get("info").and_then(|i| i.get("last_token_usage")).cloned().map(|u| (false, u)),
                _ => None,
            };
            let (Some((record, u)), Some(i)) = (usage, ts_of(&e).and_then(|ts| window(turns, ts))) else { continue };
            if !model.is_empty() {
                if record { records.push((i, model.clone(), u)) } else { counts.push((i, model.clone(), u)) }
            }
        }
        for (i, model, u) in if records.is_empty() { counts } else { records } {
            // Cached input is part of input; reasoning is part of output.
            let (input, cached, written) = (n(&u, "input_tokens"), n(&u, "cached_input_tokens"), n(&u, "cache_write_input_tokens"));
            let t = Tokens { input: input.saturating_sub(cached + written), cache_write: written, cache_write_long: 0, cache_read: cached, output: n(&u, "output_tokens") };
            out[i].entry(price_key(&model, input)).or_default().add(&t);
        }
    }
}

/// One `usage` event per pending turn, from the logs (no database access,
/// so the daemon can read while it serves requests). A turn whose logs are
/// gone gets an empty event, so it is not looked at again.
pub fn read(claude_dir: &Path, codex_dir: &Path, pending: &[Pending]) -> Vec<Event> {
    let mut by_session: BTreeMap<(&str, &str), Vec<&Pending>> = BTreeMap::new();
    for p in pending {
        by_session.entry((p.session.as_str(), p.source.as_str())).or_default().push(p);
    }
    let index = if pending.iter().any(|p| p.source == "codex") { codex_index(codex_dir) } else { HashMap::new() };
    let mut events = Vec::new();
    for ((sid, source), turns) in by_session {
        let mut out = vec![BTreeMap::new(); turns.len()];
        if source == "codex" {
            codex(index.get(sid).map(Vec::as_slice).unwrap_or(&[]), &turns, &mut out);
        } else {
            claude(claude_dir, sid, &turns, &mut out);
        }
        for (t, tokens) in turns.into_iter().zip(out) {
            let mut ev = Event::new(format!("use_{}", short_hash(&t.turn)), t.end, Source::Backfill, Kind::Usage);
            ev.session_id = Some(t.session.clone());
            ev.turn_id = Some(t.turn.clone());
            ev.payload.origin = Some(if source == "codex" { Source::Codex } else { Source::ClaudeCode });
            ev.payload.tokens = tokens;
            events.push(ev);
        }
    }
    events
}

/// Prices every turn that ended before `before` and has no usage yet.
pub fn fill(p: &mut Processor, claude_dir: &Path, codex_dir: &Path, before: i64, limit: usize) -> Result<usize> {
    let todo = pending(&p.conn, before, limit)?;
    let events = read(claude_dir, codex_dir, &todo);
    apply(p, &events)
}

/// Feeds usage events to the processor in one transaction.
pub fn apply(p: &mut Processor, events: &[Event]) -> Result<usize> {
    if events.is_empty() {
        return Ok(0);
    }
    p.begin()?;
    let mut n = 0;
    for ev in events {
        match p.handle(ev) {
            Ok(true) => n += 1,
            Ok(false) => {}
            Err(e) => eprintln!("shadowcorp: skipped usage {}: {e}", ev.id),
        }
    }
    p.commit()?;
    Ok(n)
}
