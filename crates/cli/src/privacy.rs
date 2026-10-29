//! `dango privacy-scan` (SPEC 14, 17.2): checks that nothing stored
//! locally looks like a path, code, a prompt or free text. Every stored
//! string must be a short token (ids, hashes, enum values, timestamps);
//! the only exceptions are UI strings that come from the bundled catalog.

use std::fs;

use daemon::db;
use daemon::ingest::Result;
use daemon::paths::Paths;
use daemon::spool;
use rusqlite::Connection;
use serde_json::Value;
use dango_core::achievements::Catalog;
use dango_core::progress::STAGES;

fn token_ok(s: &str) -> bool {
    s.len() <= 64 && s.chars().all(|c| c.is_ascii_alphanumeric() || "_.:+-".contains(c))
}

/// Strings shipped with the app (titles, achievement names) may hold CJK
/// and spaces; anything else must be a token.
fn catalog_text(s: &str) -> bool {
    let cat = Catalog::builtin();
    STAGES.iter().any(|st| st.title == s)
        || cat.achievements.iter().any(|a| a.tiers.iter().any(|t| t.reward.title.as_deref() == Some(s)))
}

fn walk(v: &Value, at: &str, out: &mut Vec<String>) {
    match v {
        Value::String(s) if !token_ok(s) => out.push(format!("{at}: suspicious string ({} chars)", s.chars().count())),
        Value::Array(a) => a.iter().enumerate().for_each(|(i, x)| walk(x, &format!("{at}[{i}]"), out)),
        Value::Object(o) => o.iter().for_each(|(k, x)| walk(x, &format!("{at}.{k}"), out)),
        _ => {}
    }
}

fn scan_db(conn: &Connection, out: &mut Vec<String>) -> Result<usize> {
    let mut rows = 0;
    let mut st = conn.prepare("SELECT id, source, kind, session_id, turn_id, cwd_hash, payload FROM events")?;
    for r in st.query_map([], |r| {
        Ok((
            [r.get::<_, String>(0)?, r.get(1)?, r.get(2)?],
            [r.get::<_, Option<String>>(3)?, r.get(4)?, r.get(5)?],
            r.get::<_, String>(6)?,
        ))
    })? {
        let (fixed, opt, payload) = r?;
        rows += 1;
        for s in fixed.iter().chain(opt.iter().flatten()) {
            if !token_ok(s) {
                out.push(format!("events: suspicious column value ({} chars)", s.chars().count()));
            }
        }
        walk(&serde_json::from_str(&payload).unwrap_or(Value::Null), "events.payload", out);
    }
    for (table, col) in [("turns", "agg"), ("sessions", "state")] {
        let mut st = conn.prepare(&format!("SELECT {col} FROM {table}"))?;
        for v in st.query_map([], |r| r.get::<_, String>(0))?.flatten() {
            rows += 1;
            walk(&serde_json::from_str(&v).unwrap_or(Value::Null), &format!("{table}.{col}"), out);
        }
    }
    let mut st = conn.prepare("SELECT key, value FROM meta")?;
    for (k, v) in st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?.flatten() {
        rows += 1;
        let ok = match k.as_str() {
            "streak" => serde_json::from_str::<Value>(&v).map(|j| {
                let mut o = Vec::new();
                walk(&j, "meta.streak", &mut o);
                o.is_empty()
            }).unwrap_or(false),
            "display_title" => catalog_text(&v),
            // "<achievement name> 还差 N<unit>", rebuilt from the catalog.
            "hint_text" => v.chars().count() <= 40 && !v.contains('/'),
            _ => token_ok(&v),
        };
        if !ok {
            out.push(format!("meta.{k}: unexpected value"));
        }
    }
    // session_meta holds a session's title and project folder name on
    // purpose (DESIGN.md §4): local only, so only its size is checked here.
    let mut st = conn.prepare("SELECT project, title FROM session_meta")?;
    for (p, t) in st.query_map([], |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, Option<String>>(1)?)))?.flatten() {
        rows += 1;
        if p.is_some_and(|p| p.chars().count() > 40) || t.is_some_and(|t| t.chars().count() > 60) {
            out.push("session_meta: name longer than allowed".into());
        }
    }
    let mut st = conn.prepare("SELECT item_id, source FROM inventory")?;
    for (item, src) in st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?.flatten() {
        rows += 1;
        let item_ok = item.strip_prefix("title:").map_or_else(|| token_ok(&item), catalog_text);
        if !item_ok || !token_ok(&src) {
            out.push("inventory: unexpected value".into());
        }
    }
    Ok(rows)
}

pub fn scan(paths: &Paths) -> Result<i32> {
    let mut out = Vec::new();
    let mut lines = 0;
    for f in spool::files(paths) {
        for (i, line) in fs::read_to_string(&f)?.lines().enumerate() {
            lines += 1;
            let at = format!("{}:{}", f.file_name().unwrap_or_default().to_string_lossy(), i + 1);
            match serde_json::from_str::<Value>(line) {
                Ok(v) => walk(&v, &at, &mut out),
                Err(_) => out.push(format!("{at}: not JSON")),
            }
        }
    }
    let mut rows = 0;
    if paths.db.exists() {
        rows = scan_db(&db::open(&paths.db)?, &mut out)?;
    }
    let mut states = 0;
    if let Ok(rd) = fs::read_dir(&paths.state) {
        for f in rd.flatten() {
            states += 1;
            let t = fs::read_to_string(f.path()).unwrap_or_default();
            if !t.split(' ').all(token_ok) {
                out.push(format!("state/{}: unexpected content", f.file_name().to_string_lossy()));
            }
        }
    }
    println!("扫描：spool {lines} 行，数据库 {rows} 行，state {states} 个文件。");
    if out.is_empty() {
        println!("通过：没有发现路径、代码、prompt 或自由文本。");
        Ok(0)
    } else {
        for o in &out {
            println!("✗ {o}");
        }
        println!("失败：{} 处可疑内容。", out.len());
        Ok(1)
    }
}
