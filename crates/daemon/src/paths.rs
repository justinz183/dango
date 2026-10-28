//! Where everything lives: ~/.shadowcorp, or $SHADOWCORP_HOME.

use std::fs;
use std::io;
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
            sock = std::env::temp_dir().join(format!("shadowcorp-{h}.sock"));
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
        match std::env::var_os("SHADOWCORP_HOME") {
            Some(h) if !h.is_empty() => Paths::at(PathBuf::from(h)),
            _ => {
                let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
                Paths::at(home.join(".shadowcorp"))
            }
        }
    }

    /// Creates the data directories (0700).
    pub fn ensure(&self) -> io::Result<()> {
        for d in [&self.home, &self.spool, &self.state] {
            if !d.exists() {
                fs::DirBuilder::new().recursive(true).mode(0o700).create(d)?;
            }
        }
        Ok(())
    }

    /// A per-install random salt, used to fingerprint prompts for the
    /// "same prompt three times" check without keeping anything guessable.
    /// Created with O_EXCL so two first-ever hooks agree on one salt.
    pub fn salt(&self) -> String {
        use std::io::{Read, Write};
        let mut buf = [0u8; 16];
        if let Ok(mut f) = fs::File::open("/dev/urandom") {
            let _ = f.read_exact(&mut buf);
        }
        let fresh = hex(&buf);
        let created = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&self.salt);
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
    let mut f = fs::OpenOptions::new().create(true).write(true).truncate(true).mode(0o600).open(path)?;
    f.write_all(data)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
}
