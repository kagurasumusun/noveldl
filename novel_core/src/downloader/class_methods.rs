use regex::Regex;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetType {
    Url,
    Ncode,
    Id,
    Other,
}

pub fn get_target_type(target: &str) -> TargetType {
    let t = target.trim();
    if t.starts_with("http://") || t.starts_with("https://") {
        return TargetType::Url;
    }

    let ncode_re = Regex::new(r"(?i)^n\d+[a-z]+$").expect("valid ncode regex");
    if ncode_re.is_match(t) {
        return TargetType::Ncode;
    }

    if t.parse::<u64>().is_ok() {
        return TargetType::Id;
    }

    TargetType::Other
}

pub fn normalize_ncode(target: &str) -> String {
    target.trim().to_ascii_lowercase()
}

pub fn create_subdirectory_name(title: &str) -> String {
    let t = title.trim();
    if t.is_empty() {
        return "untitled".to_string();
    }
    let sanitized: String = t
        .chars()
        .filter(|c| {
            !matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') && !c.is_control()
        })
        .collect::<String>()
        .trim()
        .trim_end_matches('.')
        .to_string();
    if sanitized.is_empty() {
        "untitled".to_string()
    } else {
        sanitized
    }
}

pub fn get_novel_section_save_dir(archive_path: &Path) -> PathBuf {
    archive_path.join("section")
}

pub fn detect_error_message(error_message_pattern: Option<&str>, source: &str) -> bool {
    let Some(pattern) = error_message_pattern else {
        return false;
    };
    Regex::new(pattern)
        .map(|re| re.is_match(source))
        .unwrap_or(false)
}

pub fn choices_to_string(choices: &[(&str, &str)], width: usize) -> String {
    choices
        .iter()
        .map(|(k, v)| format!("{}: {}", right_justify(k, width), v))
        .collect::<Vec<_>>()
        .join("\n")
}

fn right_justify(input: &str, width: usize) -> String {
    let len = input.chars().count();
    if len >= width {
        input.to_string()
    } else {
        format!("{}{}", " ".repeat(width - len), input)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_type_matches_ruby_rules() {
        assert_eq!(get_target_type("https://example.com"), TargetType::Url);
        assert_eq!(get_target_type("N1234AB"), TargetType::Ncode);
        assert_eq!(get_target_type("123"), TargetType::Id);
        assert_eq!(get_target_type("title search"), TargetType::Other);
    }

    #[test]
    fn detect_error_message_works() {
        assert!(detect_error_message(Some("not found"), "page not found"));
        assert!(!detect_error_message(None, "page not found"));
        assert!(!detect_error_message(Some("["), "page not found"));
    }
}
