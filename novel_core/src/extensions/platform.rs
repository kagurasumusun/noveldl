use std::env;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OsFamily {
    Windows,
    Unix,
    Ios,
    Unknown,
}

pub fn current_os_family() -> OsFamily {
    if cfg!(windows) {
        OsFamily::Windows
    } else if cfg!(target_os = "ios") {
        OsFamily::Ios
    } else if cfg!(unix) {
        OsFamily::Unix
    } else {
        OsFamily::Unknown
    }
}

pub fn safe_system_tmp_dir() -> PathBuf {
    let mut candidate = env::temp_dir();
    if is_ascii_safe_path(&candidate) {
        return candidate;
    }

    candidate = match current_os_family() {
        OsFamily::Windows => env::var_os("SystemRoot")
            .map(|root| PathBuf::from(root).join("Temp"))
            .unwrap_or_else(|| PathBuf::from("C:/Windows/Temp")),
        OsFamily::Unix => PathBuf::from("/tmp"),
        OsFamily::Ios => env::var_os("TMPDIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp")),
        OsFamily::Unknown => env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
    };

    candidate
}

pub fn is_ascii_safe_path(path: &std::path::Path) -> bool {
    path.to_string_lossy()
        .chars()
        .all(|c| c.is_ascii() && !c.is_control())
}
