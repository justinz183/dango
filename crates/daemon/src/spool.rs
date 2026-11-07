//! The append-only spool capture writes to (SPEC 3). One file per UTC day,
//! `spool/events-YYYYMMDD.jsonl`, so retention never has to rename a file a
//! hook may be appending to. Consumed files are kept 7 days for replay.

use std::fs;
use std::io::{self, Write};
use std::path::PathBuf;

use chrono::{DateTime, Utc};
use dango_core::event::Event;

use crate::paths::{private_options, Paths};

pub const RETENTION_DAYS: i64 = 7;

pub fn file_for(paths: &Paths, ts_ms: i64) -> PathBuf {
    let day = DateTime::<Utc>::from_timestamp_millis(ts_ms).unwrap_or_default().format("%Y%m%d");
    paths.spool.join(format!("events-{day}.jsonl"))
}

/// Appends one event as a single write, so concurrent hooks never interleave.
pub fn append(paths: &Paths, ev: &Event) -> io::Result<()> {
    let mut line = serde_json::to_vec(ev).map_err(io::Error::other)?;
    line.push(b'\n');
    let path = file_for(paths, ev.ts_ms().unwrap_or(0));
    let mut f = private_options().create(true).append(true).open(&path)?;
    f.write_all(&line)
}

/// Spool files in chronological order.
pub fn files(paths: &Paths) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir(&paths.spool)
        .map(|rd| {
            rd.filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| {
                    let n = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
                    n.starts_with("events-") && n.ends_with(".jsonl")
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

/// UTC day encoded in a spool file name.
pub fn file_day(path: &std::path::Path) -> Option<chrono::NaiveDate> {
    let n = path.file_name()?.to_str()?;
    let d = n.strip_prefix("events-")?.strip_suffix(".jsonl")?;
    chrono::NaiveDate::parse_from_str(d, "%Y%m%d").ok()
}
