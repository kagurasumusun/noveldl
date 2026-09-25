use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_yaml::Value;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use crate::runtime::Runtime;
use crate::yaml_loader;

fn copy_if_missing(src: &PathBuf, dst: &PathBuf) -> Result<bool> {
    if dst.exists() {
        return Ok(false);
    }
    if !src.exists() {
        return Ok(false);
    }
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(src, dst)?;
    Ok(true)
}

fn merge_yaml(base: &mut Value, overlay: Value) {
    match (base, overlay) {
        (Value::Mapping(base_map), Value::Mapping(overlay_map)) => {
            for (key, overlay_value) in overlay_map {
                match base_map.get_mut(&key) {
                    Some(base_value) => merge_yaml(base_value, overlay_value),
                    None => {
                        base_map.insert(key, overlay_value);
                    }
                }
            }
        }
        (base_slot, overlay_value) => *base_slot = overlay_value,
    }
}

fn load_builtin_preset(kind: &str, domain: &str) -> Option<Value> {
    let raw = match (kind, domain) {
        ("parsers/common", "syosetu_2024") => {
            Some(include_str!("../presets/parsers/common/syosetu_2024.yaml"))
        }
        ("parsers/common", "access_browser_fallback") => Some(include_str!(
            "../presets/parsers/common/access_browser_fallback.yaml"
        )),
        ("parsers", "ncode.syosetu.com") => {
            Some(include_str!("../presets/parsers/ncode.syosetu.com.yaml"))
        }
        ("parsers", "novel18.syosetu.com") => {
            Some(include_str!("../presets/parsers/novel18.syosetu.com.yaml"))
        }
        ("parsers", "noc.syosetu.com") => {
            Some(include_str!("../presets/parsers/noc.syosetu.com.yaml"))
        }
        ("parsers", "mnlt.syosetu.com") => {
            Some(include_str!("../presets/parsers/mnlt.syosetu.com.yaml"))
        }
        ("parsers", "mid.syosetu.com") => {
            Some(include_str!("../presets/parsers/mid.syosetu.com.yaml"))
        }
        ("parsers", "syosetu.org") => Some(include_str!("../presets/parsers/syosetu.org.yaml")),
        ("parsers", "kakuyomu.jp") => Some(include_str!("../presets/parsers/kakuyomu.jp.yaml")),
        ("parsers", "novelup.plus") => Some(include_str!("../presets/parsers/novelup.plus.yaml")),
        ("parsers", "www.mai-net.net") => {
            Some(include_str!("../presets/parsers/www.mai-net.net.yaml"))
        }
        ("parsers", "www.akatsuki-novels.com") => Some(include_str!(
            "../presets/parsers/www.akatsuki-novels.com.yaml"
        )),
        _ => None,
    }?;
    serde_yaml::from_str(raw).ok()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalConfig {
    pub default_engine: String,
    pub novels: HashMap<String, String>,
    #[serde(default)]
    pub domain_engines: HashMap<String, String>,
}

impl Default for GlobalConfig {
    fn default() -> Self {
        Self {
            default_engine: "nokogiri".to_string(),
            novels: HashMap::new(),
            domain_engines: HashMap::new(),
        }
    }
}

pub struct ConfigManager;

impl ConfigManager {
    pub fn user_presets_dir() -> PathBuf {
        Runtime::root_dir().join("presets")
    }

    pub fn global_config_path() -> PathBuf {
        Runtime::root_dir()
            .join(".novel_core")
            .join("parser_config.yaml")
    }

    pub fn load_global_config() -> Result<GlobalConfig> {
        let path = Self::global_config_path();
        if !path.exists() {
            let default = GlobalConfig::default();
            Self::save_global_config(&default)?;
            return Ok(default);
        }
        let content = fs::read_to_string(&path).with_context(|| format!("read {:?}", path))?;
        Ok(serde_yaml::from_str(&content)?)
    }

    pub fn save_global_config(config: &GlobalConfig) -> Result<()> {
        let path = Self::global_config_path();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, serde_yaml::to_string(config)?)?;
        Ok(())
    }

    pub fn load_parser_preset(domain: &str) -> Result<Value> {
        Self::seed_default_presets()?;
        let user_path = Self::user_presets_dir()
            .join("parsers")
            .join(format!("{}.yaml", domain));
        let value = if user_path.exists() {
            yaml_loader::load_file(&user_path)?
        } else {
            return Err(anyhow::anyhow!(
                "parser preset not found for domain: {} (expected at {})",
                domain,
                user_path.display()
            ));
        };
        Self::resolve_parser_extends(value)
    }

    pub fn load_site_preset(domain: &str) -> Result<Value> {
        Self::seed_default_presets()?;
        let user_path = Self::user_presets_dir()
            .join("webnovel")
            .join(format!("{}.yaml", domain));
        if user_path.exists() {
            return yaml_loader::load_file(&user_path);
        }
        Err(anyhow::anyhow!(
            "site preset not found for domain: {} (expected at {})",
            domain,
            user_path.display()
        ))
    }

    pub fn load_effective_parser_preset(domain: &str) -> Result<Value> {
        Self::seed_default_presets()?;
        let parser_path = Self::user_presets_dir()
            .join("parsers")
            .join(format!("{}.yaml", domain));
        let site_path = Self::user_presets_dir()
            .join("webnovel")
            .join(format!("{}.yaml", domain));

        let parser = if parser_path.exists() {
            Some(Self::resolve_parser_extends(yaml_loader::load_file(
                &parser_path,
            )?)?)
        } else {
            None
        };
        let site = if site_path.exists() {
            Some(yaml_loader::load_file(&site_path)?)
        } else {
            None
        };

        match (parser, site) {
            (Some(mut parser), Some(site)) => {
                merge_yaml(&mut parser, site);
                Self::resolve_parser_extends(parser)
            }
            (Some(parser), None) => Ok(parser),
            (None, Some(site)) => Self::resolve_parser_extends(site),
            (None, None) => Err(anyhow::anyhow!(
                "parser preset not found for domain: {} (expected at {} or {})",
                domain,
                parser_path.display(),
                site_path.display()
            )),
        }
    }

    pub fn save_user_parser_preset(domain: &str, value: &Value) -> Result<PathBuf> {
        let path = Self::user_presets_dir()
            .join("parsers")
            .join(format!("{}.yaml", domain));
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&path, serde_yaml::to_string(value)?)?;
        Ok(path)
    }

    pub fn save_user_site_preset(domain: &str, value: &Value) -> Result<PathBuf> {
        let path = Self::user_presets_dir()
            .join("webnovel")
            .join(format!("{}.yaml", domain));
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&path, serde_yaml::to_string(value)?)?;
        Ok(path)
    }

    pub fn ensure_default_presets() -> Result<()> {
        Self::seed_default_presets()
    }

    pub(crate) fn resolve_parser_extends(mut value: Value) -> Result<Value> {
        let Some(extends) = value
            .get("extends")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
        else {
            return Self::resolve_parser_access_extends(value);
        };
        if let Some(map) = value.as_mapping_mut() {
            map.remove(Value::String("extends".to_string()));
        }
        let mut base = Self::load_parser_base(&extends)?;
        merge_yaml(&mut base, value);
        Self::resolve_parser_access_extends(base)
    }

    fn resolve_parser_access_extends(mut value: Value) -> Result<Value> {
        let Some(access_extends) = value
            .get("access_extends")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
        else {
            return Ok(value);
        };
        if let Some(map) = value.as_mapping_mut() {
            map.remove(Value::String("access_extends".to_string()));
        }
        let base = Self::load_parser_base(&access_extends)?;
        let Some(mut base_access) = base.get("access").cloned() else {
            return Ok(value);
        };
        if let Some(site_access) = value.get("access").cloned() {
            merge_yaml(&mut base_access, site_access);
        }
        if let Some(map) = value.as_mapping_mut() {
            map.insert(Value::String("access".to_string()), base_access);
        }
        Ok(value)
    }

    fn load_parser_base(name: &str) -> Result<Value> {
        let rel = name.trim().trim_end_matches(".yaml");
        let user_path = Self::user_presets_dir()
            .join("parsers")
            .join(format!("{rel}.yaml"));
        if user_path.exists() {
            return yaml_loader::load_file(&user_path);
        }
        if let Some(common_name) = rel.strip_prefix("common/") {
            return load_builtin_preset("parsers/common", common_name)
                .ok_or_else(|| anyhow::anyhow!("missing builtin parser base: {rel}"));
        }
        Err(anyhow::anyhow!("parser base preset not found: {rel}"))
    }

    fn seed_default_presets() -> Result<()> {
        let user_root = Self::user_presets_dir();
        fs::create_dir_all(user_root.join("parsers"))?;
        fs::create_dir_all(user_root.join("parsers").join("common"))?;
        fs::create_dir_all(user_root.join("webnovel"))?;
        for common_name in ["syosetu_2024", "access_browser_fallback"] {
            let common_dst = user_root
                .join("parsers")
                .join("common")
                .join(format!("{common_name}.yaml"));
            if !common_dst.exists() {
                if let Some(v) = load_builtin_preset("parsers/common", common_name) {
                    fs::write(&common_dst, serde_yaml::to_string(&v)?)?;
                }
            }
        }
        let script_root = Runtime::script_dir().join("presets");
        for domain in [
            "ncode.syosetu.com",
            "novel18.syosetu.com",
            "noc.syosetu.com",
            "mnlt.syosetu.com",
            "mid.syosetu.com",
            "syosetu.org",
            "kakuyomu.jp",
            "novelup.plus",
            "www.mai-net.net",
            "www.akatsuki-novels.com",
        ] {
            let dst = user_root.join("parsers").join(format!("{domain}.yaml"));
            let src = script_root.join("parsers").join(format!("{domain}.yaml"));
            if dst.exists() || copy_if_missing(&src, &dst)? {
                continue;
            }
            if let Some(v) = load_builtin_preset("parsers", domain) {
                fs::write(&dst, serde_yaml::to_string(&v)?)?;
            }
        }
        Ok(())
    }
}
