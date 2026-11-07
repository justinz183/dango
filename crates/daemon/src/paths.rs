//! Where everything lives: ~/.dango, or $DANGO_HOME. Installs from before
//! the rename keep ~/.shadowcorp (and $SHADOWCORP_HOME) until moved.

use std::fs;
use std::io;
#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

#[derive(Debug, Clone)]
pub struct Paths {
    pub home: PathBuf,
    pub spool: PathBuf,
    pub db: PathBuf,
    pub config: PathBuf,
    pub state: PathBuf,
    pub sock: PathBuf,
    pub lock: PathBuf,
    pub status_cache: PathBuf,
    pub salt: PathBuf,
}

/// Unix socket paths are limited to ~104 bytes on macOS.
const MAX_SOCK_PATH: usize = 100;

impl Paths {
    pub fn at(home: impl Into<PathBuf>) -> Paths {
        let home: PathBuf = home.into();
        let mut sock = home.join("daemon.sock");
        if sock.as_os_str().len() > MAX_SOCK_PATH {
            let h = hex(&Sha256::digest(home.as_os_str().as_encoded_bytes()))[..12].to_string();
            sock = std::env::temp_dir().join(format!("dango-{h}.sock"));
        }
        Paths {
            spool: home.join("spool"),
            db: home.join("data.db"),
            config: home.join("config.toml"),
            state: home.join("state"),
            lock: home.join("processor.lock"),
            status_cache: home.join("status.cache"),
            salt: home.join("salt"),
            sock,
            home,
        }
    }

    pub fn from_env() -> Paths {
        let set = |k: &str| std::env::var_os(k).filter(|h| !h.is_empty());
        if let Some(h) = set("DANGO_HOME").or_else(|| set("SHADOWCORP_HOME")) {
            return Paths::at(PathBuf::from(h));
        }
        let home = user_home().unwrap_or_else(|| PathBuf::from("."));
        let (new, old) = (home.join(".dango"), home.join(".shadowcorp"));
        Paths::at(if !new.exists() && old.exists() { old } else { new })
    }

    /// Creates the data directories (0700).
    pub fn ensure(&self) -> io::Result<()> {
        for d in [&self.home, &self.spool, &self.state] {
            if !d.exists() {
                let mut b = fs::DirBuilder::new();
                b.recursive(true);
                #[cfg(unix)]
                b.mode(0o700);
                b.create(d)?;
            }
        }
        Ok(())
    }

    /// A per-install random salt, used to fingerprint prompts for the
    /// "same prompt three times" check without keeping anything guessable.
    /// Created with O_EXCL so two first-ever hooks agree on one salt.
    pub fn salt(&self) -> String {
        use std::io::Write;
        let mut buf = [0u8; 16];
        #[cfg(unix)]
        if let Ok(mut f) = fs::File::open("/dev/urandom") {
            use std::io::Read;
            let _ = f.read_exact(&mut buf);
        }
        // Windows has no /dev/urandom; std seeds RandomState from the OS's
        // random source.
        #[cfg(windows)]
        for (i, chunk) in buf.chunks_mut(8).enumerate() {
            use std::hash::{BuildHasher, Hasher};
            let mut h = std::collections::hash_map::RandomState::new().build_hasher();
            h.write_usize(i);
            chunk.copy_from_slice(&h.finish().to_le_bytes());
        }
        let fresh = hex(&buf);
        let created = private_options().write(true).create_new(true).open(&self.salt);
        if let Ok(mut f) = created {
            let _ = f.write_all(fresh.as_bytes());
            return fresh;
        }
        // Someone else created it; it may not be written yet.
        for _ in 0..50 {
            if let Ok(s) = fs::read_to_string(&self.salt) {
                if s.trim().len() >= 16 {
                    return s.trim().to_string();
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        fresh
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// First 12 hex chars of SHA-256 — used for cwd_hash, file and dir ids.
pub fn short_hash(s: &str) -> String {
    hex(&Sha256::digest(s.as_bytes()))[..12].to_string()
}

/// Writes a file readable only by the user (0600).
pub fn write_private(path: &Path, data: &[u8]) -> io::Result<()> {
    use std::io::Write;
    let mut f = private_options().create(true).write(true).truncate(true).open(path)?;
    f.write_all(data)?;
    set_private(path)
}

/// Open options that create files readable only by the user (0600). On
/// Windows there are no mode bits: files under the user's profile (where
/// the data directory is) are already the user's alone.
pub fn private_options() -> fs::OpenOptions {
    #[allow(unused_mut)]
    let mut o = fs::OpenOptions::new();
    #[cfg(unix)]
    o.mode(0o600);
    o
}

/// Makes an existing file readable only by the user (0600); nothing to do
/// on Windows (see `private_options`).
pub fn set_private(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    return fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

/// The user's home folder, where Claude Code, Codex, DeepSeek Harness and
/// WorkBuddy keep theirs: $HOME; on Windows %USERPROFILE% (Windows does not
/// set HOME; Git Bash does), else $HOME.
pub fn user_home() -> Option<PathBuf> {
    #[cfg(windows)]
    if let Some(h) = std::env::var_os("USERPROFILE").filter(|h| !h.is_empty()) {
        return Some(PathBuf::from(h));
    }
    std::env::var_os("HOME").map(PathBuf::from)
}
