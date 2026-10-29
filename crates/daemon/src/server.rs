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
            let mut text = shadowcorp_core::render::settlement_box(&summary);
            if let Ok(Some(badge)) = snapshot::take_grand(&p.conn, now, p.cfg.ceremony.grand_cooldown_hours) {
                text = format!("{text}\n{badge}");
            }
            json!({ "ok": true, "text": text })
        }
        "status" => match snapshot::status(&p.conn, p.tz, now, sid) {
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
        return Err("another shadowcorp daemon is already running".into());
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
    eprintln!("shadowcorp daemon: watching {}", paths.spool.display());
    {
        let p = shared.lock().unwrap_or_else(|e| e.into_inner());
        if let Err(e) = panel::write(paths, &p.conn, p.tz, p.cfg.general.weekly_target, now_ms())
            .and_then(|_| widget::write(paths, &p.conn, p.tz, &p.cfg, now_ms()))
        {
            eprintln!("shadowcorp daemon: panel write failed: {e}");
        }
    }
    let home = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default());
    let (claude_dir, codex_dir) = (home.join(".claude"), home.join(".codex"));
    let mut tick: u64 = 0;
    loop {
        {
            let mut p = shared.lock().unwrap_or_else(|e| e.into_inner());
            if let Err(e) = ingest_and_refresh(&mut p, paths) {
                eprintln!("shadowcorp daemon: ingest failed: {e}");
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
                    Err(e) => eprintln!("shadowcorp daemon: usage failed: {e}"),
                }
            }
        }
        tick += 1;
        thread::sleep(POLL);
    }
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
