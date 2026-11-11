//! DANGO for Windows (Tauri v2): the corner 团子, its panel and a tray icon,
//! as apps/widget (Swift, macOS only) has them. The pages are in ui/ and
//! read the widget.json the daemon writes.
//!
//! The same Dango.exe is the daemon when started with `--daemon`: that is
//! what the login item runs, and a GUI program opens no console window.
//! The command line (`dango.exe`, crates/cli) sits in the install's bin\.

#![cfg_attr(windows, windows_subsystem = "windows")]

mod autostart;

use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use daemon::config::Config;
use daemon::paths::Paths;
use dango_core::i18n::Lang;
use serde_json::{json, Value};
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent, Wry};

/// The pet window (PetView.size on a Mac), logical pixels.
const PET: (f64, f64) = (230.0, 140.0);
/// The 团子 in it (theme.swift `cardRect`, y down): only it takes the pointer.
const HIT: (f64, f64, f64, f64) = (73.0, 56.0, 84.0, 74.0);
/// The panel (440 wide on a Mac) and the room around it for its shadow.
const PANEL_W: f64 = 440.0;
const PANEL_MARGIN: f64 = 12.0;

struct Shared {
    paths: Paths,
    prefs_file: PathBuf,
    prefs: Mutex<Value>,
    /// The panel's content height (logical), as the page measured it.
    panel_h: Mutex<f64>,
    /// When the panel hid on losing focus: a click on the tray icon right
    /// after only closed it.
    hidden_at: Mutex<Option<Instant>>,
    /// When the panel opened: a focus change while it comes up is not the
    /// person clicking elsewhere.
    shown_at: Mutex<Option<Instant>>,
    /// The pet moved: save its place once it has stopped.
    moved_at: Mutex<Option<Instant>>,
}

impl Shared {
    fn pref(&self, k: &str) -> Value {
        self.prefs.lock().unwrap()[k].clone()
    }
    fn set_pref(&self, k: &str, v: Value) {
        let mut p = self.prefs.lock().unwrap();
        p[k] = v;
        if let Some(dir) = self.prefs_file.parent() {
            let _ = fs::create_dir_all(dir);
        }
        let _ = fs::write(&self.prefs_file, p.to_string());
    }
    fn appearance(&self) -> String {
        self.pref("appearance").as_str().unwrap_or("system").to_string()
    }
    /// The interface language (config.toml, which `dango lang` and the
    /// menu write).
    fn lang(&self) -> Lang {
        Config::load(&self.paths).lang()
    }
}

fn main() {
    let paths = Paths::from_env();
    if std::env::args().any(|a| a == "--daemon") {
        log_to_file(&paths);
        if let Err(e) = daemon::server::run(&paths) {
            eprintln!("dango daemon: {e}");
            std::process::exit(1);
        }
        return;
    }
    // One 团子 at a time.
    let _ = paths.ensure();
    let Ok(lock) = File::create(paths.home.join("widget.lock")) else { return };
    if lock.try_lock().is_err() {
        return;
    }
    ensure_daemon(&paths);

    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![widget, appearance, toggle_panel, close_panel, panel_height, pet_menu, daily_report])
        .on_menu_event(|app, e| on_menu(app, e.id().as_ref()))
        .on_window_event(|w, e| match (w.label(), e) {
            ("panel", WindowEvent::Focused(false)) => {
                let app = w.app_handle();
                let opening = app.state::<Shared>().shown_at.lock().unwrap().is_some_and(|t| t.elapsed() < Duration::from_millis(500));
                if w.is_visible().unwrap_or(false) && !opening {
                    *app.state::<Shared>().hidden_at.lock().unwrap() = Some(Instant::now());
                    hide_panel(app);
                }
            }
            ("pet", WindowEvent::Moved(_)) => *w.app_handle().state::<Shared>().moved_at.lock().unwrap() = Some(Instant::now()),
            _ => {}
        })
        .setup(move |app| {
            let prefs_file = app.path().app_config_dir()?.join("prefs.json");
            let prefs = fs::read_to_string(&prefs_file).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_else(|| json!({}));
            app.manage(Shared {
                paths: paths.clone(),
                prefs_file,
                prefs: Mutex::new(prefs),
                panel_h: Mutex::new(760.0),
                hidden_at: Mutex::new(None),
                shown_at: Mutex::new(None),
                moved_at: Mutex::new(None),
            });
            let handle = app.handle();
            let pet = WebviewWindowBuilder::new(handle, "pet", WebviewUrl::App("pet.html".into()))
                .title("Dango")
                .inner_size(PET.0, PET.1)
                .decorations(false)
                .transparent(true)
                .shadow(false)
                .always_on_top(true)
                .skip_taskbar(true)
                .resizable(false)
                .focusable(false)
                .visible(false)
                .build()?;
            place_pet(&pet, saved_pet(handle));
            pet.show()?;
            WebviewWindowBuilder::new(handle, "panel", WebviewUrl::App("panel.html".into()))
                .title("DANGO")
                .inner_size(PANEL_W + 2.0 * PANEL_MARGIN, 760.0)
                .decorations(false)
                .transparent(true)
                .shadow(false)
                .always_on_top(true)
                .skip_taskbar(true)
                .resizable(false)
                .visible(false)
                .build()?;
            TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().cloned().ok_or("no icon")?)
                .tooltip("DANGO")
                .menu(&menu(handle)?)
                .show_menu_on_left_click(false)
                .on_tray_icon_event(|tray, e| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                        toggle(tray.app_handle());
                    }
                })
                .build(app)?;
            let h = handle.clone();
            std::thread::spawn(move || watch(h));
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Dango could not start");
}

// MARK: the daemon

/// The daemon is this program with --daemon. Its login item points here,
/// unless it points at another dango that exists (a developer's own build,
/// as with ~/.local/bin/dango on a Mac); the first time, the 团子 starts at
/// login too. Starts the daemon when none runs.
fn ensure_daemon(paths: &Paths) {
    if !cfg!(windows) {
        // On a Mac launchd runs the daemon (apps/widget); this build is for looking.
        return;
    }
    let Ok(exe) = std::env::current_exe() else { return };
    let mine = format!("\"{}\" --daemon", exe.display());
    let current = autostart::get(autostart::DAEMON);
    let other = current.clone().filter(|c| autostart::program(c).map(PathBuf::from).is_some_and(|p| p != exe && p.is_file()));
    let fresh = other.is_none() && current.as_deref() != Some(mine.as_str());
    if fresh {
        autostart::set(autostart::DAEMON, &mine);
        if autostart::get(autostart::PET).is_none() {
            autostart::set(autostart::PET, &format!("\"{}\"", exe.display()));
        }
    }
    if !daemon_running(paths) {
        start(other.as_deref().unwrap_or(&mine));
    }
}

/// A daemon holds the processor lock while it runs.
fn daemon_running(paths: &Paths) -> bool {
    matches!(daemon::server::try_lock(paths), Ok(None))
}

/// Runs a login item's command line in the background.
fn start(command: &str) {
    let Some(program) = autostart::program(command) else { return };
    let rest = command.trim().trim_start_matches('"').strip_prefix(program).unwrap_or("").trim_start_matches('"');
    let mut c = std::process::Command::new(program);
    c.args(rest.split_whitespace()).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        use windows_sys::Win32::System::Threading::{CREATE_NO_WINDOW, DETACHED_PROCESS};
        c.creation_flags(DETACHED_PROCESS | CREATE_NO_WINDOW);
    }
    let _ = c.spawn();
}

/// The daemon's messages go to daemon.log next to its data, as launchd
/// sends them on a Mac (a GUI program has nowhere else to write).
fn log_to_file(paths: &Paths) {
    let _ = paths.ensure();
    #[cfg(windows)]
    if let Ok(f) = fs::OpenOptions::new().create(true).append(true).open(paths.home.join("daemon.log")) {
        use std::os::windows::io::IntoRawHandle;
        use windows_sys::Win32::System::Console::{SetStdHandle, STD_ERROR_HANDLE};
        // SAFETY: the handle is ours and stays open for the process's life.
        unsafe {
            SetStdHandle(STD_ERROR_HANDLE, f.into_raw_handle() as _);
        }
    }
}

// MARK: the pet and the panel

/// Where the pet stood last time (physical), if that is still on a screen.
fn saved_pet(app: &AppHandle) -> Option<PhysicalPosition<i32>> {
    let p = app.state::<Shared>().pref("pet");
    let (x, y) = (p[0].as_i64()? as i32, p[1].as_i64()? as i32);
    let on_screen = app.available_monitors().ok()?.iter().any(|m| {
        let a = m.work_area();
        x + 40 > a.position.x && x < a.position.x + a.size.width as i32 && y + 40 > a.position.y && y < a.position.y + a.size.height as i32
    });
    on_screen.then_some(PhysicalPosition::new(x, y))
}

/// The pet at `at`, or in the bottom-right corner above the taskbar.
fn place_pet(pet: &WebviewWindow, at: Option<PhysicalPosition<i32>>) {
    let at = at.or_else(|| {
        let m = pet.primary_monitor().ok()??;
        let (a, k) = (m.work_area(), m.scale_factor());
        Some(PhysicalPosition::new(
            a.position.x + a.size.width as i32 - ((PET.0 + 12.0) * k) as i32,
            a.position.y + a.size.height as i32 - ((PET.1 + 4.0) * k) as i32,
        ))
    });
    if let Some(p) = at {
        let _ = pet.set_position(p);
    }
}

fn panel_open(app: &AppHandle) -> bool {
    app.get_webview_window("panel").and_then(|w| w.is_visible().ok()).unwrap_or(false)
}

/// The panel grows up and to the left from where the pet stands and stays
/// on its screen, at most the screen's height less 32 (App.expand).
fn place_panel(app: &AppHandle) {
    let (Some(pet), Some(panel)) = (app.get_webview_window("pet"), app.get_webview_window("panel")) else { return };
    let (Ok(pos), Ok(size)) = (pet.outer_position(), pet.outer_size()) else { return };
    let k = pet.scale_factor().unwrap_or(1.0);
    let m = pet.current_monitor().ok().flatten().or_else(|| pet.primary_monitor().ok().flatten());
    let (ax, ay, aw, ah) = m.map(|m| {
        let a = m.work_area();
        (a.position.x as f64, a.position.y as f64, a.size.width as f64, a.size.height as f64)
    }).unwrap_or((0.0, 0.0, 1920.0 * k, 1080.0 * k));
    let content = *app.state::<Shared>().panel_h.lock().unwrap();
    let w = (PANEL_W + 2.0 * PANEL_MARGIN) * k;
    let h = ((content + 2.0 * PANEL_MARGIN) * k).min(ah - 32.0 * k);
    let x = (pos.x as f64 + size.width as f64 - w).clamp(ax, (ax + aw - w).max(ax));
    let y = (pos.y as f64 + size.height as f64 - h).clamp(ay, (ay + ah - h).max(ay));
    let _ = panel.set_size(PhysicalSize::new(w.round() as u32, h.round() as u32));
    let _ = panel.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
}

fn show_panel(app: &AppHandle) {
    let (Some(pet), Some(panel)) = (app.get_webview_window("pet"), app.get_webview_window("panel")) else { return };
    place_panel(app);
    *app.state::<Shared>().shown_at.lock().unwrap() = Some(Instant::now());
    let _ = app.emit_to("panel", "shown", ());
    let _ = panel.show();
    let _ = panel.set_focus();
    let _ = pet.hide();
    refresh_menu(app);
}

fn hide_panel(app: &AppHandle) {
    if let Some(panel) = app.get_webview_window("panel") {
        let _ = panel.hide();
    }
    if let Some(pet) = app.get_webview_window("pet") {
        let _ = pet.show();
    }
    refresh_menu(app);
}

fn toggle(app: &AppHandle) {
    if panel_open(app) {
        hide_panel(app);
    } else if app.state::<Shared>().hidden_at.lock().unwrap().take().is_none_or(|t| t.elapsed() > Duration::from_millis(400)) {
        show_panel(app);
    }
}

/// Every 50 ms: clicks go through the pet's window except on the 团子 (the
/// page hears when the pointer is on it); the pet's place is saved once it
/// stops moving; every 30 s the daemon is started again if it stopped
/// (launchd's KeepAlive on a Mac); the menu follows the language.
fn watch(app: AppHandle) {
    let mut inside: Option<bool> = None;
    let mut tick: u64 = 0;
    let mut lang = app.state::<Shared>().lang();
    loop {
        std::thread::sleep(Duration::from_millis(50));
        tick += 1;
        let st = app.state::<Shared>();
        if let Some(pet) = app.get_webview_window("pet").filter(|p| p.is_visible().unwrap_or(false)) {
            if let (Ok(c), Ok(p), Ok(k)) = (app.cursor_position(), pet.outer_position(), pet.scale_factor()) {
                let (x, y) = ((c.x - p.x as f64) / k, (c.y - p.y as f64) / k);
                let now = x >= HIT.0 && x <= HIT.0 + HIT.2 && y >= HIT.1 && y <= HIT.1 + HIT.3;
                if inside != Some(now) {
                    inside = Some(now);
                    let _ = pet.set_ignore_cursor_events(!now);
                    let _ = app.emit_to("pet", "hover", now);
                }
            }
        }
        let moved = *st.moved_at.lock().unwrap();
        if moved.is_some_and(|t| t.elapsed() > Duration::from_millis(600)) {
            *st.moved_at.lock().unwrap() = None;
            if let Some(p) = app.get_webview_window("pet").and_then(|w| w.outer_position().ok()) {
                st.set_pref("pet", json!([p.x, p.y]));
            }
        }
        if tick % 40 == 0 && st.lang() != lang {
            lang = st.lang();
            refresh_menu(&app);
        }
        if cfg!(windows) && tick % 600 == 0 && !daemon_running(&st.paths) {
            if let Some(c) = autostart::get(autostart::DAEMON) {
                start(&c);
            }
        }
    }
}

// MARK: the menu (the tray icon's, and the pet's right-click)

fn menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let st = app.state::<Shared>();
    let l = st.lang();
    let open = if panel_open(app) { l.t("收起仪表盘", "Close dashboard") } else { l.t("打开仪表盘", "Open dashboard") };
    let open = MenuItem::with_id(app, "toggle", open, true, None::<&str>)?;
    // Each language in its own name; "Language" stays beside the word, so
    // the menu is found in any language (as on a Mac).
    let langs: Vec<CheckMenuItem<Wry>> = Lang::ALL
        .into_iter()
        .map(|x| CheckMenuItem::with_id(app, format!("lang:{}", x.code()), x.name(), true, x == l, None::<&str>))
        .collect::<tauri::Result<_>>()?;
    let title = if l.en() { "Language".to_string() } else { format!("{} / Language", l.t("语言", "Language")) };
    let langs = Submenu::with_items(app, title, true, &langs.iter().map(|m| m as &dyn tauri::menu::IsMenuItem<Wry>).collect::<Vec<_>>())?;
    let look = st.appearance();
    let looks: Vec<CheckMenuItem<Wry>> = [("system", l.t("跟随系统", "Match the system")), ("light", l.t("浅色", "Light")), ("dark", l.t("深色（白团子）", "Dark (white dango)"))]
        .into_iter()
        .map(|(id, title)| CheckMenuItem::with_id(app, format!("look:{id}"), title, true, look == id, None::<&str>))
        .collect::<tauri::Result<_>>()?;
    let looks = Submenu::with_items(app, l.t("外观", "Appearance"), true, &[&looks[0], &looks[1], &looks[2]])?;
    let login = CheckMenuItem::with_id(app, "login", l.t("登录时自动启动", "Start at login"), cfg!(windows), autostart::get(autostart::PET).is_some(), None::<&str>)?;
    let corner = MenuItem::with_id(app, "corner", l.t("回到右下角", "Back to the corner"), true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", l.t("退出", "Quit"), true, None::<&str>)?;
    Menu::with_items(app, &[&open, &PredefinedMenuItem::separator(app)?, &langs, &looks, &login, &corner, &PredefinedMenuItem::separator(app)?, &quit])
}

fn refresh_menu(app: &AppHandle) {
    if let (Some(tray), Ok(m)) = (app.tray_by_id("main"), menu(app)) {
        let _ = tray.set_menu(Some(m));
    }
}

fn on_menu(app: &AppHandle, id: &str) {
    let st = app.state::<Shared>();
    match id {
        "toggle" => toggle(app),
        code if code.starts_with("lang:") => {
            // As `dango lang`: the daemon sees config.toml change and
            // rewrites widget.json in that language.
            if let Some(l) = Lang::ALL.into_iter().find(|l| l.code() == &code[5..]) {
                let _ = Config::set_locale(&st.paths, if l == Lang::Zh { "zh-CN" } else { l.code() });
                let _ = app.emit("reload", ());
            }
        }
        "login" => {
            if autostart::get(autostart::PET).is_some() {
                autostart::remove(autostart::PET);
            } else if let Ok(exe) = std::env::current_exe() {
                autostart::set(autostart::PET, &format!("\"{}\"", exe.display()));
            }
        }
        "corner" => {
            hide_panel(app);
            if let Some(pet) = app.get_webview_window("pet") {
                place_pet(&pet, None);
            }
            *st.moved_at.lock().unwrap() = None;
            st.set_pref("pet", Value::Null);
        }
        "quit" => app.exit(0),
        look if look.starts_with("look:") => {
            st.set_pref("appearance", json!(&look[5..]));
            let _ = app.emit("appearance", &look[5..]);
        }
        _ => {}
    }
    refresh_menu(app);
}

// MARK: what the pages ask for

/// widget.json as the daemon wrote it.
#[tauri::command]
fn widget(st: tauri::State<Shared>) -> Option<String> {
    fs::read_to_string(st.paths.home.join("widget.json")).ok()
}

/// "system", "light" or "dark".
#[tauri::command]
fn appearance(st: tauri::State<Shared>) -> String {
    st.appearance()
}

#[tauri::command]
fn toggle_panel(app: AppHandle) {
    toggle(&app);
}

#[tauri::command]
fn close_panel(app: AppHandle) {
    hide_panel(&app);
}

/// The page's height changed (the roster opened, new data).
#[tauri::command]
fn panel_height(app: AppHandle, height: f64) {
    *app.state::<Shared>().panel_h.lock().unwrap() = height.clamp(200.0, 4000.0);
    if panel_open(&app) {
        place_panel(&app);
    }
}

#[tauri::command]
fn pet_menu(app: AppHandle, window: tauri::Window) {
    if let Ok(m) = menu(&app) {
        let _ = window.popup_menu(&m);
    }
}

/// The day's, this week's or this month's report as text (`kind`: the
/// panel's range), for the clipboard: no session titles or project names
/// (`dango report` without --names).
#[tauri::command]
fn daily_report(st: tauri::State<Shared>, kind: Option<String>) -> Result<String, String> {
    let paths = &st.paths;
    let _ = daemon::server::request(paths, &json!({ "op": "flush" }), Duration::from_secs(3));
    let conn = daemon::db::open(&paths.db).map_err(|e| e.to_string())?;
    let (cfg, tz, now) = (Config::load(paths), daemon::ingest::Tz::from_env(), daemon::server::now_ms());
    let claude = daemon::paths::user_home().unwrap_or_default().join(".claude");
    // The panel's range: 1 day → today's, 7 days → this week's, 30 days → this month's.
    let report = match kind.as_deref() {
        Some("week") => daemon::report::week,
        Some("month") => daemon::report::month,
        _ => daemon::report::day,
    };
    let r = report(&conn, tz, &cfg, Path::new(&claude), tz.date(now), now, false, None).map_err(|e| e.to_string())?;
    Ok(daemon::report::text(&r))
}
