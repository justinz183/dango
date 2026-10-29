//! The interface language: Chinese or English (config `general.locale`).

/// Which language text is written in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Lang {
    #[default]
    Zh,
    En,
}

impl Lang {
    /// "en", "en-US", "English" → English; anything else is Chinese.
    pub fn parse(s: &str) -> Lang {
        if s.trim().to_lowercase().starts_with("en") {
            Lang::En
        } else {
            Lang::Zh
        }
    }

    /// "zh" or "en", as widget.json and reports carry it.
    pub fn code(self) -> &'static str {
        match self {
            Lang::Zh => "zh",
            Lang::En => "en",
        }
    }

    /// The Chinese or the English text.
    pub fn t<'a>(self, zh: &'a str, en: &'a str) -> &'a str {
        match self {
            Lang::Zh => zh,
            Lang::En => en,
        }
    }

    pub fn en(self) -> bool {
        self == Lang::En
    }
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
}
