//! config.toml (SPEC 13). Unknown keys are ignored so the file can carry
//! settings for later milestones.

use std::fs;

use serde::Deserialize;

use crate::paths::{write_private, Paths};

pub const DEFAULT_CONFIG: &str = r#"[general]
locale = "zh-CN"
weekly_target = 0          # 0 = automatic (SPEC 6.3); any other value pins the target
quiet_hours = ["23:00", "08:00"]
autostart = true

[sources]
claude_code = true
codex = true
deepseek = true
workbuddy = true
git_hook = false

[scoring]
version = "1.0"
classifier_v2 = false

[character]
name = ""                  # 角色的名字；空 = 中文叫"团子"，英文叫"Dango"

[ceremony]
sound = true
volume = 0.6
grand_cooldown_hours = 4
reduce_motion = "system"   # system | always | never

[social]
enabled = false
anonymous_stats = false
"#;

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Config {
    pub general: General,
    pub sources: Sources,
    pub ceremony: Ceremony,
    pub character: Character,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Character {
    pub name: String,
}

impl Default for Character {
    fn default() -> Character {
        Character { name: String::new() }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct General {
    pub weekly_target: f64,
    /// "zh-CN" or "en": the language of everything shown.
    pub locale: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Sources {
    pub claude_code: bool,
    pub codex: bool,
    /// DeepSeek Harness, read from ~/.dsh (dsh.rs).
    pub deepseek: bool,
    /// WorkBuddy, read from ~/.workbuddy-ai or ~/.workbuddy (workbuddy.rs).
    pub workbuddy: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Ceremony {
    pub grand_cooldown_hours: f64,
}

impl Default for Config {
    fn default() -> Config {
        Config {
            general: General::default(),
            sources: Sources::default(),
            ceremony: Ceremony::default(),
            character: Character::default(),
        }
    }
}
impl Default for General {
    fn default() -> General {
        General { weekly_target: 0.0, locale: "zh-CN".into() }
    }
}
impl Default for Sources {
    fn default() -> Sources {
        Sources { claude_code: true, codex: true, deepseek: true, workbuddy: true }
    }
}
impl Default for Ceremony {
    fn default() -> Ceremony {
        Ceremony { grand_cooldown_hours: 4.0 }
    }
}

impl Config {
    pub fn lang(&self) -> dango_core::i18n::Lang {
        dango_core::i18n::Lang::parse(&self.general.locale)
    }

    /// The character's name: the one set, else 团子 / Dango.
    pub fn character_name(&self) -> String {
        let n = self.character.name.trim();
        if n.is_empty() { self.lang().t("团子", "Dango").to_string() } else { n.to_string() }
    }

    /// Writes the language into config.toml, keeping everything else.
    pub fn set_locale(paths: &Paths, locale: &str) -> std::io::Result<()> {
        let _ = Config::load(paths);
        let s = fs::read_to_string(&paths.config).unwrap_or_default();
        let line = format!("locale = \"{locale}\"");
        let mut out = Vec::new();
        let (mut section, mut done) = (String::new(), false);
        for l in s.lines() {
            let t = l.trim();
            if t.starts_with('[') {
                if section == "[general]" && !done {
                    out.push(line.clone());
                    done = true;
                }
                section = t.to_string();
            }
            if section == "[general]" && t.starts_with("locale") && t[6..].trim_start().starts_with('=') {
                if !done {
                    out.push(line.clone());
                    done = true;
                }
                continue;
            }
            out.push(l.to_string());
        }
        if !done {
            if section != "[general]" {
                out.push("[general]".into());
            }
            out.push(line);
        }
        write_private(&paths.config, (out.join("\n") + "\n").as_bytes())
    }

    /// Reads config.toml, writing the default file first if there is none.
    /// A malformed file falls back to defaults rather than stopping capture.
    pub fn load(paths: &Paths) -> Config {
        match fs::read_to_string(&paths.config) {
            Ok(s) => toml::from_str(&s).unwrap_or_default(),
            Err(_) => {
                let _ = paths.ensure().and_then(|_| write_private(&paths.config, DEFAULT_CONFIG.as_bytes()));
                Config::default()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_file_parses() {
        let c: Config = toml::from_str(DEFAULT_CONFIG).unwrap();
        assert_eq!(c.general.weekly_target, 0.0);
        assert!(c.sources.claude_code && c.sources.codex);
        assert_eq!(c.ceremony.grand_cooldown_hours, 4.0);
        assert_eq!(c.character_name(), "团子");
        assert_eq!(c.lang(), dango_core::i18n::Lang::Zh);
    }

    #[test]
    fn locale_is_written_in_place() {
        let dir = std::env::temp_dir().join(format!("dango-cfg-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let p = Paths::at(&dir);
        Config::set_locale(&p, "en").unwrap();
        let c = Config::load(&p);
        assert_eq!(c.lang(), dango_core::i18n::Lang::En);
        assert_eq!(c.character_name(), "Dango");
        assert_eq!(c.ceremony.grand_cooldown_hours, 4.0, "the rest is kept");
        Config::set_locale(&p, "zh-CN").unwrap();
        let s = fs::read_to_string(&p.config).unwrap();
        assert_eq!(s.matches("locale").count(), 1, "{s}");
        assert_eq!(Config::load(&p).lang(), dango_core::i18n::Lang::Zh);
        let _ = fs::remove_dir_all(&dir);
    }
}
