//! The daemon: tails the spool and answers a JSON-lines protocol on a Unix
//! socket (SPEC 3). Requests: {"op":"ping"|"flush"|"settle"|"status", "session_id"?}.

use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde_json::{json, Value};

use crate::config::Config;
use crate::db;
use crate::ingest::{Mode, Processor, Result, Tz};
use crate::panel;
use crate::widget;
use crate::paths::Paths;
use crate::snapshot;

pub const POLL: Duration = Duration::from_millis(250);
/// Model usage is read every this many polls (~10 s)…
const USAGE_EVERY: u64 = 40;
/// …for turns that ended at least this long ago, once their logs are written.
const USAGE_SETTLE_MS: i64 = 15_000;
/// Codex's rollout files are followed every this many polls (~1 s).
const CODEX_EVERY: u64 = 4;
/// Claude Code's transcripts, when its hooks are not installed (~2 s).
const CLAUDE_EVERY: u64 = 8;

/// Takes the processor lock without waiting. Ok(None) means another process
/// (normally the daemon) holds it.
pub fn try_lock(paths: &Paths) -> Result<Option<File>> {
    paths.ensure()?;
    let f = OpenOptions::new().create(true).truncate(false).write(true).open(&paths.lock)?;
    match f.try_lock() {
        Ok(()) => Ok(Some(f)),
        Err(fs::TryLockError::WouldBlock) => Ok(None),
        Err(fs::TryLockError::Error(e)) => Err(e.into()),
    }
}

pub fn open_processor(paths: &Paths, mode: Mode) -> Result<Processor> {
    let cfg = Config::load(paths);
    let conn = db::open(&paths.db)?;
    Ok(Processor::new(conn, mode, Tz::from_env(), cfg))
}

pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// Ingests new spool lines and, when anything changed, rewrites the local
/// panel's data so an open panel follows along.
pub fn ingest_and_refresh(p: &mut Processor, paths: &Paths) -> Result<usize> {
    let n = p.ingest_spool(paths)?;
    if n > 0 {
        panel::write(paths, &p.conn, p.tz, p.cfg.general.weekly_target, now_ms())?;
        widget::write(paths, &p.conn, p.tz, &p.cfg, now_ms())?;
    }
    Ok(n)
}

/// Handles one request against an exclusive processor.
pub fn respond(p: &mut Processor, paths: &Paths, req: &Value) -> Value {
    if let Err(e) = ingest_and_refresh(p, paths) {
        return json!({ "ok": false, "error": e.to_string() });
    }
    let sid = req.get("session_id").and_then(Value::as_str);
    let now = now_ms();
    match req.get("op").and_then(Value::as_str).unwrap_or("") {
        "ping" | "flush" => json!({ "ok": true }),
        "settle" => {
            let Some(summary) = sid.and_then(|s| p.settlements.remove(s)) else { return json!({ "ok": true }) };
            let mut text = dango_core::render::settlement_box(&summary);
            if let Ok(Some(badge)) = snapshot::take_grand(&p.conn, now, p.cfg.ceremony.grand_cooldown_hours) {
                text = format!("{text}\n{badge}");
            }
            json!({ "ok": true, "text": text })
        }
        "status" => match snapshot::status(&p.conn, p.tz, now, sid, p.cfg.lang()) {
            Ok(t) => json!({ "ok": true, "text": t }),
            Err(e) => json!({ "ok": false, "error": e.to_string() }),
        },
        op => json!({ "ok": false, "error": format!("unknown op {op:?}") }),
    }
}

fn serve_client(stream: UnixStream, shared: &Mutex<Processor>, paths: &Paths) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
    let mut line = String::new();
    if BufReader::new(&stream).read_line(&mut line).is_err() {
        return;
    }
    let req: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
    let resp = {
        let mut p = shared.lock().unwrap_or_else(|e| e.into_inner());
        respond(&mut p, paths, &req)
    };
    let mut w = &stream;
    let _ = writeln!(w, "{resp}");
}

/// Runs in the foreground until killed. A kill at any point loses nothing:
/// the spool offset only advances in the same transaction as the work.
pub fn run(paths: &Paths) -> Result<()> {
    let Some(_lock) = try_lock(paths)? else {
        return Err("another dango daemon is already running".into());
    };
    let shared = Arc::new(Mutex::new(open_processor(paths, Mode::Live)?));
    let _ = fs::remove_file(&paths.sock);
    let listener = UnixListener::bind(&paths.sock)?;
    fs::set_permissions(&paths.sock, fs::Permissions::from_mode(0o600))?;
    {
        let shared = Arc::clone(&shared);
        let paths = paths.clone();
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                serve_client(stream, &shared, &paths);
            }
        });
    }
    eprintln!("dango daemon: watching {}", paths.spool.display());
    {
        let p = shared.lock().unwrap_or_else(|e| e.into_inner());
        if let Err(e) = panel::write(paths, &p.conn, p.tz, p.cfg.general.weekly_target, now_ms())
            .and_then(|_| widget::write(paths, &p.conn, p.tz, &p.cfg, now_ms()))
        {
            eprintln!("dango daemon: panel write failed: {e}");
        }
    }
    let home = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let (claude_dir, codex_dir) = (home.join(".claude"), home.join(".codex"));
    {
        let mut p = shared.lock().unwrap_or_else(|e| e.into_inner());
        if let Err(e) = import_history(&mut p, paths, &claude_dir, &codex_dir) {
            eprintln!("dango daemon: history import failed: {e}");
        }
    }
    let mut codex = crate::codex_tail::CodexTail::new(&codex_dir);
    let mut claude = crate::claude_tail::ClaudeTail::new(&claude_dir);
    let mut tick: u64 = 0;
    let modified = |p: &Paths| fs::metadata(&p.config).and_then(|m| m.modified()).ok();
    let mut config_at = modified(paths);
    loop {
        {
            let mut p = shared.lock().unwrap_or_else(|e| e.into_inner());
            // A changed config.toml (the language switch) applies right away.
            let now_at = modified(paths);
            if now_at != config_at {
                config_at = now_at;
                p.cfg = Config::load(paths);
                let _ = widget::write(paths, &p.conn, p.tz, &p.cfg, now_ms());
            }
            if let Err(e) = ingest_and_refresh(&mut p, paths) {
                eprintln!("dango daemon: ingest failed: {e}");
            }
        }
        // Every second, what Codex has written: its work, without hooks. The
        // files are read without the lock.
        if tick % CODEX_EVERY == 0 {
            let on = shared.lock().unwrap_or_else(|e| e.into_inner()).cfg.sources.codex;
            let events = if on { codex.poll(paths, now_ms()) } else { Vec::new() };
            if !events.is_empty() {
                let mut p = shared.lock().unwrap_or_else(|e| e.into_inner());
                if let Err(e) = take_followed(&mut p, paths, &events) {
                    // Nothing kept: read the files again from the top next
                    // time (what did count is ignored by id).
                    codex = crate::codex_tail::CodexTail::new(&codex_dir);
                    eprintln!("dango daemon: codex failed: {e}");
                }
            }
        }
        // Every ~2 s, what Claude Code has written, unless Dango's hooks are
        // installed and report it themselves.
        if tick % CLAUDE_EVERY == 0 && !claude.hooks_installed() {
            let mut events = claude.poll(paths, now_ms());
            if !events.is_empty() {
                let mut p = shared.lock().unwrap_or_else(|e| e.into_inner());
                drop_hooked_sessions(&p.conn, &mut events);
                if let Err(e) = take_followed(&mut p, paths, &events) {
                    claude = crate::claude_tail::ClaudeTail::new(&claude_dir);
                    eprintln!("dango daemon: claude failed: {e}");
                }
            }
        }
        // Every ~10 s, price turns that ended a little while ago. The logs
        // are read without the lock, so a Stop hook's box is never held up.
        if tick % USAGE_EVERY == 0 {
            let todo = {
                let p = shared.lock().unwrap_or_else(|e| e.into_inner());
                crate::usage::pending(&p.conn, now_ms() - USAGE_SETTLE_MS, 200).unwrap_or_default()
            };
            if !todo.is_empty() {
                let events = crate::usage::read(&claude_dir, &codex_dir, &todo);
                let mut p = shared.lock().unwrap_or_else(|e| e.into_inner());
                match crate::usage::apply(&mut p, &events) {
                    Ok(n) if n > 0 => {
                        let _ = widget::write(paths, &p.conn, p.tz, &p.cfg, now_ms());
                    }
                    Ok(_) => {}
                    Err(e) => eprintln!("dango daemon: usage failed: {e}"),
                }
            }
        }
        tick += 1;
        thread::sleep(POLL);
    }
}

/// Ingests events followed from a tool's own logs, as backfill does: one
/// transaction, a bad event skipped, the panel rewritten when anything was
/// new. On an error nothing is kept.
fn take_followed(p: &mut Processor, paths: &Paths, events: &[dango_core::event::Event]) -> Result<()> {
    let mut fresh = 0;
    let done = p.begin().and_then(|_| {
        for ev in events {
            match p.handle(ev) {
                Ok(new) => fresh += new as usize,
                Err(e) => eprintln!("dango daemon: skipped {}: {e}", ev.id),
            }
        }
        p.commit()
    });
    match done {
        Ok(()) => {
            if fresh > 0 {
                let _ = panel::write(paths, &p.conn, p.tz, p.cfg.general.weekly_target, now_ms())
                    .and_then(|_| widget::write(paths, &p.conn, p.tz, &p.cfg, now_ms()));
            }
            Ok(())
        }
        Err(e) => {
            p.rollback();
            Err(e)
        }
    }
}

/// Followed Claude Code events of sessions its hooks have reported (they
/// count those live; following them too would count twice).
fn drop_hooked_sessions(conn: &rusqlite::Connection, events: &mut Vec<dango_core::event::Event>) {
    let mut seen: std::collections::HashMap<String, bool> = std::collections::HashMap::new();
    events.retain(|e| {
        let Some(sid) = e.session_id.clone() else { return true };
        let hooked = *seen.entry(sid.clone()).or_insert_with(|| {
            conn.query_row("SELECT 1 FROM events WHERE session_id = ?1 AND source = 'claude_code' LIMIT 1", [&sid], |_| Ok(()))
                .is_ok()
        });
        !hooked
    });
}

/// The first start on a Mac: imports the history (Claude Code before its
/// hooks first reported, all of Codex) the way `dango backfill` does, so a
/// fresh install has its boss type at once. Done once (meta
/// `history_imported`); afterwards the followers and hooks keep it current,
/// and running it again would only find what is already counted.
pub fn import_history(p: &mut Processor, paths: &Paths, claude_dir: &std::path::Path, codex_dir: &std::path::Path) -> Result<()> {
    if db::get_meta(&p.conn, "history_imported")?.is_some() {
        return Ok(());
    }
    let now = now_ms();
    let cutoff = db::get_meta(&p.conn, "live_since")?.and_then(|v| v.parse().ok()).unwrap_or(now);
    let codex = p.cfg.sources.codex && codex_dir.join("sessions").is_dir();
    eprintln!("dango daemon: importing history…");
    let mode = p.mode;
    p.mode = Mode::Backfill;
    let r = crate::backfill::run(p, paths, claude_dir, cutoff, codex.then_some((codex_dir, now)))
        .and_then(|_| crate::usage::fill(p, claude_dir, codex_dir, now, usize::MAX).map(|_| ()));
    p.mode = mode;
    r?;
    // As `dango backfill`: badges earned in the past are not celebrated now.
    p.conn.execute("UPDATE unlocks SET celebrated = 1 WHERE backfilled = 1", [])?;
    db::set_meta(&p.conn, "history_imported", &now.to_string())?;
    panel::write(paths, &p.conn, p.tz, p.cfg.general.weekly_target, now_ms())?;
    widget::write(paths, &p.conn, p.tz, &p.cfg, now_ms())
}

/// Sends one request; None if no daemon answers within `timeout`.
pub fn request(paths: &Paths, req: &Value, timeout: Duration) -> Option<Value> {
    let mut s = UnixStream::connect(&paths.sock).ok()?;
    s.set_read_timeout(Some(timeout)).ok()?;
    s.set_write_timeout(Some(timeout)).ok()?;
    writeln!(s, "{req}").ok()?;
    let mut line = String::new();
    BufReader::new(&s).read_line(&mut line).ok()?;
    serde_json::from_str(&line).ok()
}
