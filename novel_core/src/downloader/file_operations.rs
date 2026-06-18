use anyhow::Result;
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};

pub const SECTION_SAVE_DIR_NAME: &str = "section";
pub const CACHE_SAVE_DIR_NAME: &str = "cache";
pub const RAW_DATA_DIR_NAME: &str = "raw";
pub const TOC_FILE_NAME: &str = "toc.yaml";

pub fn ensure_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    Ok(())
}

pub fn section_file_path(base: &Path, index: &str, file_subtitle: &str) -> PathBuf {
    base.join(SECTION_SAVE_DIR_NAME)
        .join(format!("{} {}.yaml", index, file_subtitle))
}

pub fn cache_dir(base: &Path) -> PathBuf {
    base.join(SECTION_SAVE_DIR_NAME).join(CACHE_SAVE_DIR_NAME)
}

pub fn move_to_cache_dir(base: &Path, section_file: &Path) -> Result<()> {
    let cache = cache_dir(base);
    ensure_dir(&cache)?;
    if section_file.exists() {
        let file_name = section_file.file_name().unwrap_or_default();
        fs::rename(section_file, cache.join(file_name))?;
    }
    Ok(())
}

pub fn remove_cache_dir(base: &Path) -> Result<()> {
    let cache = cache_dir(base);
    if cache.exists() {
        fs::remove_dir_all(cache)?;
    }
    Ok(())
}

pub fn save_yaml<T: Serialize>(path: &Path, object: &T) -> Result<()> {
    if let Some(parent) = path.parent() {
        ensure_dir(parent)?;
    }
    let content = serde_yaml::to_string(object)?;
    fs::write(path, content)?;
    Ok(())
}

pub fn save_raw_data(
    base: &Path,
    index: &str,
    file_subtitle: &str,
    raw: &str,
    ext: &str,
) -> Result<()> {
    let raw_dir = base.join(RAW_DATA_DIR_NAME);
    ensure_dir(&raw_dir)?;
    fs::write(
        raw_dir.join(format!("{} {}{}", index, file_subtitle, ext)),
        raw,
    )?;
    Ok(())
}
