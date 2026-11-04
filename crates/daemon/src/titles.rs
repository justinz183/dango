//! Session titles and project names (DESIGN.md §4), read from the Claude
//! Code transcript of a session: the title Claude Code gave it (custom
//! over AI-generated) and the folder name of its working directory. Codex
//! sessions get the thread name Codex keeps in ~/.codex/session_index.jsonl
//! and the folder from their rollout (~/.codex sits next to ~/.claude).
//! Cached in session_meta. Local only: never uploaded, off share cards
//! unless the user asks for names.

use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;

use crate::ingest::Result;

pub const TITLE_MAX: usize = 60;
pub const PROJECT_MAX: usize = 40;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Meta {
    pub title: Option<String>,
    pub project: Option<String>,
}

fn clean(s: &str, max: usize) -> Option<String> {
    let t: String = s.chars().filter(|c| !c.is_control()).collect::<String>().trim().chars().take(max).collect();
    (!t.is_empty()).then_some(t)
}

/// The transcript for a session, wherever Claude Code filed it.
pub fn transcript_for(claude_dir: &Path, sid: &str) -> Option<PathBuf> {
    if sid.is_empty() || sid.contains(['/', '\\']) {
        return None;
    }
    let projects = fs::read_dir(claude_dir.join("projects")).ok()?;
    projects.flatten().map(|e| e.path().join(format!("{sid}.jsonl"))).find(|p| p.is_file())
}

/// Reads the title and project of one transcript. Only lines that can carry
/// them are parsed; message content is never looked at.
pub fn read(path: &Path) -> Meta {
    let mut m = Meta::default();
    let Ok(f) = fs::File::open(path) else { return m };
    let (mut ai, mut custom) = (None, None);
    // The project is the folder the session spent most of its turns in; the
    // home folder (where sessions start by default) says nothing about the
    // work, so it never counts.
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    let mut cwds: HashMap<String, usize> = HashMap::new();
    for line in BufReader::new(f).lines().map_while(|l| l.ok()) {
        let wants_title = line.contains("\"type\":\"ai-title\"") || line.contains("\"type\":\"custom-title\"");
        let has_cwd = line.contains("\"cwd\":");
        if !wants_title && !has_cwd {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        match v.get("type").and_then(Value::as_str) {
            Some("ai-title") => ai = v.get("aiTitle").and_then(Value::as_str).and_then(|s| clean(s, TITLE_MAX)),
            Some("custom-title") => custom = v.get("customTitle").and_then(Value::as_str).and_then(|s| clean(s, TITLE_MAX)),
            Some("user") | Some("assistant") => {
                if let Some(cwd) = v.get("cwd").and_then(Value::as_str) {
                    if home.as_deref() != Some(Path::new(cwd)) {
                        *cwds.entry(cwd.to_string()).or_default() += 1;
                    }
                }
            }
            _ => {}
        }
    }
    m.project = cwds
        .into_iter()
        .max_by_key(|(c, n)| (*n, std::cmp::Reverse(c.clone())))
        .and_then(|(c, _)| Path::new(&c).file_name().and_then(|n| n.to_str()).and_then(|n| clean(n, PROJECT_MAX)));
    m.title = custom.or(ai);
    m
}

/// A Codex session's title (the newest thread name Codex gave it) and
/// project (the folder most of its turns ran in, never the home folder).
/// Only the index and the rollout's context lines are parsed.
pub fn codex(codex_dir: &Path, sid: &str) -> Meta {
    let mut m = Meta::default();
    if sid.is_empty() || sid.contains(['/', '\\']) {
        return m;
    }
    if let Ok(f) = fs::File::open(codex_dir.join("session_index.jsonl")) {
        for line in BufReader::new(f).lines().map_while(|l| l.ok()).filter(|l| l.contains(sid)) {
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                if v.get("id").and_then(Value::as_str) == Some(sid) {
                    if let Some(t) = v.get("thread_name").and_then(Value::as_str).and_then(|s| clean(s, TITLE_MAX)) {
                        m.title = Some(t);
                    }
                }
            }
        }
    }
    let Some(path) = codex_rollout(codex_dir, sid) else { return m };
    let Ok(f) = fs::File::open(path) else { return m };
    let home = std::env::var("HOME").ok().map(PathBuf::from);
    let mut cwds: HashMap<String, usize> = HashMap::new();
    for line in BufReader::new(f).lines().map_while(|l| l.ok()) {
        if !(line.contains("\"type\":\"turn_context\"") || line.contains("\"type\":\"session_meta\"")) {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        if !matches!(v.get("type").and_then(Value::as_str), Some("turn_context") | Some("session_meta")) {
            continue;
        }
        if let Some(cwd) = v["payload"].get("cwd").and_then(Value::as_str) {
            if home.as_deref() != Some(Path::new(cwd)) {
                *cwds.entry(cwd.to_string()).or_default() += 1;
            }
        }
    }
    m.project = cwds
        .into_iter()
        .max_by_key(|(c, n)| (*n, std::cmp::Reverse(c.clone())))
        .and_then(|(c, _)| Path::new(&c).file_name().and_then(|n| n.to_str()).and_then(|n| clean(n, PROJECT_MAX)));
    m
}

/// The rollout file of a Codex session: sessions/YYYY/MM/DD/rollout-…-<id>.jsonl.
fn codex_rollout(codex_dir: &Path, sid: &str) -> Option<PathBuf> {
    let tail = format!("{sid}.jsonl");
    let list = |p: &Path| -> Vec<PathBuf> { fs::read_dir(p).map(|d| d.flatten().map(|e| e.path()).collect()).unwrap_or_default() };
    for y in list(&codex_dir.join("sessions")) {
        for mo in list(&y) {
            for d in list(&mo) {
                if let Some(f) = list(&d).into_iter().find(|f| f.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with(&tail))) {
                    return Some(f);
                }
            }
        }
    }
    None
}

/// The cached meta for a session, looking the transcript up when nothing
/// is cached yet or an open session still has no title.
pub fn cached(conn: &Connection, claude_dir: &Path, sid: &str, ended: bool) -> Result<Meta> {
    let now = chrono::Utc::now().timestamp_millis();
    let row: Option<(Option<String>, Option<String>, i64)> = conn
        .query_row("SELECT project, title, looked_up_at FROM session_meta WHERE session_id = ?1", [sid], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .optional()?;
    if let Some((project, title, at)) = row {
        // A finished session with nothing found is looked at again once a
        // day: its tool may name it later (Codex renames threads), or the
        // lookup may have learned a new place to look.
        if title.is_some() || (ended && (project.is_some() || now - at < 24 * 3600 * 1000)) {
            return Ok(Meta { title, project });
        }
    }
    let m = match transcript_for(claude_dir, sid) {
        Some(p) => read(&p),
        None => claude_dir.parent().map(|home| codex(&home.join(".codex"), sid)).unwrap_or_default(),
    };
    conn.execute(
        "INSERT INTO session_meta (session_id, project, title, looked_up_at) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(session_id) DO UPDATE SET project = excluded.project, title = excluded.title, looked_up_at = excluded.looked_up_at",
        params![sid, m.project, m.title, now],
    )?;
    Ok(m)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_title_and_project_without_touching_messages() {
        let dir = std::env::temp_dir().join(format!("sc-titles-{}", std::process::id()));
        let proj = dir.join("projects").join("-Users-me-app");
        fs::create_dir_all(&proj).unwrap();
        let p = proj.join("abc.jsonl");
        fs::write(
            &p,
            concat!(
                "{\"type\":\"user\",\"cwd\":\"/Users/me/tmp\",\"message\":{\"content\":\"secret prompt\"}}\n",
                "{\"type\":\"ai-title\",\"aiTitle\":\"修复登录\",\"sessionId\":\"abc\"}\n",
                "{\"type\":\"assistant\",\"cwd\":\"/Users/me/app\"}\n",
                "{\"type\":\"user\",\"cwd\":\"/Users/me/app\",\"message\":{\"content\":\"x\"}}\n",
                "{\"type\":\"custom-title\",\"customTitle\":\"  登录重构\\u0007 \",\"sessionId\":\"abc\"}\n",
            ),
        )
        .unwrap();
        assert_eq!(transcript_for(&dir, "abc").as_deref(), Some(p.as_path()));
        assert_eq!(read(&p), Meta { title: Some("登录重构".into()), project: Some("app".into()) });
        assert!(transcript_for(&dir, "../abc").is_none());
        assert!(transcript_for(&dir, "nope").is_none());
    }

    #[test]
    fn codex_sessions_get_their_thread_name_and_folder() {
        let dir = std::env::temp_dir().join(format!("sc-codex-titles-{}", std::process::id()));
        let day = dir.join("sessions/2026/10/31");
        fs::create_dir_all(&day).unwrap();
        fs::write(
            dir.join("session_index.jsonl"),
            concat!(
                "{\"id\":\"s1\",\"thread_name\":\"Old name\",\"updated_at\":\"2026-10-31T01:00:00Z\"}\n",
                "{\"id\":\"other\",\"thread_name\":\"Not this\",\"updated_at\":\"2026-10-31T01:00:00Z\"}\n",
                "{\"id\":\"s1\",\"thread_name\":\"修复 Codex 计数\",\"updated_at\":\"2026-10-31T02:00:00Z\"}\n",
            ),
        )
        .unwrap();
        fs::write(
            day.join("rollout-2026-10-31T01-46-15-s1.jsonl"),
            concat!(
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"s1\",\"cwd\":\"/Users/me/tmp\"}}\n",
                "{\"type\":\"response_item\",\"payload\":{\"text\":\"\\\"type\\\":\\\"turn_context\\\" cwd /Users/me/secret\"}}\n",
                "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/Users/me/dango\"}}\n",
                "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/Users/me/dango\"}}\n",
            ),
        )
        .unwrap();
        assert_eq!(codex(&dir, "s1"), Meta { title: Some("修复 Codex 计数".into()), project: Some("dango".into()) });
        assert_eq!(codex(&dir, "nope"), Meta::default());
        assert_eq!(codex(&dir, "../s1"), Meta::default());
    }
}
