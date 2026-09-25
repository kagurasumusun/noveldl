use chrono::{DateTime, NaiveDate, NaiveDateTime, Utc};
use regex::Regex;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OsKind {
    Docker,
    Windows,
    Cygwin,
    Mac,
    Ios,
    Wsl,
    Linux,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VarType {
    Boolean,
    Integer,
    Float,
    String,
    Select,
    Multiple,
    Directory,
    File,
}
#[derive(Debug, Clone, PartialEq)]
pub enum ValueCast {
    Boolean(bool),
    Integer(i64),
    Float(f64),
    String(String),
}

pub fn detect_os() -> OsKind {
    if in_docker() {
        OsKind::Docker
    } else if cfg!(windows) {
        OsKind::Windows
    } else if is_cygwin_env() {
        OsKind::Cygwin
    } else if cfg!(target_os = "macos") {
        OsKind::Mac
    } else if cfg!(target_os = "ios") {
        OsKind::Ios
    } else if wsl_environment() {
        OsKind::Wsl
    } else {
        OsKind::Linux
    }
}
pub fn os_windows() -> bool {
    detect_os() == OsKind::Windows
}
pub fn os_mac() -> bool {
    detect_os() == OsKind::Mac
}
pub fn os_cygwin() -> bool {
    detect_os() == OsKind::Cygwin
}
pub fn os_ios() -> bool {
    detect_os() == OsKind::Ios
}
pub fn os_wsl() -> bool {
    detect_os() == OsKind::Wsl
}
pub fn os_linux() -> bool {
    detect_os() == OsKind::Linux
}

pub fn in_docker() -> bool {
    let p = Path::new("/proc/1/cgroup");
    p.exists()
        && fs::read_to_string(p)
            .map(|c| c.contains("/docker/") || c.contains("/lxc/"))
            .unwrap_or(false)
}
pub fn wsl_environment() -> bool {
    env::var_os("WSL_DISTRO_NAME").is_some()
        || fs::read_to_string("/proc/version")
            .map(|c| c.contains("Microsoft"))
            .unwrap_or(false)
}
fn is_cygwin_env() -> bool {
    env::var("OSTYPE")
        .map(|v| v.to_ascii_lowercase().contains("cygwin"))
        .unwrap_or(false)
}

pub fn command_available(command: &str) -> bool {
    env::var("PATH")
        .unwrap_or_default()
        .split(if cfg!(windows) { ';' } else { ':' })
        .any(|p| {
            let c = Path::new(p).join(command);
            c.exists() && c.is_file()
        })
}

pub fn variable_type_to_description(t: VarType) -> &'static str {
    match t {
        VarType::Boolean => "true/false",
        VarType::Integer => "整数",
        VarType::Float => "小数点数",
        VarType::String | VarType::Select => "文字列",
        VarType::Multiple => "文字列(複数)",
        VarType::Directory => "フォルダパス",
        VarType::File => "ファイルパス",
    }
}

pub fn string_cast_to_type(value: &str, t: VarType) -> Result<ValueCast, String> {
    match t {
        VarType::Boolean => match value.trim().to_ascii_lowercase().as_str() {
            "true" => Ok(ValueCast::Boolean(true)),
            "false" => Ok(ValueCast::Boolean(false)),
            _ => Err("invalid boolean".into()),
        },
        VarType::Integer => value
            .parse::<i64>()
            .map(ValueCast::Integer)
            .map_err(|_| "invalid integer".into()),
        VarType::Float => value
            .parse::<f64>()
            .map(ValueCast::Float)
            .map_err(|_| "invalid float".into()),
        VarType::Directory => {
            if Path::new(value).is_dir() {
                Ok(ValueCast::String(canonical_or_raw(value)))
            } else {
                Err("invalid directory".into())
            }
        }
        VarType::File => {
            if Path::new(value).is_file() {
                Ok(ValueCast::String(canonical_or_raw(value)))
            } else {
                Err("invalid file".into())
            }
        }
        VarType::String | VarType::Select | VarType::Multiple => {
            Ok(ValueCast::String(value.to_string()))
        }
    }
}

fn canonical_or_raw(value: &str) -> String {
    fs::canonicalize(value)
        .ok()
        .and_then(|p| p.to_str().map(|s| s.to_string()))
        .unwrap_or_else(|| value.to_string())
}

pub fn restore_entity(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&#160;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
}
pub fn pretreatment_source(s: &str) -> String {
    s.replace("\r\n", "\n").replace('\r', "\n")
}

pub fn date_string_to_time(input: &str) -> Option<DateTime<Utc>> {
    let t = input.trim();
    if t.is_empty() {
        return None;
    }
    if let Ok(v) = DateTime::parse_from_rfc3339(t) {
        return Some(v.with_timezone(&Utc));
    }
    for fmt in [
        "%Y-%m-%d %H:%M:%S",
        "%Y/%m/%d %H:%M",
        "%Y/%m/%d",
        "%Y-%m-%d",
    ] {
        if let Ok(v) = NaiveDateTime::parse_from_str(t, fmt) {
            return Some(DateTime::<Utc>::from_naive_utc_and_offset(v, Utc));
        }
        if let Ok(vd) = NaiveDate::parse_from_str(t, fmt) {
            let ndt = vd.and_hms_opt(0, 0, 0)?;
            return Some(DateTime::<Utc>::from_naive_utc_and_offset(ndt, Utc));
        }
    }
    None
}

pub fn ampersand_to_entity(s: &str) -> String {
    s.replace("&amp;", "__AMP__")
        .replace('&', "&amp;")
        .replace("__AMP__", "&amp;")
}
pub fn replace_filename_special_chars(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '/' => '／',
            ':' => '：',
            '*' => '＊',
            '?' => '？',
            '"' => '”',
            '<' => '〈',
            '>' => '〉',
            '[' => '［',
            ']' => '］',
            '{' => '｛',
            '}' => '｝',
            '|' => '｜',
            '.' => '．',
            '`' => '｀',
            '\\' => '￥',
            '\t' | '\n' | '\r' => ' ',
            _ => c,
        })
        .collect::<String>()
        .trim()
        .to_string()
}
pub fn extract_illust_chuki(s: &str) -> (String, Vec<String>) {
    let re = Regex::new(r"[ 　\t]*?(［＃挿絵（.+?）入る］)\n?").expect("regex");
    let mut a = Vec::new();
    let out = re.replace_all(s, |caps: &regex::Captures| {
        a.push(caps[1].to_string());
        ""
    });
    (out.to_string(), a)
}
pub fn to_unprintable_words(s: &str, mask: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_digit() || "０１２３４５６７８９ 　、。!?！？".contains(c)
            {
                c.to_string()
            } else {
                mask.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("")
}
pub fn numeric_length(s: &str) -> i64 {
    s.replace(',', "").parse::<i64>().unwrap_or(0)
}
pub fn truncate_folder_title(title: &str, limit: usize) -> String {
    if title.chars().count() <= limit {
        title.to_string()
    } else {
        title
            .chars()
            .take(limit)
            .collect::<String>()
            .trim()
            .to_string()
    }
}

pub fn truncate_path(path: &str, limit: usize, extname: Option<&str>) -> String {
    let p = Path::new(path);
    let ext = extname.map(|s| s.to_string()).unwrap_or_else(|| {
        p.extension()
            .map(|e| format!(".{}", e.to_string_lossy()))
            .unwrap_or_default()
    });
    let stem = p
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    if stem.chars().count() <= limit {
        return path.to_string();
    }
    let trunc = stem.chars().take(limit).collect::<String>();
    let dir = p.parent().and_then(|d| {
        if d.as_os_str().is_empty() || d == Path::new(".") {
            None
        } else {
            Some(d)
        }
    });
    let name = format!("{}{}", trunc, ext);
    dir.map(|d| d.join(&name).to_string_lossy().to_string())
        .unwrap_or(name)
}

pub fn copy_files(from: &[PathBuf], dest_dir: &Path, check_timestamp: bool) -> std::io::Result<()> {
    for path in from {
        let basename = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        let dirname = path
            .parent()
            .and_then(|p| p.file_name())
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        let save_dir = dest_dir.join(dirname);
        fs::create_dir_all(&save_dir)?;
        let dest = save_dir.join(basename);
        if check_timestamp && dest.exists() {
            let src_mtime = fs::metadata(path)?.modified()?;
            let dest_mtime = fs::metadata(&dest)?.modified()?;
            if dest_mtime >= src_mtime {
                continue;
            }
        }
        fs::copy(path, dest)?;
    }
    Ok(())
}

pub fn file_latest(path: &str, cache: &mut HashMap<String, SystemTime>) -> std::io::Result<bool> {
    let full = fs::canonicalize(path)?.to_string_lossy().to_string();
    let m = fs::metadata(&full)?.modified()?;
    let old = cache.get(&full).cloned();
    let latest = old.map(|o| o != m).unwrap_or(true);
    if latest {
        cache.insert(full, m);
    }
    Ok(latest)
}
