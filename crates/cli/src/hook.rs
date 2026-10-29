//! `dango hook` (Claude Code) and `dango hook --codex` (Codex):
//! the command every hook runs. Reads stdin, appends its events to the
//! spool and exits 0 — always, so it can never block the agent. On Stop it asks the daemon for this turn's box and
//! returns it as `systemMessage`, which Claude Code shows to the user and
//! does not add to the model's context. Async hooks print nothing: their
//! output would be delivered to Claude.

use std::io::Read;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use daemon::capture::{self, CaptureEnv};
use daemon::config::Config;
use daemon::paths::Paths;
use daemon::{server, spool};
use serde_json::{json, Value};
use dango_core::event::Kind;

/// SPEC 4.1: the Stop hook waits at most this long for the box.
pub const SETTLE_TIMEOUT: Duration = Duration::from_millis(300);

pub fn run(paths: &Paths, codex: bool) -> i32 {
    let mut raw = Vec::new();
    if std::io::stdin().read_to_end(&mut raw).is_err() {
        return 0;
    }
    let Ok(input) = serde_json::from_slice::<Value>(&raw) else { return 0 };
    let sources = Config::load(paths).sources;
    if !(if codex { sources.codex } else { sources.claude_code }) || paths.ensure().is_err() {
        return 0;
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let env = CaptureEnv {
        paths,
        now_ms: now.as_millis() as i64,
        nonce: format!("{}:{}", std::process::id(), now.as_nanos()),
        git_lookup: true,
    };
    let events = if codex { capture::from_codex_hook(&input, &raw, &env) } else { capture::from_claude_hook(&input, &raw, &env).into_iter().collect() };
    if events.iter().any(|ev| spool::append(paths, ev).is_err()) {
        return 0;
    }
    // Codex shows a Stop hook's systemMessage too, as a notice.
    for ev in events.iter().filter(|ev| ev.kind == Kind::TurnEnd && ev.payload.stop_hook_active != Some(true)) {
        if let Some(sid) = &ev.session_id {
            let req = json!({ "op": "settle", "session_id": sid });
            if let Some(text) = server::request(paths, &req, SETTLE_TIMEOUT)
                .and_then(|r| r.get("text").and_then(Value::as_str).map(str::to_string))
            {
                println!("{}", json!({ "systemMessage": text }));
            }
        }
    }
    0
}
