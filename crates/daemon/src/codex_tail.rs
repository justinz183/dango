//! Codex without hooks: the daemon follows Codex's own rollout files
//! (~/.codex/sessions/YYYY/MM/DD/*.jsonl) while Codex writes them, through
//! the same reader as backfill, so nothing has to be installed or trusted
//! in Codex. An event has the same id whether it was followed here or
//! backfilled, so it counts once. Lines are read and dropped; only the
//! events (ids, numbers) are kept.

use std::collections::HashMap;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use chrono::{Days, Local};
use dango_core::event::Event;

use crate::backfill::Rollout;
use crate::paths::Paths;

/// Rollouts written to within this long are followed: a session left open
/// overnight, or picked up again the next day.
const RECENT: Duration = Duration::from_secs(36 * 3600);

pub struct CodexTail {
    sessions: PathBuf,
    /// Each followed file: how far it has been read, and its reader.
    files: HashMap<PathBuf, (u64, Rollout)>,
}

impl CodexTail {
    pub fn new(codex_dir: &Path) -> CodexTail {
        CodexTail { sessions: codex_dir.join("sessions"), files: HashMap::new() }
    }

    /// The events in every line Codex has finished writing since the last
    /// poll, oldest first. The first poll reads recent files from the top;
    /// what was already counted comes back with the same ids and is ignored.
    pub fn poll(&mut self, paths: &Paths, now_ms: i64) -> Vec<Event> {
        let horizon = SystemTime::now() - RECENT;
        let recent = |p: &Path| fs::metadata(p).and_then(|m| m.modified()).is_ok_and(|t| t >= horizon);
        // Rollouts are filed by the day they started (local time).
        let today = Local::now().date_naive();
        for back in 0..3 {
            let Some(day) = today.checked_sub_days(Days::new(back)) else { continue };
            let Ok(entries) = fs::read_dir(self.sessions.join(day.format("%Y/%m/%d").to_string())) else { continue };
            for p in entries.flatten().map(|e| e.path()) {
                if p.extension().and_then(|e| e.to_str()) == Some("jsonl") && !self.files.contains_key(&p) && recent(&p) {
                    let r = Rollout::new(&p);
                    self.files.insert(p, (0, r));
                }
            }
        }
        let mut out = Vec::new();
        for (path, (offset, r)) in self.files.iter_mut() {
            let len = fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            if len > *offset {
                let mut buf = Vec::new();
                let read = fs::File::open(path).and_then(|mut f| {
                    f.seek(SeekFrom::Start(*offset))?;
                    f.take(len - *offset).read_to_end(&mut buf)
                });
                // Whole lines only: Codex may be half way through one.
                if let (Ok(_), Some(last)) = (read, buf.iter().rposition(|&b| b == b'\n')) {
                    for line in buf[..last].split(|&b| b == b'\n') {
                        if let Ok(s) = std::str::from_utf8(line) {
                            out.extend(r.line(s, i64::MAX, paths));
                        }
                    }
                    *offset += last as u64 + 1;
                }
            }
            out.extend(r.end(now_ms));
        }
        self.files.retain(|p, _| recent(p));
        // Stable: a file's own order holds for equal times.
        out.sort_by_key(|e| e.ts_ms().unwrap_or(0));
        out
    }
}
