//! SQLite schema (SPEC 13). `events` is the only source of truth; every other
//! table can be rebuilt from it with `dango rebuild`.

use std::path::Path;

use rusqlite::{Connection, OptionalExtension};

pub const SCHEMA_VERSION: &str = "1";

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS events (
  id          TEXT PRIMARY KEY,
  ts          INTEGER NOT NULL,
  source      TEXT NOT NULL,
  kind        TEXT NOT NULL,
  session_id  TEXT,
  turn_id     TEXT,
  cwd_hash    TEXT,
  payload     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS events_session ON events(session_id, ts);

CREATE TABLE IF NOT EXISTS sessions (
  id             TEXT PRIMARY KEY,
  source         TEXT NOT NULL,
  started_at     INTEGER NOT NULL,
  ended_at       INTEGER,
  active_minutes REAL NOT NULL DEFAULT 0,
  human_minutes  REAL NOT NULL DEFAULT 0,
  leverage       REAL,
  subagents_max  INTEGER NOT NULL DEFAULT 0,
  files_touched  INTEGER NOT NULL DEFAULT 0,
  state          TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS turns (
  id            TEXT PRIMARY KEY,
  session_id    TEXT NOT NULL REFERENCES sessions(id),
  started_at    INTEGER NOT NULL,
  ended_at      INTEGER,
  task_class    TEXT NOT NULL,
  role_card     TEXT,
  is_correction INTEGER NOT NULL DEFAULT 0,
  files_touched INTEGER NOT NULL DEFAULT 0,
  lines_added   INTEGER NOT NULL DEFAULT 0,
  lines_removed INTEGER NOT NULL DEFAULT 0,
  test_run      INTEGER NOT NULL DEFAULT 0,
  test_passed   INTEGER,
  git_action    TEXT,
  subagents     INTEGER NOT NULL DEFAULT 0,
  human_minutes REAL NOT NULL DEFAULT 0,
  credited_pd   REAL NOT NULL DEFAULT 0,
  scoring_version TEXT NOT NULL,
  agg           TEXT NOT NULL DEFAULT '{}',
  -- Credited minutes per occupation (JSON) and what hiring them would cost.
  work          TEXT NOT NULL DEFAULT '{}',
  usd           REAL NOT NULL DEFAULT 0,
  -- Model tokens by price key (JSON), what they cost at API prices, and
  -- whether the turn's usage event has been applied.
  tokens        TEXT NOT NULL DEFAULT '{}',
  cost_usd      REAL NOT NULL DEFAULT 0,
  cost_done     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS turns_session ON turns(session_id, started_at);

CREATE TABLE IF NOT EXISTS daily (
  day            TEXT PRIMARY KEY,
  person_days    REAL NOT NULL,
  active_minutes REAL NOT NULL,
  turns          INTEGER NOT NULL,
  sessions       INTEGER NOT NULL,
  is_active      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS counters (
  metric TEXT NOT NULL,
  scope  TEXT NOT NULL,
  value  REAL NOT NULL,
  PRIMARY KEY (metric, scope)
);

CREATE TABLE IF NOT EXISTS unlocks (
  achievement_id TEXT NOT NULL,
  tier           INTEGER NOT NULL,
  unlocked_at    INTEGER NOT NULL,
  backfilled     INTEGER NOT NULL DEFAULT 0,
  celebrated     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (achievement_id, tier)
);

CREATE TABLE IF NOT EXISTS ceremonies (
  id         TEXT PRIMARY KEY,
  level      TEXT NOT NULL,
  kind       TEXT NOT NULL,
  ref        TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  shown_at   INTEGER
);

CREATE TABLE IF NOT EXISTS wallet (
  id            INTEGER PRIMARY KEY CHECK (id = 1),
  coins         INTEGER NOT NULL DEFAULT 0,
  freeze_tokens INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO wallet (id) VALUES (1);

CREATE TABLE IF NOT EXISTS inventory (
  item_id     TEXT PRIMARY KEY,
  acquired_at INTEGER NOT NULL,
  source      TEXT NOT NULL,
  placed_at   TEXT
);

CREATE TABLE IF NOT EXISTS records (
  key   TEXT PRIMARY KEY,
  value REAL NOT NULL,
  at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS friends (
  friend_id  TEXT PRIMARY KEY,
  display    TEXT NOT NULL,
  added_at   INTEGER NOT NULL,
  last_sync  INTEGER
);

-- For the "deleted recent agent-written lines" badge: per file id, how many
-- lines the agent wrote and when (no paths are stored).
CREATE TABLE IF NOT EXISTS agent_files (
  file_id    TEXT PRIMARY KEY,
  last_write INTEGER NOT NULL,
  lines      INTEGER NOT NULL
);

-- Session title and project folder name, read from the session's own
-- transcript (DESIGN.md §4). Local only; off share cards unless asked.
CREATE TABLE IF NOT EXISTS session_meta (
  session_id   TEXT PRIMARY KEY,
  project      TEXT,
  title        TEXT,
  looked_up_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"#;

pub fn open(path: &Path) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    init(&conn)?;
    for p in [path.to_path_buf(), path.with_extension("db-wal"), path.with_extension("db-shm")] {
        if p.exists() {
            let _ = crate::paths::set_private(&p);
        }
    }
    Ok(conn)
}

pub fn open_memory() -> rusqlite::Result<Connection> {
    let conn = Connection::open_in_memory()?;
    init(&conn)?;
    Ok(conn)
}

fn init(conn: &Connection) -> rusqlite::Result<()> {
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.execute_batch(SCHEMA)?;
    // Databases from before occupations (docs/DESIGN.md §3) and model costs (v5) lack these.
    let has = |c: &str| conn.prepare(&format!("SELECT 1 FROM pragma_table_info('turns') WHERE name = '{c}'"))?.exists([]);
    if !has("usd")? {
        conn.execute_batch(
            "ALTER TABLE turns ADD COLUMN work TEXT NOT NULL DEFAULT '{}';
             ALTER TABLE turns ADD COLUMN usd REAL NOT NULL DEFAULT 0;",
        )?;
    }
    if !has("cost_usd")? {
        conn.execute_batch(
            "ALTER TABLE turns ADD COLUMN tokens TEXT NOT NULL DEFAULT '{}';
             ALTER TABLE turns ADD COLUMN cost_usd REAL NOT NULL DEFAULT 0;
             ALTER TABLE turns ADD COLUMN cost_done INTEGER NOT NULL DEFAULT 0;",
        )?;
    }
    conn.execute(
        "INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?1)",
        [SCHEMA_VERSION],
    )?;
    Ok(())
}

pub fn get_meta(conn: &Connection, key: &str) -> rusqlite::Result<Option<String>> {
    conn.query_row("SELECT value FROM meta WHERE key = ?1", [key], |r| r.get(0)).optional()
}

pub fn set_meta(conn: &Connection, key: &str, value: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [key, value],
    )?;
    Ok(())
}
