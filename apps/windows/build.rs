//! Puts the web pages (ui/), the art the macOS app uses (apps/widget/
//! assets: the 团子 parts, the room pictures, the boss-type scenes) and the
//! translation tables (assets/i18n) into dist/, which Tauri embeds in
//! Dango.exe. The art and the words stay in one place.

use std::fs;
use std::path::Path;

fn copy_dir(from: &Path, to: &Path, keep: &dyn Fn(&Path) -> bool) {
    fs::create_dir_all(to).unwrap();
    for e in fs::read_dir(from).unwrap_or_else(|e| panic!("{}: {e}", from.display())).flatten() {
        let p = e.path();
        if p.is_dir() {
            copy_dir(&p, &to.join(e.file_name()), keep);
        } else if keep(&p) {
            fs::copy(&p, to.join(e.file_name())).unwrap();
        }
    }
}

fn main() {
    let here = Path::new(env!("CARGO_MANIFEST_DIR"));
    let art = here.join("../widget/assets");
    let dist = here.join("dist");
    let _ = fs::remove_dir_all(&dist);
    copy_dir(&here.join("ui"), &dist, &|_| true);
    let png_or_json = |p: &Path| matches!(p.extension().and_then(|e| e.to_str()), Some("png" | "json"));
    copy_dir(&art.join("dango"), &dist.join("art/dango"), &png_or_json);
    copy_dir(&art.join("theme-b"), &dist.join("art/theme-b"), &png_or_json);
    copy_dir(&art.join("abti/scene"), &dist.join("art/scene"), &png_or_json);
    copy_dir(&here.join("../../assets/i18n"), &dist.join("i18n"), &png_or_json);
    for d in ["ui", "../widget/assets/dango", "../widget/assets/theme-b", "../widget/assets/abti/scene", "../../assets/i18n"] {
        println!("cargo:rerun-if-changed={d}");
    }
    tauri_build::build()
}
