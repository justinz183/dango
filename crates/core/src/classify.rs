//! Rule-based classifier v1 (SPEC 5.1, 5.2): task class from prompt keywords,
//! correction detection, and path/command signals. Prompts and commands are
//! inspected in memory only; callers persist the returned labels, never the text.

use crate::event::{GitAction, Role, TaskClass};

/// Checked in order; the first class with a matching keyword wins. ASCII
/// keywords match whole words (or whole word sequences), CJK ones substrings.
const KEYWORDS: &[(TaskClass, &[&str])] = &[
    (TaskClass::Migration, &["升级", "迁移到", "upgrade", "migrate", "port to"]),
    (TaskClass::Test, &["测试", "用例", "单测", "test", "tests", "spec", "coverage"]),
    (
        TaskClass::Bugfix,
        &["修复", "修一下", "修好", "报错", "bug", "fix", "broken", "fails", "failing", "crash"],
    ),
    (TaskClass::Refactor, &["重构", "整理", "抽出", "refactor", "clean up", "cleanup", "extract"]),
    (TaskClass::Docs, &["文档", "readme", "注释", "docs", "documentation", "comment", "comments"]),
    (TaskClass::Infra, &["部署", "ci", "docker", "deploy", "pipeline", "k8s", "kubernetes"]),
    (TaskClass::Data, &["数据", "sql", "迁移", "query", "schema", "etl"]),
    (TaskClass::Config, &["配置", "环境变量", "config", "env", "settings"]),
    (TaskClass::Research, &["调研", "比较", "research", "compare", "options"]),
    (TaskClass::Review, &["看看", "解释", "review", "explain", "why"]),
    (TaskClass::Feature, &["实现", "加一个", "新增", "add", "implement", "build"]),
];

pub fn classify_prompt(prompt: &str) -> TaskClass {
    let lower = prompt.to_lowercase();
    let words: Vec<&str> = lower
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '\''))
        .filter(|w| !w.is_empty())
        .collect();
    let spaced = format!(" {} ", words.join(" "));
    for (class, keys) in KEYWORDS {
        for k in *keys {
            let hit = if k.is_ascii() {
                spaced.contains(&format!(" {k} "))
            } else {
                lower.contains(k)
            };
            if hit {
                return *class;
            }
        }
    }
    TaskClass::Other
}

const CORRECTION_MARKERS: &[&str] = &[
    "不对", "错了", "不是", "重来", "撤销", "改回", "wrong", "no,", "not that", "undo", "revert",
    "that's not",
];

/// A correction is any marker inside the first 12 characters (SPEC 5.2).
pub fn is_correction(prompt: &str) -> bool {
    let head: String = prompt.trim_start().chars().take(12).collect::<String>().to_lowercase();
    let head = head.replace('’', "'");
    CORRECTION_MARKERS.iter().any(|m| head.contains(m))
}

/// Tool signals nudge the prompt class (SPEC 5.1).
pub fn final_class(prompt_class: TaskClass, test_run: bool, migration_path: bool) -> TaskClass {
    match prompt_class {
        TaskClass::Other | TaskClass::Feature | TaskClass::Data if migration_path => {
            TaskClass::Migration
        }
        TaskClass::Other if test_run => TaskClass::Test,
        c => c,
    }
}

fn segments(path: &str) -> Vec<String> {
    path.split(['/', '\\']).filter(|s| !s.is_empty()).map(|s| s.to_lowercase()).collect()
}

fn ext(path: &str) -> String {
    let name = path.rsplit(['/', '\\']).next().unwrap_or("");
    match name.rsplit_once('.') {
        Some((stem, e)) if !stem.is_empty() => e.to_lowercase(),
        _ => String::new(),
    }
}

fn file_name(path: &str) -> String {
    path.rsplit(['/', '\\']).next().unwrap_or("").to_lowercase()
}

/// Programming language of a file, by extension. Prose and data formats
/// (md, json, yaml, …) are not languages for the polyglot badge.
pub fn language_for_path(path: &str) -> Option<&'static str> {
    Some(match ext(path).as_str() {
        "ts" | "tsx" | "mts" | "cts" => "ts",
        "js" | "jsx" | "mjs" | "cjs" => "js",
        "py" | "pyi" | "ipynb" => "py",
        "rs" => "rs",
        "go" => "go",
        "java" => "java",
        "kt" | "kts" => "kotlin",
        "swift" => "swift",
        "dart" => "dart",
        "rb" => "ruby",
        "php" => "php",
        "c" | "h" => "c",
        "cc" | "cpp" | "cxx" | "hpp" | "hh" => "cpp",
        "m" | "mm" => "objc",
        "cs" => "csharp",
        "fs" => "fsharp",
        "scala" => "scala",
        "ex" | "exs" => "elixir",
        "erl" => "erlang",
        "hs" => "haskell",
        "lua" => "lua",
        "r" => "r",
        "jl" => "julia",
        "zig" => "zig",
        "sql" => "sql",
        "sh" | "bash" | "zsh" | "fish" => "shell",
        "ps1" => "powershell",
        "html" | "htm" => "html",
        "css" | "scss" | "sass" | "less" => "css",
        "vue" => "vue",
        "svelte" => "svelte",
        "tf" | "hcl" => "hcl",
        "sol" => "solidity",
        "proto" => "proto",
        _ => return None,
    })
}

pub fn is_migration_path(path: &str) -> bool {
    segments(path).iter().any(|s| s == "migrations" || s == "migrate" || s == "migration")
}

/// Role card a single file points at (SPEC 5.1, second pass). `rel` is the
/// path relative to the session's cwd when possible.
pub fn role_for_path(rel: &str) -> Option<Role> {
    let segs = segments(rel);
    let dirs = &segs[..segs.len().saturating_sub(1)];
    let name = file_name(rel);
    let e = ext(rel);
    let in_dir = |names: &[&str]| dirs.iter().any(|d| names.contains(&d.as_str()));

    if in_dir(&["auth", "crypto", "security"]) || name.contains("security") {
        return Some(Role::Security);
    }
    if in_dir(&["test", "tests", "spec", "specs", "__tests__", "e2e"])
        || name.contains(".test.")
        || name.contains(".spec.")
        || name.ends_with("_test.go")
        || (name.starts_with("test_") && e == "py")
    {
        return Some(Role::Qa);
    }
    if e == "sql" || in_dir(&["migrations", "migrate"]) {
        return Some(Role::Dba);
    }
    if name.starts_with("dockerfile")
        || name.starts_with("docker-compose")
        || matches!(e.as_str(), "yml" | "yaml" | "tf" | "hcl" | "toml" | "ini" | "conf" | "env")
        || name == ".env"
        || in_dir(&[".github", ".circleci", "k8s", "helm", "deploy"])
    {
        return Some(Role::Devops);
    }
    if matches!(e.as_str(), "md" | "mdx" | "rst" | "adoc") {
        return Some(Role::Writer);
    }
    if matches!(e.as_str(), "tsx" | "jsx" | "vue" | "svelte" | "css" | "scss" | "sass" | "less" | "html") {
        return Some(Role::Frontend);
    }
    if matches!(e.as_str(), "swift" | "kt" | "kts" | "dart" | "m" | "mm") {
        return Some(Role::Mobile);
    }
    if matches!(e.as_str(), "pt" | "onnx" | "safetensors" | "h5" | "ckpt")
        || in_dir(&["ml", "training", "models"])
        || (e == "py" && name.starts_with("train"))
    {
        return Some(Role::Ml);
    }
    if e == "ipynb" || in_dir(&["etl", "pipelines", "notebooks"]) {
        return Some(Role::Data);
    }
    if language_for_path(rel).is_some() {
        return Some(Role::Backend);
    }
    None
}

/// First path segment relative to cwd ("." for files at the root).
pub fn top_dir(rel: &str) -> String {
    let segs = segments(rel);
    if segs.len() <= 1 {
        ".".to_string()
    } else {
        segs[0].clone()
    }
}

/// The role card a finished turn counts toward (SPEC 5.1).
pub fn turn_role(class: TaskClass, file_roles: &[Role], distinct_dirs: usize) -> Option<Role> {
    let by_files = || -> Option<Role> {
        if distinct_dirs >= 3 {
            return Some(Role::Architect);
        }
        let mut best: Option<(Role, usize)> = None;
        for r in Role::ALL {
            let n = file_roles.iter().filter(|x| **x == r).count();
            if n > 0 && best.map_or(true, |(_, b)| n > b) {
                best = Some((r, n));
            }
        }
        best.map(|(r, _)| r)
    };
    match class {
        TaskClass::Feature | TaskClass::Bugfix | TaskClass::Other => by_files(),
        TaskClass::Refactor | TaskClass::Review | TaskClass::Migration => Some(Role::Architect),
        TaskClass::Test => Some(Role::Qa),
        TaskClass::Docs => Some(Role::Writer),
        TaskClass::Infra | TaskClass::Config => Some(Role::Devops),
        TaskClass::Research => Some(Role::Pm),
        TaskClass::Data => {
            if file_roles.contains(&Role::Dba) {
                Some(Role::Dba)
            } else {
                Some(Role::Data)
            }
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CommandInfo {
    pub test: bool,
    pub git: Option<GitAction>,
}

const SUBCOMMAND_RUNNERS: &[&str] = &[
    "cargo", "npm", "pnpm", "yarn", "bun", "deno", "go", "mvn", "mvnw", "gradle", "gradlew", "make",
    "just", "swift", "xcodebuild", "dotnet", "mix", "flutter", "sbt", "lein", "nx", "turbo", "zig",
];
const DIRECT_RUNNERS: &[&str] = &[
    "pytest", "py.test", "jest", "vitest", "mocha", "rspec", "phpunit", "ctest", "tox", "nox", "ava",
    "karma", "unittest", "nose2", "busted",
];

/// Spots test/CI runs and git commit/merge/push in a shell command line.
pub fn analyze_command(cmd: &str) -> CommandInfo {
    let mut info = CommandInfo::default();
    let normalized = cmd.replace("&&", "\n").replace("||", "\n").replace([';', '|'], "\n");
    for seg in normalized.lines() {
        let mut w: Vec<&str> = seg.split_whitespace().collect();
        // Strip env assignments and wrappers that do not change what runs.
        loop {
            match w.first() {
                Some(x) if x.contains('=') && !x.starts_with('-') => {
                    w.remove(0);
                }
                Some(&("sudo" | "time" | "exec" | "env" | "command" | "nice" | "npx" | "bunx" | "pnpx")) => {
                    w.remove(0);
                }
                Some(&("uv" | "poetry" | "pipenv" | "rye" | "hatch")) if w.get(1) == Some(&"run") => {
                    w.drain(..2);
                }
                Some(&("bundle" | "pnpm" | "yarn" | "npm")) if w.get(1) == Some(&"exec") => {
                    w.drain(..2);
                }
                Some(&("python" | "python3")) if w.get(1) == Some(&"-m") => {
                    w.drain(..2);
                }
                _ => break,
            }
        }
        let Some(&first) = w.first() else { continue };
        let first = first.rsplit('/').next().unwrap_or(first);
        let args: Vec<&str> = w[1..].iter().copied().filter(|a| !a.starts_with('-')).take(4).collect();

        if DIRECT_RUNNERS.contains(&first) || (first == "playwright" && args.first() == Some(&"test")) {
            info.test = true;
        } else if SUBCOMMAND_RUNNERS.contains(&first) {
            let hit = args.iter().any(|a| {
                *a == "test"
                    || a.starts_with("test:")
                    || (*a == "t" && matches!(first, "cargo" | "npm" | "pnpm" | "yarn"))
                    || (*a == "nextest" && first == "cargo")
                    || (*a == "verify" && first.starts_with("mvn"))
                    || (*a == "check" && matches!(first, "gradle" | "gradlew" | "make" | "just"))
            });
            if hit {
                info.test = true;
            }
        } else if first == "gh" {
            match (args.first(), args.get(1)) {
                (Some(&"pr"), Some(&"checks")) | (Some(&"run"), Some(&("watch" | "view"))) => info.test = true,
                (Some(&"pr"), Some(&"merge")) => info.git = Some(GitAction::Merge),
                _ => {}
            }
        } else if first == "git" {
            // Skip global options such as `-C dir` / `-c key=val`.
            let mut i = 1;
            while i < w.len() && w[i].starts_with('-') {
                i += if matches!(w[i], "-C" | "-c") { 2 } else { 1 };
            }
            let action = match w.get(i) {
                Some(&"commit") => Some(GitAction::Commit),
                Some(&"merge") => Some(GitAction::Merge),
                Some(&"push") => Some(GitAction::Push),
                _ => None,
            };
            // Commit/merge outrank push when one line does both.
            if let Some(a) = action {
                if info.git.is_none() || info.git == Some(GitAction::Push) {
                    info.git = Some(a);
                }
            }
        }
    }
    info
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_keyword_hits_its_class() {
        for (class, keys) in KEYWORDS {
            for k in *keys {
                assert_eq!(classify_prompt(k), *class, "keyword {k:?}");
                assert_eq!(classify_prompt(&format!("please {k} it")), *class, "in sentence {k:?}");
            }
        }
    }

    #[test]
    fn ascii_keywords_need_word_boundaries() {
        assert_eq!(classify_prompt("address the prefix"), TaskClass::Other);
        assert_eq!(classify_prompt("修改一下这个函数的名字"), TaskClass::Other);
        assert_eq!(classify_prompt("No match here"), TaskClass::Other);
        assert_eq!(classify_prompt("Fix the login crash"), TaskClass::Bugfix);
        assert_eq!(classify_prompt("帮我实现一个登录页"), TaskClass::Feature);
        assert_eq!(classify_prompt("把数据库迁移到 Postgres"), TaskClass::Migration);
    }

    #[test]
    fn corrections_only_count_in_the_head() {
        for p in ["不对，应该是另一个", "错了", "wrong file", "No, the other one", "undo that", "That’s not it"] {
            assert!(is_correction(p), "{p}");
        }
        assert!(!is_correction("Add a button. Actually that's not needed... wrong"));
        assert!(!is_correction("Nothing to see"));
    }

    #[test]
    fn tool_signals_bias_the_class() {
        assert_eq!(final_class(TaskClass::Other, true, false), TaskClass::Test);
        assert_eq!(final_class(TaskClass::Feature, true, true), TaskClass::Migration);
        assert_eq!(final_class(TaskClass::Bugfix, true, true), TaskClass::Bugfix);
    }

    #[test]
    fn roles_from_paths() {
        assert_eq!(role_for_path("src/App.tsx"), Some(Role::Frontend));
        assert_eq!(role_for_path("db/migrations/001.sql"), Some(Role::Dba));
        assert_eq!(role_for_path("Dockerfile"), Some(Role::Devops));
        assert_eq!(role_for_path("tests/test_api.py"), Some(Role::Qa));
        assert_eq!(role_for_path("README.md"), Some(Role::Writer));
        assert_eq!(role_for_path("ios/App/View.swift"), Some(Role::Mobile));
        assert_eq!(role_for_path("src/auth/session.rs"), Some(Role::Security));
        assert_eq!(role_for_path("analysis.ipynb"), Some(Role::Data));
        assert_eq!(role_for_path("scripts/train_model.py"), Some(Role::Ml));
        assert_eq!(role_for_path("server/main.go"), Some(Role::Backend));
        assert_eq!(role_for_path("package.json"), None);
    }

    #[test]
    fn three_directories_make_an_architect() {
        let roles = [Role::Backend, Role::Frontend, Role::Backend];
        assert_eq!(turn_role(TaskClass::Feature, &roles, 3), Some(Role::Architect));
        assert_eq!(turn_role(TaskClass::Feature, &roles, 2), Some(Role::Backend));
        assert_eq!(turn_role(TaskClass::Other, &[], 0), None);
        assert_eq!(turn_role(TaskClass::Docs, &roles, 1), Some(Role::Writer));
    }

    #[test]
    fn commands() {
        let t = |c: &str| analyze_command(c).test;
        assert!(t("cargo test -p core"));
        assert!(t("cd web && pnpm -C apps test 2>&1 | tail -20"));
        assert!(t("npm run test:unit"));
        assert!(t("uv run pytest -q"));
        assert!(t("python3 -m pytest tests/"));
        assert!(t("CI=1 npx vitest run"));
        assert!(t("go test ./..."));
        assert!(t("gh pr checks 42"));
        assert!(!t("cargo check"));
        assert!(!t("cargo build --release"));
        assert!(!t("echo test"));
        let g = |c: &str| analyze_command(c).git;
        assert_eq!(g("git add -A && git commit -m 'x'"), Some(GitAction::Commit));
        assert_eq!(g("git -C repo merge main"), Some(GitAction::Merge));
        assert_eq!(g("git push origin main"), Some(GitAction::Push));
        assert_eq!(g("git commit -m x && git push"), Some(GitAction::Commit));
        assert_eq!(g("gh pr merge 12 --squash"), Some(GitAction::Merge));
        assert_eq!(g("git status"), None);
    }
}
