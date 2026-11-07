//! Start at login, the Windows way: string values under
//! HKCU\Software\Microsoft\Windows\CurrentVersion\Run (what launchd's
//! agents are on a Mac). Elsewhere (a developer running the app on a Mac to
//! look at it) there is nothing to read or write.

/// The daemon's value: `"…\Dango.exe" --daemon` (com.dango.daemon on a Mac).
pub const DAEMON: &str = "Dango Daemon";
/// The corner 团子's value (com.dango.widget on a Mac).
pub const PET: &str = "Dango";

#[cfg(windows)]
mod imp {
    use windows_sys::Win32::Foundation::ERROR_SUCCESS;
    use windows_sys::Win32::System::Registry::{RegDeleteKeyValueW, RegGetValueW, RegSetKeyValueW, HKEY_CURRENT_USER, REG_SZ, RRF_RT_REG_SZ};

    const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }

    pub fn get(name: &str) -> Option<String> {
        let (key, value) = (wide(RUN), wide(name));
        let mut bytes = 0u32;
        // SAFETY: the first call only asks for the size; the second gets a
        // buffer of that size.
        unsafe {
            let n = RegGetValueW(HKEY_CURRENT_USER, key.as_ptr(), value.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), std::ptr::null_mut(), &mut bytes);
            if n != ERROR_SUCCESS || bytes < 2 {
                return None;
            }
            let mut buf = vec![0u16; bytes as usize / 2];
            let n = RegGetValueW(HKEY_CURRENT_USER, key.as_ptr(), value.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buf.as_mut_ptr().cast(), &mut bytes);
            if n != ERROR_SUCCESS {
                return None;
            }
            let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
            Some(String::from_utf16_lossy(&buf[..end]))
        }
    }

    pub fn set(name: &str, command: &str) -> bool {
        let (key, value, data) = (wide(RUN), wide(name), wide(command));
        // SAFETY: all three strings are NUL-terminated and outlive the call.
        unsafe { RegSetKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), value.as_ptr(), REG_SZ, data.as_ptr().cast(), (data.len() * 2) as u32) == ERROR_SUCCESS }
    }

    pub fn remove(name: &str) {
        let (key, value) = (wide(RUN), wide(name));
        // SAFETY: NUL-terminated strings that outlive the call.
        unsafe {
            RegDeleteKeyValueW(HKEY_CURRENT_USER, key.as_ptr(), value.as_ptr());
        }
    }
}

#[cfg(not(windows))]
mod imp {
    pub fn get(_: &str) -> Option<String> {
        None
    }
    pub fn set(_: &str, _: &str) -> bool {
        false
    }
    pub fn remove(_: &str) {}
}

pub use imp::{get, remove, set};

/// The program a Run value starts: the quoted path at its front.
pub fn program(command: &str) -> Option<&str> {
    let c = command.trim();
    match c.strip_prefix('"') {
        Some(rest) => rest.split('"').next(),
        None => c.split_whitespace().next(),
    }
}

#[cfg(test)]
mod tests {
    use super::program;

    #[test]
    fn the_program_of_a_run_value() {
        assert_eq!(program(r#""C:\Users\me\AppData\Local\Dango\Dango.exe" --daemon"#), Some(r"C:\Users\me\AppData\Local\Dango\Dango.exe"));
        assert_eq!(program(r"C:\dango\Dango.exe --daemon"), Some(r"C:\dango\Dango.exe"));
        assert_eq!(program(""), None);
    }
}
