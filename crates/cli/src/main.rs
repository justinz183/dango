//! shadowcorp — hook handler, daemon and CLI in one binary (SPEC 3).

mod hook;
mod pages;
mod privacy;

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;

use daemon::backfill;
use daemon::capture::{self, CaptureEnv};
use daemon::config::Config;
use daemon::db;
use daemon::ingest::{Mode, Processor, Result, Tz};
use daemon::paths::Paths;
use daemon::server::{self, now_ms};
use daemon::snapshot;
use daemon::spool;
use rusqlite::Connection;
use serde_json::{json, Value};
use shadowcorp_core::event::{Event, Kind};
use shadowcorp_core::render::{fmt_pd, fmt_usd, settlement_box};

const USAGE: &str = "shadowcorp — 衡量产出的 AI 编码成就系统

用法:
  shadowcorp hook                  Claude Code hook 入口（从 stdin 读 JSON）
  shadowcorp status [--claude]     一行状态；--claude 供 statusLine 使用
  shadowcorp stats                 公司页
  shadowcorp badges                成就与职业图鉴
  shadowcorp widget                启动桌面小部件（屏幕右下角）
  shadowcorp report [--week|--month|--year] [--day DATE] [--tool claude|codex] [--names] [--json]
                                   日报 / 周报 / 月报（DATE = YYYY-MM-DD | today | yesterday，
                                   周报取 DATE 所在的周，月报取所在的月）
  shadowcorp card [--week|--month|--year] [--day DATE] [--tool claude|codex] [--names] [--out PNG] [--no-open]
                                   渲染分享卡到 ~/Pictures/ShadowCorp/ 并复制到剪贴板
  shadowcorp panel [--no-open]     生成并打开本地网页面板（办公室、成就、周报）
  shadowcorp backfill [--claude-dir DIR]
                                   导入安装前的 Claude Code 历史
  shadowcorp daemon                前台运行守护进程
  shadowcorp replay PATH...        回放 hook fixtures（.json / .jsonl / 目录）
  shadowcorp rebuild               从事件表重建全部派生数据
  shadowcorp privacy-scan          扫描本地数据，确认没有路径、代码或 prompt

数据目录: ~/.shadowcorp（可用 SHADOWCORP_HOME 覆盖）";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let paths = Paths::from_env();
    let code = match args.first().map(String::as_str) {
        Some("hook") => hook::run(&paths, args.get(1).map(String::as_str) == Some("--codex")),
        Some(cmd) => match dispatch(cmd, &args[1..], &paths) {
            Ok(code) => code,
            Err(e) => {
                eprintln!("shadowcorp {cmd}: {e}");
                1
            }
        },
        None => {
            println!("{USAGE}");
            0
        }
    };
    std::process::exit(code);
}

fn dispatch(cmd: &str, args: &[String], paths: &Paths) -> Result<i32> {
    match cmd {
        "status" => status(paths, args.iter().any(|a| a == "--claude")),
        "stats" => with_fresh_db(paths, |c, cfg| pages::stats(c, Tz::from_env(), cfg, now_ms())),
        "badges" => with_fresh_db(paths, |c, _| pages::badges(c)),
        "backfill" => run_backfill(paths, args),
        "panel" => panel(paths, args.iter().any(|a| a == "--no-open")),
        "widget" => widget(paths),
        "report" => report(paths, args),
        "card" => card(paths, args),
        "daemon" => server::run(paths).map(|_| 0),
        "replay" => replay(paths, args),
        "rebuild" => rebuild(paths),
        "privacy-scan" => privacy::scan(paths),
        "version" | "--version" | "-V" => {
            println!("shadowcorp {}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        "help" | "--help" | "-h" => {
            println!("{USAGE}");
            Ok(0)
        }
        other => Err(format!("unknown command {other:?}\n\n{USAGE}").into()),
    }
}

/// Runs `f` on an up-to-date database: asks a running daemon to flush the
/// spool, or ingests it here when no daemon holds the processor lock.
fn fresh_db<T>(paths: &Paths, f: impl FnOnce(&Connection, &Config) -> Result<T>) -> Result<T> {
    match server::try_lock(paths)? {
        Some(_lock) => {
            let mut p = server::open_processor(paths, Mode::Live)?;
            p.ingest_spool(paths)?;
            f(&p.conn, &p.cfg)
        }
        None => {
            let _ = server::request(paths, &json!({ "op": "flush" }), Duration::from_secs(5));
            let conn = db::open(&paths.db)?;
            f(&conn, &Config::load(paths))
        }
    }
}

fn with_fresh_db(paths: &Paths, f: impl FnOnce(&Connection, &Config) -> Result<String>) -> Result<i32> {
    println!("{}", fresh_db(paths, f)?);
    Ok(0)
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
}

fn claude_dir() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".claude")
}

fn parse_day(args: &[String]) -> Result<chrono::NaiveDate> {
    let today = Tz::from_env().date(now_ms());
    Ok(match flag(args, "--day").as_deref() {
        None | Some("today") | Some("今天") => today,
        Some("yesterday") | Some("昨天") => today.pred_opt().unwrap(),
        Some(d) => chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").map_err(|_| format!("日期格式应为 YYYY-MM-DD，收到 {d:?}"))?,
    })
}

/// `--tool claude|codex`: one agent's work only (sessions.source).
fn parse_tool(args: &[String]) -> Result<Option<&'static str>> {
    Ok(match flag(args, "--tool").as_deref() {
        None | Some("all") => None,
        Some("claude" | "claude_code" | "claude-code") => Some("claude_code"),
        Some("codex") => Some("codex"),
        Some(t) => return Err(format!("--tool 只接 claude 或 codex，收到 {t:?}").into()),
    })
}

/// The day, week, month or year report the arguments ask for (the one
/// that contains `--day`).
fn any_report(paths: &Paths, args: &[String]) -> Result<Value> {
    let date = parse_day(args)?;
    let tool = parse_tool(args)?;
    let names = args.iter().any(|a| a == "--names");
    let has = |f: &str| args.iter().any(|a| a == f);
    fresh_db(paths, |c, cfg| {
        let (tz, dir, now) = (Tz::from_env(), claude_dir(), now_ms());
        if has("--year") {
            daemon::report::year(c, tz, cfg, &dir, date, now, names, tool)
        } else if has("--month") {
            daemon::report::month(c, tz, cfg, &dir, date, now, names, tool)
        } else if has("--week") {
            daemon::report::week(c, tz, cfg, &dir, date, now, names, tool)
        } else {
            daemon::report::day(c, tz, cfg, &dir, date, now, names, tool)
        }
    })
}

fn report(paths: &Paths, args: &[String]) -> Result<i32> {
    let r = any_report(paths, args)?;
    if args.iter().any(|a| a == "--json") {
        println!("{}", serde_json::to_string_pretty(&r)?);
    } else {
        println!("{}", daemon::report::text(&r));
    }
    Ok(0)
}

/// The card renderer: ShadowCorp.app when installed, else the widget binary.
fn renderer() -> Result<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let candidates = [
        PathBuf::from("/Applications/ShadowCorp.app/Contents/MacOS/ShadowCorp"),
        PathBuf::from(format!("{home}/Applications/ShadowCorp.app/Contents/MacOS/ShadowCorp")),
        std::env::current_exe()?.with_file_name("shadowcorp-widget"),
    ];
    candidates.into_iter().find(|p| p.exists()).ok_or_else(|| "没有找到 ShadowCorp.app，先运行 apps/widget/bundle.sh".into())
}

fn card(paths: &Paths, args: &[String]) -> Result<i32> {
    let r = any_report(paths, args)?;
    let kind = r["kind"].as_str().unwrap_or("day").to_string();
    let tool = r["tool"].as_str().map(|t| format!("-{t}")).unwrap_or_default();
    let date = format!("{kind}-{}{tool}", r["date"].as_str().unwrap_or(""));
    let cards = paths.home.join("cards");
    fs::create_dir_all(&cards)?;
    let json_path = cards.join(format!("{date}.json"));
    daemon::paths::write_private(&json_path, serde_json::to_string(&r)?.as_bytes())?;
    let out = match flag(args, "--out") {
        Some(o) => PathBuf::from(o),
        None => {
            let dir = PathBuf::from(std::env::var("HOME")?).join("Pictures").join("ShadowCorp");
            fs::create_dir_all(&dir)?;
            dir.join(format!("{date}.png"))
        }
    };
    let status = std::process::Command::new(renderer()?).arg("--card").arg(&json_path).arg(&out).arg("--copy").status()?;
    if !status.success() {
        return Err("渲染失败".into());
    }
    let what = match kind.as_str() { "week" => "周报卡", "month" => "月报卡", "year" => "年报卡", _ => "日报卡" };
    println!("{what}：{}（已复制到剪贴板）", out.display());
    if !args.iter().any(|a| a == "--no-open") {
        std::process::Command::new("open").arg(&out).status()?;
    }
    Ok(0)
}

/// Starts the desktop widget with fresh data to show: ShadowCorp.app when
/// it is installed (apps/widget/bundle.sh), else the bare binary next to
/// this one. The widget itself refuses to run twice.
fn widget(paths: &Paths) -> Result<i32> {
    fresh_db(paths, |c, cfg| daemon::widget::write(paths, c, Tz::from_env(), cfg, now_ms()))?;
    let home = std::env::var("HOME").unwrap_or_default();
    let apps = [PathBuf::from("/Applications/ShadowCorp.app"), PathBuf::from(format!("{home}/Applications/ShadowCorp.app"))];
    if let Some(app) = apps.iter().find(|a| a.exists()) {
        std::process::Command::new("open").arg("-a").arg(app).status()?;
        println!("ShadowCorp 已打开，小部件在屏幕右下角。右键可退出或设置登录时自动启动。");
        return Ok(0);
    }
    let exe = std::env::current_exe()?.with_file_name("shadowcorp-widget");
    if !exe.exists() {
        return Err(format!("没有找到 ShadowCorp.app 或 {}，先运行 apps/widget/bundle.sh", exe.display()).into());
    }
    std::process::Command::new(exe)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    println!("小部件已启动，在屏幕右下角。右键可退出或设置登录时自动启动。");
    Ok(0)
}

fn status(paths: &Paths, claude: bool) -> Result<i32> {
    if !claude {
        return with_fresh_db(paths, |c, _| snapshot::status(c, Tz::from_env(), now_ms(), None));
    }
    // statusLine mode: session_id from stdin, answer from the daemon or the
    // last cached line (SPEC 4.2). Never slower than the hook budget.
    let mut raw = String::new();
    let _ = std::io::stdin().read_to_string(&mut raw);
    let sid = serde_json::from_str::<Value>(&raw).ok().and_then(|v| v.get("session_id").and_then(Value::as_str).map(str::to_string));
    let req = json!({ "op": "status", "session_id": sid });
    match server::request(paths, &req, hook::SETTLE_TIMEOUT).and_then(|r| r.get("text").and_then(Value::as_str).map(str::to_string)) {
        Some(line) => {
            println!("{line}");
            let _ = daemon::paths::write_private(&paths.status_cache, line.as_bytes());
        }
        None => println!("{}", fs::read_to_string(&paths.status_cache).unwrap_or_else(|_| "▮ 影子公司".into())),
    }
    Ok(0)
}

/// Writes the local panel and opens it in the default browser.
fn panel(paths: &Paths, no_open: bool) -> Result<i32> {
    let mut page = PathBuf::new();
    with_fresh_db(paths, |c, cfg| {
        page = daemon::panel::write(paths, c, Tz::from_env(), cfg.general.weekly_target, now_ms())?;
        Ok(format!("面板：{}", page.display()))
    })?;
    if !no_open {
        std::process::Command::new("open").arg(&page).status()?;
    }
    Ok(0)
}

fn locked_processor(paths: &Paths, mode: Mode) -> Result<(fs::File, Processor)> {
    let lock = server::try_lock(paths)?.ok_or("the daemon is running; stop it first (it holds processor.lock)")?;
    Ok((lock, server::open_processor(paths, mode)?))
}

fn run_backfill(paths: &Paths, args: &[String]) -> Result<i32> {
    let dir = |flag: &str, default: &str| -> Result<PathBuf> {
        Ok(match args.iter().position(|a| a == flag) {
            Some(i) => PathBuf::from(args.get(i + 1).ok_or(format!("{flag} needs a path"))?),
            None => PathBuf::from(std::env::var("HOME")?).join(default),
        })
    };
    let (claude_dir, codex_dir) = (dir("--claude-dir", ".claude")?, dir("--codex-dir", ".codex")?);
    let codex = Config::load(paths).sources.codex && codex_dir.join("sessions").is_dir();
    if !claude_dir.join("projects").is_dir() && !codex {
        println!("没有找到 {}/projects 或 {}/sessions，跳过回填。", claude_dir.display(), codex_dir.display());
        return Ok(0);
    }
    let (_lock, mut p) = locked_processor(paths, Mode::Backfill)?;
    let since = |key: &str| -> Result<i64> { Ok(db::get_meta(&p.conn, key)?.and_then(|v| v.parse().ok()).unwrap_or_else(now_ms)) };
    let (cutoff, codex_cutoff) = (since("live_since")?, since("live_since:codex")?);
    println!("正在整理 Claude Code{} 的历史…", if codex { " 和 Codex" } else { "" });
    let r = backfill::run(&mut p, paths, &claude_dir, cutoff, codex.then_some((codex_dir.as_path(), codex_cutoff)))?;
    daemon::usage::fill(&mut p, &claude_dir, &codex_dir, now_ms(), usize::MAX)?;
    let total = snapshot::counter(&p.conn, "person_days", "all");
    let unlocked: i64 = p.conn.query_row("SELECT COUNT(DISTINCT achievement_id) FROM unlocks", [], |r| r.get(0))?;
    p.conn.execute("UPDATE unlocks SET celebrated = 1 WHERE backfilled = 1", [])?;
    let usd = |m: &str| fmt_usd(snapshot::counter(&p.conn, m, "all"));
    println!(
        "累计 {}（Claude Code {} · Codex {}），{} 人日，解锁了 {unlocked} 个徽章。",
        usd("usd"),
        usd("usd:claude_code"),
        usd("usd:codex"),
        fmt_pd(total)
    );
    let rate = if r.secs > 0.0 { r.events as f64 / r.secs } else { 0.0 };
    println!("（{} 个 transcript，{} 个事件，新增 {}，用时 {:.2}s，{:.0} 事件/秒）", r.files, r.events, r.new_events, r.secs, rate);
    Ok(0)
}

fn fixture_files(args: &[String]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for a in args {
        let p = Path::new(a);
        if p.is_dir() {
            let mut v: Vec<PathBuf> = fs::read_dir(p)
                .map(|rd| rd.flatten().map(|e| e.path()).collect())
                .unwrap_or_default();
            v.retain(|f| matches!(f.extension().and_then(|e| e.to_str()), Some("json" | "jsonl")));
            v.sort();
            out.extend(v);
        } else {
            out.push(p.to_path_buf());
        }
    }
    out
}

/// Replays recorded hook stdin (one JSON object per line or per file) as if
/// Claude Code had sent it, at the time in each object's `_ts`.
fn replay(paths: &Paths, args: &[String]) -> Result<i32> {
    if args.is_empty() {
        return Err("replay needs at least one fixture path".into());
    }
    let (_lock, mut p) = locked_processor(paths, Mode::Live)?;
    let mut n = 0;
    for f in fixture_files(args) {
        let text = fs::read_to_string(&f)?;
        let docs: Vec<Value> = if f.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            text.lines().filter(|l| !l.trim().is_empty()).map(serde_json::from_str).collect::<std::result::Result<_, _>>()?
        } else {
            vec![serde_json::from_str(&text)?]
        };
        for mut v in docs {
            let ts = v
                .get("_ts")
                .and_then(Value::as_str)
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .map(|d| d.timestamp_millis())
                .unwrap_or_else(now_ms);
            if let Some(o) = v.as_object_mut() {
                o.remove("_ts");
            }
            let raw = serde_json::to_vec(&v)?;
            let env = CaptureEnv { paths, now_ms: ts, nonce: String::new(), git_lookup: false };
            let Some(ev) = capture::from_claude_hook(&v, &raw, &env) else { continue };
            spool::append(paths, &ev)?;
            n += p.ingest_spool(paths)?;
            if ev.kind == Kind::TurnEnd {
                if let Some(s) = ev.session_id.as_deref().and_then(|s| p.settlements.remove(s)) {
                    println!("{}", settlement_box(&s));
                    if let Some(badge) = snapshot::take_grand(&p.conn, ts, p.cfg.ceremony.grand_cooldown_hours)? {
                        println!("{badge}");
                    }
                }
            }
        }
    }
    println!("回放完成：{n} 个事件入库。");
    Ok(0)
}

/// Re-derives every table from `events` into a fresh database and swaps it
/// in, unless the new total would be lower than the old one (SPEC 5.5).
fn rebuild(paths: &Paths) -> Result<i32> {
    let (_lock, _) = locked_processor(paths, Mode::Rebuild)?;
    let old = db::open(&paths.db)?;
    let old_total = snapshot::counter(&old, "person_days", "all");
    let old_usd = snapshot::counter(&old, "usd", "all");
    let tmp = paths.home.join("data.rebuild.db");
    for ext in ["", "-wal", "-shm"] {
        let _ = fs::remove_file(format!("{}{ext}", tmp.display()));
    }
    let new = db::open(&tmp)?;
    {
        let mut st = old.prepare(
            "SELECT key, value FROM meta WHERE key IN ('installed_at', 'live_since', 'display_title') OR key LIKE 'spool_offset:%' OR key LIKE 'live_since:%'",
        )?;
        for (k, v) in st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?.flatten() {
            db::set_meta(&new, &k, &v)?;
        }
    }
    let mut p = Processor::new(new, Mode::Rebuild, Tz::from_env(), Config::load(paths));
    // Usage last: it prices a finished turn, and a turn that ended without a
    // Stop is only closed by a later event than its usage.
    let mut st = old.prepare("SELECT id, ts, source, kind, session_id, turn_id, cwd_hash, payload FROM events ORDER BY kind = 'usage', ts, rowid")?;
    let rows = st.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            r.get::<_, Option<String>>(4)?,
            r.get::<_, Option<String>>(5)?,
            r.get::<_, Option<String>>(6)?,
            r.get::<_, String>(7)?,
        ))
    })?;
    p.begin()?;
    let mut n = 0;
    for row in rows.flatten() {
        let (id, ts, source, kind, session_id, turn_id, cwd_hash, payload) = row;
        let mut ev = Event::new(id, ts, serde_json::from_value(json!(source))?, serde_json::from_value(json!(kind))?);
        ev.session_id = session_id;
        ev.turn_id = turn_id;
        ev.cwd_hash = cwd_hash;
        ev.payload = serde_json::from_str(&payload)?;
        if p.handle(&ev)? {
            n += 1;
        }
    }
    p.commit()?;
    let new_total = snapshot::counter(&p.conn, "person_days", "all");
    let new_usd = snapshot::counter(&p.conn, "usd", "all");
    drop(st);
    drop(p);
    if new_total + 1e-9 < old_total {
        let _ = fs::remove_file(&tmp);
        println!("未重建：新常数算出 {} 人日，少于现有的 {} 人日（只增不减）。", fmt_pd(new_total), fmt_pd(old_total));
        return Ok(1);
    }
    if new_usd + 0.005 < old_usd {
        let _ = fs::remove_file(&tmp);
        println!("未重建：新规则算出 {}，少于现有的 {}（只增不减）。", fmt_usd(new_usd), fmt_usd(old_usd));
        return Ok(1);
    }
    drop(old);
    fs::rename(&tmp, &paths.db)?;
    for ext in ["-wal", "-shm"] {
        let _ = fs::remove_file(format!("{}{ext}", paths.db.display()));
        let _ = fs::remove_file(format!("{}{ext}", tmp.display()));
    }
    println!("重建完成：{n} 个事件，{} → {}。", fmt_usd(old_usd), fmt_usd(new_usd));
    Ok(0)
}
