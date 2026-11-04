//! Claude Code without hooks: the daemon follows Claude Code's own
//! transcripts (~/.claude/projects/<project>/<session>.jsonl and the
//! session's subagents/*.jsonl) while they are written, through the same
//! reader as backfill, so a fresh install needs nothing set up or trusted
//! inside Claude Code. An event has the same id whether it was followed
//! here or backfilled, so it counts once.
//!
//! What the hooks would say right away, a running Claude Code also writes
//! in ~/.claude/sessions/<pid>.json: whether its session is busy or idle,
//! and whether a dialog (a permission prompt among them) waits for the
//! person. When that file says idle after the transcript's last line, the
//! turn ends at once; while it says something waits, the session is
//! waiting for you. It is Claude Code's own file, not a documented
//! interface: anything missing or unreadable, or a process no longer
//! running, means "not known", and the transcript rules decide alone.
//!
//! When Dango's hooks are installed (the plugin, or a `dango hook` command
//! in ~/.claude/settings.json) they report live instead and this stays off,
//! and a session the hooks have reported is never followed (server.rs drops
//! it), so nothing is counted twice. Lines are read and dropped; only the
//! events (ids, numbers) are kept.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use dango_core::event::{Event, Kind, Source};
use serde_json::Value;

use crate::backfill::{bf_event, Transcript};
use crate::paths::Paths;

/// Transcripts written to within this long are followed.
const RECENT: Duration = Duration::from_secs(36 * 3600);
/// How often settings.json is looked at again for Dango's hooks.
const HOOKS_EVERY: Duration = Duration::from_secs(60);

pub struct ClaudeTail {
    claude_dir: PathBuf,
    /// Each followed file: how far it has been read, and its reader.
    files: HashMap<PathBuf, (u64, Transcript)>,
    hooks: Option<(Instant, bool)>,
    /// Waits already reported: (session, when its status changed).
    asked: HashSet<(String, i64)>,
}

/// A running Claude Code's word on its session.
#[derive(Debug, Clone, PartialEq)]
pub struct Live {
    /// Not working: waiting for the next prompt.
    pub idle: bool,
    /// When the status last changed (ms).
    pub at: i64,
    /// A dialog waits for the person (a permission prompt, a question).
    pub waiting: bool,
}

/// What each running Claude Code says about its session, by session id.
/// A file whose process is gone says nothing (its status may be stale).
pub fn live_sessions(claude_dir: &Path) -> HashMap<String, Live> {
    let mut out: HashMap<String, Live> = HashMap::new();
    let Ok(dir) = fs::read_dir(claude_dir.join("sessions")) else { return out };
    for p in dir.flatten().map(|e| e.path()).filter(|p| p.extension().and_then(|e| e.to_str()) == Some("json")) {
        let Ok(v) = fs::read_to_string(&p).map_err(|_| ()).and_then(|t| serde_json::from_str::<Value>(&t).map_err(|_| ())) else { continue };
        let (Some(sid), Some(status)) = (v["sessionId"].as_str(), v["status"].as_str()) else { continue };
        let pid = v["pid"].as_i64().unwrap_or(0);
        if pid <= 0 || pid > i32::MAX as i64 || !alive(pid as i32) {
            continue;
        }
        let at = v["statusUpdatedAt"].as_i64().or_else(|| v["updatedAt"].as_i64()).unwrap_or(0);
        let idle = matches!(status, "idle" | "shell");
        let waiting = !idle && v["waitingFor"].as_str().is_some_and(|w| !w.trim().is_empty());
        let live = Live { idle, at, waiting };
        // A session resumed in a second process: the newer word counts.
        if out.get(sid).is_none_or(|old| old.at <= at) {
            out.insert(sid.to_string(), live);
        }
    }
    out
}

/// Whether a process is still running.
fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 sends nothing; it only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

impl ClaudeTail {
    pub fn new(claude_dir: &Path) -> ClaudeTail {
        ClaudeTail { claude_dir: claude_dir.to_path_buf(), files: HashMap::new(), hooks: None, asked: HashSet::new() }
    }

    /// Whether Dango's own hooks report Claude Code, so following is off.
    pub fn hooks_installed(&mut self) -> bool {
        if let Some((at, on)) = self.hooks {
            if at.elapsed() < HOOKS_EVERY {
                return on;
            }
        }
        let on = hooked(&self.claude_dir);
        self.hooks = Some((Instant::now(), on));
        on
    }

    /// The events in every line Claude Code has finished writing since the
    /// last poll, oldest first, and the turns and sessions that have closed
    /// by `now_ms`. The first poll reads recent files from the top; what was
    /// already counted comes back with the same ids and is ignored.
    pub fn poll(&mut self, paths: &Paths, now_ms: i64) -> Vec<Event> {
        let horizon = SystemTime::now() - RECENT;
        let recent = |p: &Path| fs::metadata(p).and_then(|m| m.modified()).is_ok_and(|t| t >= horizon);
        for (p, parent) in transcripts(&self.claude_dir) {
            if !self.files.contains_key(&p) && recent(&p) {
                let t = Transcript::new(parent.as_deref());
                self.files.insert(p, (0, t));
            }
        }
        let live = live_sessions(&self.claude_dir);
        let mut out = Vec::new();
        for (path, (offset, t)) in self.files.iter_mut() {
            let len = fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            if len > *offset {
                let mut buf = Vec::new();
                let read = fs::File::open(path).and_then(|mut f| {
                    f.seek(SeekFrom::Start(*offset))?;
                    f.take(len - *offset).read_to_end(&mut buf)
                });
                // Whole lines only: Claude Code may be half way through one.
                if let (Ok(_), Some(last)) = (read, buf.iter().rposition(|&b| b == b'\n')) {
                    for line in buf[..last].split(|&b| b == b'\n') {
                        if let Ok(s) = std::str::from_utf8(line) {
                            out.extend(t.line(s, i64::MAX, paths));
                        }
                    }
                    *offset += last as u64 + 1;
                }
            }
            if let Some((sid, l)) = t.session().and_then(|sid| live.get(sid).map(|l| (sid.to_string(), l))) {
                if l.idle && l.at >= t.last_ts() {
                    // Idle since the last line: the turn is over, no need to wait.
                    out.extend(t.end_turn());
                } else if l.waiting && t.turn_open() && self.asked.insert((sid.clone(), l.at)) {
                    // Waiting for the person: what the hooks' permission prompt says.
                    let mut ev = bf_event(&format!("{sid}\0{}\0waiting", l.at), l.at.max(t.last_ts()), Kind::Notification, &sid);
                    ev.payload.origin = Some(Source::ClaudeCode);
                    ev.payload.notification_type = Some("permission_prompt".into());
                    out.push(ev);
                }
            }
            out.extend(t.finish(now_ms));
        }
        self.files.retain(|p, _| recent(p));
        self.asked.retain(|(_, at)| now_ms - *at < 24 * 3600 * 1000);
        // Stable: a file's own order holds for equal times.
        out.sort_by_key(|e| e.ts_ms().unwrap_or(0));
        out
    }
}

/// Every transcript and subagent transcript under projects/, with the
/// parent session of a subagent file. Only names are listed.
fn transcripts(claude_dir: &Path) -> Vec<(PathBuf, Option<String>)> {
    let list = |p: &Path| -> Vec<PathBuf> { fs::read_dir(p).map(|d| d.flatten().map(|e| e.path()).collect()).unwrap_or_default() };
    let jsonl = |p: &Path| p.extension().and_then(|e| e.to_str()) == Some("jsonl");
    let mut out = Vec::new();
    for proj in list(&claude_dir.join("projects")).into_iter().filter(|p| p.is_dir()) {
        for p in list(&proj) {
            if jsonl(&p) {
                out.push((p, None));
            } else if p.is_dir() {
                let parent = p.file_name().and_then(|n| n.to_str()).map(str::to_string);
                out.extend(list(&p.join("subagents")).into_iter().filter(|s| jsonl(s)).map(|s| (s, parent.clone())));
            }
        }
    }
    out
}

/// Dango's hooks in Claude Code's user settings: the plugin enabled, or a
/// `dango hook` (or old `shadowcorp hook`) command among the hooks.
pub fn hooked(claude_dir: &Path) -> bool {
    let Ok(s) = fs::read_to_string(claude_dir.join("settings.json")) else { return false };
    let Ok(v) = serde_json::from_str::<Value>(&s) else { return false };
    let plugin = v["enabledPlugins"]
        .as_object()
        .is_some_and(|m| m.iter().any(|(k, on)| (k.starts_with("dango@") || k.starts_with("shadowcorp@")) && on.as_bool() == Some(true)));
    let hooks = v["hooks"].to_string();
    plugin || hooks.contains("dango hook") || hooks.contains("shadowcorp hook")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hooks_are_found_in_settings() {
        let dir = std::env::temp_dir().join(format!("sc-claude-hooks-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        assert!(!hooked(&dir), "no settings, no hooks");
        fs::write(dir.join("settings.json"), r#"{"enabledPlugins":{"dango@dango":true}}"#).unwrap();
        assert!(hooked(&dir));
        fs::write(dir.join("settings.json"), r#"{"enabledPlugins":{"dango@dango":false,"other@x":true}}"#).unwrap();
        assert!(!hooked(&dir), "a disabled plugin reports nothing");
        fs::write(dir.join("settings.json"), r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/dango hook"}]}]}}"#).unwrap();
        assert!(hooked(&dir));
        fs::write(dir.join("settings.json"), "not json").unwrap();
        assert!(!hooked(&dir));
    }
}
