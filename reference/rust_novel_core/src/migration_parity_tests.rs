#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::fs;
    use std::path::Path;

    use serde_yaml::Value as YamlValue;

    use crate::Runtime;
    use crate::parser_selector::{ParserEngine, select_by_domain};

    fn collect_domains(dir: &Path) -> BTreeSet<String> {
        fs::read_dir(dir)
            .unwrap_or_else(|err| panic!("read_dir failed for {}: {err}", dir.display()))
            .filter_map(|entry| {
                let path = entry.ok()?.path();
                let ext = path.extension()?.to_str()?;
                if ext != "yaml" {
                    return None;
                }
                path.file_stem()
                    .and_then(|v| v.to_str())
                    .map(|v| v.to_string())
            })
            .collect()
    }

    fn first_existing_dir(candidates: &[std::path::PathBuf]) -> std::path::PathBuf {
        candidates
            .iter()
            .find(|path| path.is_dir())
            .cloned()
            .unwrap_or_else(|| {
                panic!(
                    "none of the expected reference directories exists: {}",
                    candidates
                        .iter()
                        .map(|path| path.display().to_string())
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            })
    }

    fn yaml_mapping(path: &Path) -> serde_yaml::Mapping {
        let raw = fs::read_to_string(path)
            .unwrap_or_else(|err| panic!("read YAML failed for {}: {err}", path.display()));
        serde_yaml::from_str::<YamlValue>(&raw)
            .unwrap_or_else(|err| panic!("parse YAML failed for {}: {err}", path.display()))
            .as_mapping()
            .unwrap_or_else(|| panic!("YAML root is not a mapping: {}", path.display()))
            .clone()
    }

    fn assert_reference_domains_are_migrated(rust_dir: &Path, reference_dir: &Path, label: &str) {
        let rust_domains = collect_domains(rust_dir);
        let reference_domains = collect_domains(reference_dir);
        let missing = reference_domains
            .difference(&rust_domains)
            .cloned()
            .collect::<Vec<_>>();

        assert!(
            missing.is_empty(),
            "{label} reference domains missing from Rust presets: {missing:?}"
        );
    }

    #[test]
    fn parser_presets_domains_are_fully_migrated() {
        let script_dir = Runtime::script_dir();
        let rust_dir = script_dir.join("presets/parsers");
        let reference_dir = first_existing_dir(&[
            script_dir.join("../novel_core/presets/parsers"),
            script_dir.join("../reference/narorb/preset/parsers"),
        ]);

        assert_reference_domains_are_migrated(&rust_dir, &reference_dir, "parser preset");
    }

    #[test]
    fn bundled_parser_presets_use_current_schema_without_legacy_webnovel_blocks() {
        let parser_dir = Runtime::script_dir().join("presets/parsers");
        for domain in collect_domains(&parser_dir) {
            let parser_path = parser_dir.join(format!("{domain}.yaml"));
            let parser = yaml_mapping(&parser_path);
            assert!(
                !parser.contains_key(YamlValue::String("legacy_webnovel".to_string())),
                "bundled parser preset must not keep legacy_webnovel block: {domain}"
            );

            let has_toc_sources = parser.contains_key(YamlValue::String("toc_sources".to_string()))
                || parser.contains_key(YamlValue::String("extends".to_string()));
            assert!(
                has_toc_sources,
                "bundled parser preset should define or inherit current toc_sources: {domain}"
            );
        }
    }

    #[test]
    fn all_known_domains_use_data_driven_nokogiri_engine() {
        let domains = collect_domains(&Runtime::script_dir().join("presets/parsers"));
        for domain in domains {
            let engine = select_by_domain(&domain);
            assert_eq!(
                engine,
                ParserEngine::NokogiriCompat,
                "known domain should use data-driven Nokogiri engine: {domain}"
            );
        }
    }

    #[test]
    fn ruby_core_components_have_rust_replacement_modules() {
        let rust_src = Runtime::script_dir().join("src");
        let replacements = [
            "api.rs",
            "config_manager.rs",
            "conversion_html.rs",
            "downloader/mod.rs",
            "file_lock.rs",
            "helper.rs",
            "novel_info.rs",
            "parser_selector.rs",
            "parsers/mod.rs",
            "process_manager.rs",
            "rate_limiter.rs",
            "runtime.rs",
            "sanitize.rs",
            "section_cache.rs",
            "yaml_loader.rs",
        ];

        for replacement in replacements {
            assert!(
                rust_src.join(replacement).exists(),
                "missing Rust replacement module: {replacement}"
            );
        }
    }
}
