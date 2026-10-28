//! Value categories (DESIGN.md §3): the four kinds of work a turn can be,
//! for reports and share cards. Every task class maps to exactly one.

use crate::event::TaskClass;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Category {
    Build,
    Fix,
    Guard,
    Learn,
    Other,
}

impl Category {
    pub const ALL: [Category; 5] = [Category::Build, Category::Fix, Category::Guard, Category::Learn, Category::Other];

    pub fn of(class: TaskClass) -> Category {
        match class {
            TaskClass::Feature | TaskClass::Migration | TaskClass::Data | TaskClass::Infra => Category::Build,
            TaskClass::Bugfix | TaskClass::Refactor | TaskClass::Config => Category::Fix,
            TaskClass::Test | TaskClass::Review => Category::Guard,
            TaskClass::Docs | TaskClass::Research => Category::Learn,
            TaskClass::Other => Category::Other,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Category::Build => "build",
            Category::Fix => "fix",
            Category::Guard => "guard",
            Category::Learn => "learn",
            Category::Other => "other",
        }
    }

    pub fn name_zh(self) -> &'static str {
        match self {
            Category::Build => "建造",
            Category::Fix => "修缮",
            Category::Guard => "守护",
            Category::Learn => "沉淀",
            Category::Other => "其他",
        }
    }

    pub fn tagline(self) -> &'static str {
        match self {
            Category::Build => "做出了新东西",
            Category::Fix => "让旧东西更好",
            Category::Guard => "保证质量",
            Category::Learn => "写下来、想清楚",
            Category::Other => "没认出来的",
        }
    }

    pub fn color(self) -> &'static str {
        match self {
            Category::Build => "#5b8c7e",
            Category::Fix => "#d9955b",
            Category::Guard => "#6f8fc9",
            Category::Learn => "#a98fd0",
            Category::Other => "#b8b0a2",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_class_has_a_category() {
        for c in TaskClass::ALL {
            let cat = Category::of(c);
            assert!(Category::ALL.contains(&cat));
        }
        assert_eq!(Category::of(TaskClass::Feature), Category::Build);
        assert_eq!(Category::of(TaskClass::Refactor), Category::Fix);
        assert_eq!(Category::of(TaskClass::Review), Category::Guard);
        assert_eq!(Category::of(TaskClass::Research), Category::Learn);
        assert_eq!(Category::of(TaskClass::Other), Category::Other);
    }
}
