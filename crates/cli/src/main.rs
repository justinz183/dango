//! dango — hook handler, daemon and CLI in one binary (SPEC 3).

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
use dango_core::event::{Event, Kind};
use dango_core::render::{fmt_pd, fmt_usd, settlement_box};

const USAGE: &str = "dango（打工团子）— 你的 AI 替你干了多少活、请人来做要花多少钱

用法:
  dango hook                  Claude Code hook 入口（从 stdin 读 JSON）
  dango status [--claude]     一行状态；--claude 供 statusLine 使用
  dango stats                 公司页
  dango badges                成就与职业图鉴
  dango widget                启动桌面小部件（屏幕右下角）
  dango report [--week|--month|--year] [--day DATE] [--tool claude|codex|deepseek|workbuddy] [--names] [--json]
                                   日报 / 周报 / 月报（DATE = YYYY-MM-DD | today | yesterday，
                                   周报取 DATE 所在的周，月报取所在的月）
  dango card [--week|--month|--year] [--day DATE] [--out PNG] [--no-open]
                                   导出 4:5 分享图（和报告窗口同一套设计）到 ~/Pictures/DANGO/ 并复制到剪贴板
  dango abti [--json] | dango abti --report day|week|month|year|total [--day DATE]
                                   老板人格的结果 / 报告窗口一页的数据（JSON）
  dango panel [--no-open]     生成并打开本地网页面板（办公室、成就、周报）
  dango backfill [--claude-dir DIR]
                                   导入安装前的 Claude Code 历史
  dango daemon                前台运行守护进程
  dango replay PATH...        回放 hook fixtures（.json / .jsonl / 目录）
  dango rebuild [--allow-lower]  从事件表重建全部派生数据（--allow-lower：你同意总数变少）
  dango privacy-scan          扫描本地数据，确认没有路径、代码或 prompt

数据目录: ~/.dango（可用 DANGO_HOME 覆盖）";
const USAGE_EN: &str = "dango — how much work your AI did, and what hiring people for it would cost

Usage:
  dango hook                  Claude Code hook entry (reads JSON on stdin)
  dango status [--claude]     one-line status; --claude for statusLine
  dango stats                 output page
  dango widget                start the desktop pet (bottom-right corner)
  dango lang [zh|en|ko|ja|fr|es]  show or set the language
  dango report [--week|--month|--year] [--day DATE] [--tool claude|codex|deepseek|workbuddy] [--names] [--json]
                                   day / week / month / year report (DATE = YYYY-MM-DD | today | yesterday;
                                   the week, month or year that contains DATE)
  dango card [--week|--month|--year] [--day DATE] [--out PNG] [--no-open]
                                   export the 4:5 share image (the report window's design) to ~/Pictures/DANGO/ and copy it
  dango abti [--json] | dango abti --report day|week|month|year|total [--day DATE]
                                   the AI boss type, or one report window page (JSON)
  dango backfill [--claude-dir DIR]
                                   import Claude Code and Codex history from before install
  dango daemon                run the daemon in the foreground
  dango rebuild [--allow-lower]  rebuild everything derived from the event log (--allow-lower: you accept a lower total)
  dango privacy-scan          check local data holds no paths, code or prompts

Data directory: ~/.dango (override with DANGO_HOME)";


fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let paths = Paths::from_env();
    let code = match args.first().map(String::as_str) {
        Some("hook") => hook::run(&paths, args.get(1).map(String::as_str) == Some("--codex")),
        Some(cmd) => match dispatch(cmd, &args[1..], &paths) {
            Ok(code) => code,
            Err(e) => {
                eprintln!("dango {cmd}: {e}");
                1
            }
        },
        None => {
            println!("{}", usage(&paths));
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
        "lang" => lang(paths, args),
        "report" => report(paths, args),
        "abti" => abti(paths, args),
        "card" => card(paths, args),
        "daemon" => server::run(paths).map(|_| 0),
        "replay" => replay(paths, args),
        "rebuild" => rebuild(paths, args.iter().any(|a| a == "--allow-lower")),
        "privacy-scan" => privacy::scan(paths),
        "version" | "--version" | "-V" => {
            println!("dango {}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        "help" | "--help" | "-h" => {
            println!("{}", usage(paths));
            Ok(0)
        }
        other => Err(format!("unknown command {other:?}\n\n{}", usage(paths)).into()),
    }
}

/// The help text in the configured language.
fn usage(paths: &Paths) -> &'static str {
    if Config::load(paths).lang().en() { USAGE_EN } else { USAGE }
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
    daemon::paths::user_home().unwrap_or_default().join(".claude")
}

/// $HOME (%USERPROFILE% on Windows), or the same error `env::var` gives.
fn home() -> std::result::Result<PathBuf, std::env::VarError> {
    daemon::paths::user_home().ok_or(std::env::VarError::NotPresent)
}

/// Opens a file with its default app: `open` on a Mac, `start` on Windows.
fn open_path(path: &Path) -> std::io::Result<std::process::ExitStatus> {
    if cfg!(windows) {
        std::process::Command::new("cmd").args(["/C", "start", ""]).arg(path).status()
    } else {
        std::process::Command::new("open").arg(path).status()
    }
}

fn parse_day(args: &[String]) -> Result<chrono::NaiveDate> {
    let today = Tz::from_env().date(now_ms());
    Ok(match flag(args, "--day").as_deref() {
        None | Some("today") | Some("今天") => today,
        Some("yesterday") | Some("昨天") => today.pred_opt().unwrap(),
        Some(d) => chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").map_err(|_| format!("日期格式应为 YYYY-MM-DD，收到 {d:?}"))?,
    })
}

/// `--tool claude|codex|deepseek|workbuddy`: one agent's work only (sessions.source).
fn parse_tool(args: &[String]) -> Result<Option<&'static str>> {
    Ok(match flag(args, "--tool").as_deref() {
        None | Some("all") => None,
        Some("claude" | "claude_code" | "claude-code") => Some("claude_code"),
        Some("codex") => Some("codex"),
        Some("deepseek" | "dsh") => Some("deepseek"),
        Some("workbuddy" | "wb") => Some("workbuddy"),
        Some(t) => return Err(format!("--tool 只接 claude、codex、deepseek 或 workbuddy，收到 {t:?}").into()),
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

/// `dango abti`: the boss type (老板人格) and what the card and the story
/// show, as JSON with --json. `dango abti --report day|week|month|year|total
/// [--day DATE]`: one report window page.
fn abti(paths: &Paths, args: &[String]) -> Result<i32> {
    let now = now_ms();
    let tz = Tz::from_env();
    let v = match flag(args, "--report") {
        Some(kind) => {
            let day = parse_day(args)?;
            fresh_db(paths, |c, cfg| daemon::abti::report(c, tz, cfg, &claude_dir(), &kind, day, now))?
        }
        None => fresh_db(paths, |c, cfg| daemon::abti::result(c, tz, cfg, now))?,
    };
    if args.iter().any(|a| a == "--json") || v["kind"].is_string() {
        println!("{}", serde_json::to_string_pretty(&v)?);
    } else {
        let pct = |x: &Value| format!("{:.0}%", x.as_f64().unwrap_or(0.0) * 100.0);
        println!("{} {} — {}", v["code"].as_str().unwrap_or(""), v["type"]["name"].as_str().unwrap_or(""), v["type"]["roast"].as_str().unwrap_or(""));
        for d in v["dims"].as_array().into_iter().flatten() {
            let name = d["names"][d["winner"].as_u64().unwrap_or(0) as usize].as_str().unwrap_or("");
            let shown = if d["id"] == "range" { format!("{} / 8", d["roles"]) } else { pct(&d["pct"]) };
            println!("  {} {name} {shown}", d["letter"].as_str().unwrap_or(""));
        }
        println!("  {} · {} · {}", fmt_usd(v["usd"].as_f64().unwrap_or(0.0)), v["scale"]["name"].as_str().unwrap_or(""), v["margin_tier"]["name"].as_str().unwrap_or(""));
    }
    Ok(0)
}

/// The card renderer: the app this dango came in (Contents/Helpers/dango,
/// apps/widget/package.sh), Dango.app when installed, else the widget binary.
fn renderer() -> Result<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    let exe = std::env::current_exe()?;
    let candidates = [
        exe.parent().and_then(Path::parent).map(|c| c.join("MacOS/Dango")).filter(|_| exe.parent().is_some_and(|d| d.ends_with("Contents/Helpers"))).unwrap_or_default(),
        PathBuf::from("/Applications/Dango.app/Contents/MacOS/Dango"),
        PathBuf::from(format!("{home}/Applications/Dango.app/Contents/MacOS/Dango")),
        exe.with_file_name("dango-widget"),
    ];
    candidates.into_iter().find(|p| !p.as_os_str().is_empty() && p.exists()).ok_or_else(|| "没有找到 Dango.app，先运行 apps/widget/bundle.sh".into())
}

/// `dango card [--week|--month|--year] [--day DATE]`: the period's 4:5
/// share image, drawn by the app in the report window's design, saved to
/// ~/Pictures/DANGO and copied. Share images never carry project names or
/// session titles.
fn card(paths: &Paths, args: &[String]) -> Result<i32> {
    if cfg!(windows) {
        // The share images are drawn by the macOS app; the Windows app does
        // not draw them yet.
        return Err(Config::load(paths).lang().t("Windows 版还不能出分享图", "The Windows version cannot make share images yet").into());
    }
    let kind = ["week", "month", "year"].into_iter().find(|k| args.iter().any(|a| *a == format!("--{k}"))).unwrap_or("day");
    let day = parse_day(args)?;
    let (tz, now) = (Tz::from_env(), now_ms());
    let r = fresh_db(paths, |c, cfg| daemon::abti::report(c, tz, cfg, &claude_dir(), kind, day, now))?;
    let date = format!("{kind}-{}", r["from"].as_str().unwrap_or(""));
    let cards = paths.home.join("cards");
    fs::create_dir_all(&cards)?;
    let json_path = cards.join(format!("{date}.json"));
    daemon::paths::write_private(&json_path, serde_json::to_string(&r)?.as_bytes())?;
    let out = match flag(args, "--out") {
        Some(o) => PathBuf::from(o),
        None => {
            let dir = home()?.join("Pictures").join("DANGO");
            fs::create_dir_all(&dir)?;
            dir.join(format!("dango-{date}.png"))
        }
    };
    let status = std::process::Command::new(renderer()?).arg("--abti").arg(&json_path).arg(&out).args(["--page", "share", "--copy"]).status()?;
    if !status.success() {
        return Err("渲染失败".into());
    }
    if r["lang"] == "en" {
        let what = match kind { "week" => "Week image", "month" => "Month image", "year" => "Year image", _ => "Day image" };
        println!("{what}: {} (copied to the clipboard)", out.display());
    } else {
        let what = match kind { "week" => "周报图", "month" => "月报图", "year" => "年报图", _ => "日报图" };
        println!("{what}：{}（已复制到剪贴板）", out.display());
    }
    if !args.iter().any(|a| a == "--no-open") {
        open_path(&out)?;
    }
    Ok(0)
}

/// `dango lang [zh|en|ko|ja|fr|es]`: shows or sets the language of everything shown,
/// and rewrites widget.json so the widget switches at once.
fn lang(paths: &Paths, args: &[String]) -> Result<i32> {
    let Some(want) = args.first() else {
        println!("{}", Config::load(paths).lang().code());
        return Ok(0);
    };
    let w = want.to_lowercase();
    let locale = match w.as_str() {
        "zh" | "zh-cn" | "cn" | "中文" => "zh-CN",
        _ => match dango_core::i18n::Lang::ALL.into_iter().find(|l| w == l.code() || w == l.name().to_lowercase()) {
            Some(l) => l.code(),
            None => return Err(format!("dango lang zh|en|ko|ja|fr|es (got {other:?})", other = want).into()),
        },
    };
    Config::set_locale(paths, locale)?;
    fresh_db(paths, |c, cfg| daemon::widget::write(paths, c, Tz::from_env(), cfg, now_ms()))?;
    let l = Config::load(paths).lang();
    println!("{}", l.f("界面语言：{}", "Language: {}", &[l.name()]));
    Ok(0)
}

/// Starts the desktop widget with fresh data to show: Dango.app when
/// it is installed (apps/widget/bundle.sh), else the bare binary next to
/// this one. The widget itself refuses to run twice.
fn widget(paths: &Paths) -> Result<i32> {
    fresh_db(paths, |c, cfg| daemon::widget::write(paths, c, Tz::from_env(), cfg, now_ms()))?;
    if cfg!(windows) {
        return windows_widget(paths);
    }
    let home = std::env::var("HOME").unwrap_or_default();
    let apps = [PathBuf::from("/Applications/Dango.app"), PathBuf::from(format!("{home}/Applications/Dango.app"))];
    if let Some(app) = apps.iter().find(|a| a.exists()) {
        std::process::Command::new("open").arg("-a").arg(app).status()?;
        println!("{}", Config::load(paths).lang().t("打工团子已打开，在屏幕右下角。右键可退出或设置登录时自动启动。", "Dango is open in the bottom-right corner. Right-click it to quit or start it at login."));
        return Ok(0);
    }
    let exe = std::env::current_exe()?.with_file_name("dango-widget");
    if !exe.exists() {
        return Err(format!("没有找到 Dango.app 或 {}，先运行 apps/widget/bundle.sh", exe.display()).into());
    }
    std::process::Command::new(exe)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    println!("{}", Config::load(paths).lang().t("打工团子已启动，在屏幕右下角。右键可退出或设置登录时自动启动。", "Dango started in the bottom-right corner. Right-click it to quit or start it at login."));
    Ok(0)
}

/// Windows: Dango.exe from the installer (this dango sits in its bin
/// folder), or the dev build next to this one (apps/windows).
fn windows_widget(paths: &Paths) -> Result<i32> {
    let exe = std::env::current_exe()?;
    let local = std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("Dango").join("Dango.exe"));
    let candidates = [exe.parent().and_then(Path::parent).map(|d| d.join("Dango.exe")), local, Some(exe.with_file_name("dango-desktop.exe"))];
    let lang = Config::load(paths).lang();
    let Some(app) = candidates.into_iter().flatten().find(|p| p.is_file()) else {
        return Err(lang.t("没有找到 Dango.exe，先装 Windows 安装包（apps/windows）", "Dango.exe not found: install the Windows app first (apps/windows)").into());
    };
    std::process::Command::new(app)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    println!("{}", lang.t("打工团子已打开，在屏幕右下角。右键托盘图标可以换语言和外观。", "Dango is open in the bottom-right corner. Right-click the tray icon for language and appearance."));
    Ok(0)
}

fn status(paths: &Paths, claude: bool) -> Result<i32> {
    if !claude {
        return with_fresh_db(paths, |c, cfg| snapshot::status(c, Tz::from_env(), now_ms(), None, cfg.lang()));
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
        None => println!("{}", fs::read_to_string(&paths.status_cache).unwrap_or_else(|_| format!("▮ {}", Config::load(paths).lang().t("打工团子", "Dango")))),
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
        open_path(&page)?;
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
            None => home()?.join(default),
        })
    };
    let (claude_dir, codex_dir, dsh_dir) = (dir("--claude-dir", ".claude")?, dir("--codex-dir", ".codex")?, dir("--dsh-dir", ".dsh")?);
    let codex = Config::load(paths).sources.codex && codex_dir.join("sessions").is_dir();
    if !claude_dir.join("projects").is_dir() && !codex {
        println!("没有找到 {}/projects 或 {}/sessions，跳过回填。", claude_dir.display(), codex_dir.display());
        return Ok(0);
    }
    let (_lock, mut p) = locked_processor(paths, Mode::Backfill)?;
    let since = |key: &str| -> Result<i64> { Ok(db::get_meta(&p.conn, key)?.and_then(|v| v.parse().ok()).unwrap_or_else(now_ms)) };
    // Codex comes from its logs with the same ids either way: all of it.
    let (cutoff, codex_cutoff) = (since("live_since")?, now_ms());
    println!("正在整理 Claude Code{} 的历史…", if codex { " 和 Codex" } else { "" });
    let r = backfill::run(&mut p, paths, &claude_dir, cutoff, codex.then_some((codex_dir.as_path(), codex_cutoff)))?;
    // DeepSeek Harness, like Codex, from its own logs: all of it.
    if Config::load(paths).sources.deepseek {
        daemon::dsh::import(&mut p, paths, &dsh_dir, now_ms())?;
    }
    // WorkBuddy too, from ~/.workbuddy-ai or ~/.workbuddy (or --wb-root).
    let wb_root = dir("--wb-root", "")?;
    if Config::load(paths).sources.workbuddy {
        daemon::workbuddy::import(&mut p, paths, &wb_root, now_ms())?;
    }
    daemon::usage::fill(&mut p, &claude_dir, &codex_dir, &dsh_dir, &wb_root, now_ms(), usize::MAX)?;
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
/// `allow_lower`: the user has agreed that new rules may lower the total
/// (2026-10-29, prose at 2,000 words an hour); otherwise it only goes up.
fn rebuild(paths: &Paths, allow_lower: bool) -> Result<i32> {
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
    if new_total + 1e-9 < old_total && !allow_lower {
        let _ = fs::remove_file(&tmp);
        println!("未重建：新常数算出 {} 人日，少于现有的 {} 人日（只增不减）。", fmt_pd(new_total), fmt_pd(old_total));
        return Ok(1);
    }
    if new_usd + 0.005 < old_usd && !allow_lower {
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
    if Config::load(paths).lang().en() {
        println!("Rebuilt: {n} events, {} → {}.", fmt_usd(old_usd), fmt_usd(new_usd));
    } else {
        println!("重建完成：{n} 个事件，{} → {}。", fmt_usd(old_usd), fmt_usd(new_usd));
    }
    Ok(0)
}
