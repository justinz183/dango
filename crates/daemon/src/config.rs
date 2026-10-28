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
git_hook = false

[scoring]
version = "1.0"
classifier_v2 = false

[value]
hourly_rate_usd = 0        # 0 = 不显示金额；填你自己的时薪后，报告里会多一行 ≈ $

[character]
name = "Claude"            # 小部件里那个角色的名字

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
    pub value: ValueCfg,
    pub character: Character,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Character {
    pub name: String,
}

impl Default for Character {
    fn default() -> Character {
        Character { name: "Claude".into() }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ValueCfg {
    pub hourly_rate_usd: f64,
}

impl Default for ValueCfg {
    fn default() -> ValueCfg {
        ValueCfg { hourly_rate_usd: 0.0 }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct General {
    pub weekly_target: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Sources {
    pub claude_code: bool,
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
            value: ValueCfg::default(),
            character: Character::default(),
        }
    }
}
impl Default for General {
    fn default() -> General {
        General { weekly_target: 0.0 }
    }
}
impl Default for Sources {
    fn default() -> Sources {
        Sources { claude_code: true }
    }
}
impl Default for Ceremony {
    fn default() -> Ceremony {
        Ceremony { grand_cooldown_hours: 4.0 }
    }
}

impl Config {
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
        assert!(c.sources.claude_code);
        assert_eq!(c.ceremony.grand_cooldown_hours, 4.0);
        assert_eq!(c.value.hourly_rate_usd, 0.0);
        assert_eq!(c.character.name, "Claude");
    }
}
