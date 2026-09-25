use anyhow::Result;
use serde_yaml::Value;
use std::fs;
use std::path::Path;

pub fn load_file(path: &Path) -> Result<Value> {
    let content = fs::read_to_string(path)?;
    let value: Value = serde_yaml::from_str(&content)?;
    Ok(value)
}
