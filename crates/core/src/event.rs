//! The unified event record every capture source normalizes into (SPEC 4.6).
//! Payloads carry derived values only: never prompt text, code, commands or paths.

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    ClaudeCode,
    Codex,
    Git,
    Backfill,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::ClaudeCode => "claude_code",
            Source::Codex => "codex",
            Source::Git => "git",
            Source::Backfill => "backfill",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    SessionStart,
    Prompt,
    Tool,
    SubagentStop,
    TurnEnd,
    Notification,
    SessionEnd,
    Commit,
    PreCompact,
    /// A finished turn's token usage by model, read from the agent's logs.
    Usage,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::SessionStart => "session_start",
            Kind::Prompt => "prompt",
            Kind::Tool => "tool",
            Kind::SubagentStop => "subagent_stop",
            Kind::TurnEnd => "turn_end",
            Kind::Notification => "notification",
            Kind::SessionEnd => "session_end",
            Kind::Commit => "commit",
            Kind::PreCompact => "pre_compact",
            Kind::Usage => "usage",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskClass {
    Feature,
    Bugfix,
    Refactor,
    Test,
    Docs,
    Infra,
    Data,
    Review,
    Migration,
    Config,
    Research,
    Other,
}

impl TaskClass {
    pub const ALL: [TaskClass; 12] = [
        TaskClass::Feature,
        TaskClass::Bugfix,
        TaskClass::Refactor,
        TaskClass::Test,
        TaskClass::Docs,
        TaskClass::Infra,
        TaskClass::Data,
        TaskClass::Review,
        TaskClass::Migration,
        TaskClass::Config,
        TaskClass::Research,
        TaskClass::Other,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            TaskClass::Feature => "feature",
            TaskClass::Bugfix => "bugfix",
            TaskClass::Refactor => "refactor",
            TaskClass::Test => "test",
            TaskClass::Docs => "docs",
            TaskClass::Infra => "infra",
            TaskClass::Data => "data",
            TaskClass::Review => "review",
            TaskClass::Migration => "migration",
            TaskClass::Config => "config",
            TaskClass::Research => "research",
            TaskClass::Other => "other",
        }
    }

    pub fn parse(s: &str) -> Option<TaskClass> {
        TaskClass::ALL.into_iter().find(|c| c.as_str() == s)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitAction {
    Commit,
    Merge,
    Push,
}

impl GitAction {
    pub fn as_str(self) -> &'static str {
        match self {
            GitAction::Commit => "commit",
            GitAction::Merge => "merge",
            GitAction::Push => "push",
        }
    }
}

/// Role cards (SPEC 7.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Frontend,
    Backend,
    Dba,
    Devops,
    Qa,
    Writer,
    Security,
    Data,
    Mobile,
    Architect,
    Pm,
    Ml,
}

impl Role {
    pub const ALL: [Role; 12] = [
        Role::Frontend,
        Role::Backend,
        Role::Dba,
        Role::Devops,
        Role::Qa,
        Role::Writer,
        Role::Security,
        Role::Data,
        Role::Mobile,
        Role::Architect,
        Role::Pm,
        Role::Ml,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Role::Frontend => "frontend",
            Role::Backend => "backend",
            Role::Dba => "dba",
            Role::Devops => "devops",
            Role::Qa => "qa",
            Role::Writer => "writer",
            Role::Security => "security",
            Role::Data => "data",
            Role::Mobile => "mobile",
            Role::Architect => "architect",
            Role::Pm => "pm",
            Role::Ml => "ml",
        }
    }

    pub fn parse(s: &str) -> Option<Role> {
        Role::ALL.into_iter().find(|r| r.as_str() == s)
    }
}

/// Derived signals only. Every field is optional; a tool event fills the tool
/// fields, a prompt event the classification fields, and so on.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Payload {
    /// For `source = backfill`: the tool the history came from.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<Source>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task_class: Option<TaskClass>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_correction: Option<bool>,
    /// How many times in a row this exact prompt was sent (1 = first time).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_repeat: Option<u32>,
    /// Other topics the prompt scored just as high for: the session keeps
    /// the one it is already on.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub topic_ties: Option<Vec<String>>,
    /// SessionStart `source`: startup | resume | clear | compact | fork.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_source: Option<String>,
    /// edit | write | bash | agent
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub files_touched: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines_added: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines_removed: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub test_cmd: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub test_passed: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub git_action: Option<GitAction>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subagents: Option<u32>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub languages: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub roles: Vec<Role>,
    /// 12-hex digests of absolute file paths (identity only, never the path).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub file_ids: Vec<String>,
    /// 12-hex digests of the top-level directory each file sits in.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub dir_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_ages_days_max: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub migration_path: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_hook_active: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notification_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Who would have done this step (an occupation id, docs/DESIGN.md v3).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub occupation: Option<String>,
    /// Minutes that person would have needed for it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub minutes: Option<f64>,
    /// Words of prose added (counted, never kept).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub words: Option<u32>,
    /// What the prompt (or a connector) is about: an occupation id.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub topic: Option<String>,
    /// Before v6 a finance prompt was this flag; read, never written, so
    /// that replaying old events (rebuild) still pays them as finance. The
    /// old `translate` flag is let go: it only turned writing into
    /// translation, which pays less.
    #[serde(skip_serializing)]
    pub finance: Option<bool>,
    /// Usage events: tokens by price key (model, "@long" over the
    /// long-context threshold). Counts only.
    #[serde(skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub tokens: std::collections::BTreeMap<String, crate::pricing::Tokens>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Event {
    pub v: u32,
    pub id: String,
    /// RFC 3339, UTC, millisecond precision.
    pub ts: String,
    pub source: Source,
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd_hash: Option<String>,
    #[serde(default)]
    pub payload: Payload,
}

impl Payload {
    /// The topic, from older events' flags too, as the occupation it
    /// counts as now (a merged one is its representative).
    pub fn topic(&self) -> Option<String> {
        let t = self.topic.clone().or_else(|| (self.finance == Some(true)).then(|| "fin".to_string()))?;
        Some(crate::occupation::Table::builtin().canon(&t).to_string())
    }
}

impl Event {
    pub fn new(id: String, ts_ms: i64, source: Source, kind: Kind) -> Event {
        Event {
            v: SCHEMA_VERSION,
            id,
            ts: format_ts(ts_ms),
            source,
            kind,
            session_id: None,
            turn_id: None,
            cwd_hash: None,
            payload: Payload::default(),
        }
    }

    pub fn ts_ms(&self) -> Option<i64> {
        DateTime::parse_from_rfc3339(&self.ts).ok().map(|d| d.timestamp_millis())
    }

    /// The tool that produced the activity (backfilled events keep their origin).
    pub fn origin(&self) -> Source {
        self.payload.origin.unwrap_or(self.source)
    }
}

pub fn format_ts(ms: i64) -> String {
    DateTime::<Utc>::from_timestamp_millis(ms)
        .unwrap_or_default()
        .to_rfc3339_opts(SecondsFormat::Millis, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_skips_empty_fields() {
        let mut e = Event::new("evt_1".into(), 1_793_000_000_000, Source::ClaudeCode, Kind::Tool);
        e.payload.lines_added = Some(3);
        let s = serde_json::to_string(&e).unwrap();
        assert!(!s.contains("languages"));
        assert!(!s.contains("session_id"));
        let back: Event = serde_json::from_str(&s).unwrap();
        assert_eq!(back, e);
        assert_eq!(back.ts_ms(), Some(1_793_000_000_000));
    }

    #[test]
    fn old_topic_flags_still_read() {
        let p: Payload = serde_json::from_str(r#"{"finance":true}"#).unwrap();
        assert_eq!(p.topic().as_deref(), Some("fin"));
        assert!(!serde_json::to_string(&p).unwrap().contains("finance"));
        let p: Payload = serde_json::from_str(r#"{"finance":true,"topic":"doctor"}"#).unwrap();
        assert_eq!(p.topic().as_deref(), Some("doctor"));
        let p: Payload = serde_json::from_str(r#"{"topic":"vet"}"#).unwrap();
        assert_eq!(p.topic().as_deref(), Some("doctor"), "merged into the doctor");
        let p: Payload = serde_json::from_str(r#"{"translate":true}"#).unwrap();
        assert_eq!(p.topic(), None);
    }
}
