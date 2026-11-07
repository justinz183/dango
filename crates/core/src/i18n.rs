//! The interface language (config `general.locale`). Chinese and English are
//! written side by side in the code (`t(中, 英)`); Korean, Japanese, French
//! and Spanish come from assets/i18n/<code>.json, which map the English text
//! to theirs (user, 2026-11-08: 「中英韩日法西」). A sentence with numbers or
//! names in it is a template with `{}` holes (`f`); a translation may number
//! them `{0}`, `{1}` to put them in its own order. Text a table lacks stays
//! English (tools/i18n_check.py lists what is missing).

use std::collections::HashMap;
use std::sync::OnceLock;

/// Which language text is written in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Lang {
    #[default]
    Zh,
    En,
    Ko,
    Ja,
    Fr,
    Es,
}

impl Lang {
    /// Every language, in the order the menus list them.
    pub const ALL: [Lang; 6] = [Lang::Zh, Lang::En, Lang::Ko, Lang::Ja, Lang::Fr, Lang::Es];

    /// "en-US" → English, "ja_JP" → Japanese, …; anything else is Chinese.
    pub fn parse(s: &str) -> Lang {
        let s = s.trim().to_lowercase();
        Lang::ALL.into_iter().find(|l| s.starts_with(l.code())).unwrap_or(Lang::Zh)
    }

    /// "zh", "en", "ko", "ja", "fr" or "es", as widget.json and reports carry it.
    pub fn code(self) -> &'static str {
        match self {
            Lang::Zh => "zh",
            Lang::En => "en",
            Lang::Ko => "ko",
            Lang::Ja => "ja",
            Lang::Fr => "fr",
            Lang::Es => "es",
        }
    }

    /// The language's own name, for menus.
    pub fn name(self) -> &'static str {
        match self {
            Lang::Zh => "中文",
            Lang::En => "English",
            Lang::Ko => "한국어",
            Lang::Ja => "日本語",
            Lang::Fr => "Français",
            Lang::Es => "Español",
        }
    }

    /// The text in this language: the Chinese, the English, or the English
    /// looked up in this language's table.
    pub fn t<'a>(self, zh: &'a str, en: &'a str) -> &'a str {
        match self {
            Lang::Zh => zh,
            Lang::En => en,
            l => tr(l, en),
        }
    }

    /// A sentence with `{}` holes, filled in order.
    pub fn f(self, zh: &str, en: &str, args: &[&str]) -> String {
        fill(self.t(zh, en), args)
    }

    pub fn en(self) -> bool {
        self == Lang::En
    }

    /// Chinese stays Chinese, every other language reads English: for the
    /// terminal's text reports, which are not translated.
    pub fn zh_or_en(self) -> Lang {
        if self == Lang::Zh { Lang::Zh } else { Lang::En }
    }
}

fn table(lang: Lang) -> Option<&'static HashMap<String, String>> {
    static T: OnceLock<[HashMap<String, String>; 4]> = OnceLock::new();
    let all = T.get_or_init(|| {
        let p = |s: &str| serde_json::from_str(s).expect("assets/i18n");
        [
            p(include_str!("../../../assets/i18n/ko.json")),
            p(include_str!("../../../assets/i18n/ja.json")),
            p(include_str!("../../../assets/i18n/fr.json")),
            p(include_str!("../../../assets/i18n/es.json")),
        ]
    });
    match lang {
        Lang::Ko => Some(&all[0]),
        Lang::Ja => Some(&all[1]),
        Lang::Fr => Some(&all[2]),
        Lang::Es => Some(&all[3]),
        _ => None,
    }
}

/// The English text in another language (the English if its table lacks it).
pub fn tr(lang: Lang, en: &str) -> &str {
    table(lang).and_then(|t| t.get(en)).map(|s| s.as_str()).unwrap_or(en)
}

/// Fills `{}` holes in order, or numbered `{0}`, `{1}` holes by number.
pub fn fill(tpl: &str, args: &[&str]) -> String {
    let mut out = tpl.to_string();
    if (0..args.len()).any(|i| out.contains(&format!("{{{i}}}"))) {
        for (i, a) in args.iter().enumerate() {
            out = out.replace(&format!("{{{i}}}"), a);
        }
        return out;
    }
    for a in args {
        match out.find("{}") {
            Some(i) => out.replace_range(i..i + 2, a),
            None => break,
        }
    }
    out
}

/// "a software engineer", "an architect": a job name inside an English sentence.
pub fn a_job(name: &str) -> String {
    let lower = lower_first(name);
    let article = if lower.starts_with(['a', 'e', 'i', 'o', 'u']) { "an" } else { "a" };
    format!("{article} {lower}")
}

/// "Software engineer" → "software engineer" (acronyms like "QA" stay).
pub fn lower_first(s: &str) -> String {
    let mut c = s.chars();
    match (c.next(), c.clone().next()) {
        (Some(f), Some(n)) if n.is_uppercase() => format!("{f}{}", c.as_str()),
        (Some(f), _) => format!("{}{}", f.to_lowercase(), c.as_str()),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn language_and_articles() {
        assert_eq!(Lang::parse("zh-CN"), Lang::Zh);
        assert_eq!(Lang::parse("en-US"), Lang::En);
        assert_eq!(Lang::En.t("今天", "today"), "today");
        assert_eq!(a_job("Architect"), "an architect");
        assert_eq!(a_job("Software engineer"), "a software engineer");
        assert_eq!(a_job("QA engineer"), "a QA engineer");
    }

    #[test]
    fn six_languages_and_templates() {
        assert_eq!(Lang::parse("ja_JP"), Lang::Ja);
        assert_eq!(Lang::parse("es-419"), Lang::Es);
        assert_eq!(Lang::parse("de"), Lang::Zh);
        for l in Lang::ALL {
            assert_eq!(Lang::parse(l.code()), l);
        }
        assert_eq!(fill("{} of {}", &["a", "b"]), "a of b");
        assert_eq!(fill("{1}의 {0}", &["a", "b"]), "b의 a");
        // Text a table lacks stays English.
        assert_eq!(Lang::Fr.t("没有这句", "No such line in any table"), "No such line in any table");
    }
}
