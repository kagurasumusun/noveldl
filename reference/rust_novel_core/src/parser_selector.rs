use crate::config_manager::ConfigManager;
use crate::parsers::{
    WebNovelParser, hameln::HamelnParser, kakuyomu::KakuyomuParser,
    legacy_compat::LegacyCompatParser, narou::NarouParser, nokogiri_compat::NokogiriCompatParser,
    novelupplus::NovelUpPlusParser,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParserEngine {
    Narou,
    Kakuyomu,
    NokogiriCompat,
    LegacyCompat,
    NovelUpPlus,
    Hameln,
}

pub fn select_by_domain(domain: &str) -> ParserEngine {
    if let Ok(cfg) = ConfigManager::load_global_config() {
        if let Some(name) = cfg.domain_engines.get(domain) {
            if let Some(engine) = parse_engine_name(name) {
                return engine;
            }
        }
    }
    auto_detect_parser(domain)
}

fn auto_detect_parser(domain: &str) -> ParserEngine {
    // Complete data-driven redesign: when a parser YAML exists, the shared
    // Nokogiri-compatible engine is the canonical path for every site.
    // Specialized engines remain buildable only as explicit legacy/debug choices.
    if ConfigManager::load_parser_preset(domain).is_ok() {
        return ParserEngine::NokogiriCompat;
    }
    ParserEngine::NokogiriCompat
}

fn parse_engine_name(name: &str) -> Option<ParserEngine> {
    match name.to_ascii_lowercase().as_str() {
        "domain" | "auto" | "default" => None,
        "narou" => Some(ParserEngine::Narou),
        "kakuyomu" => Some(ParserEngine::Kakuyomu),
        "nokogiri" | "nokogiri_compat" | "nokogiricompat" => Some(ParserEngine::NokogiriCompat),
        "legacy" | "legacy_compat" | "legacycompat" => Some(ParserEngine::LegacyCompat),
        "novelupplus" | "novelup_plus" => Some(ParserEngine::NovelUpPlus),
        "hameln" => Some(ParserEngine::Hameln),
        _ => None,
    }
}

pub fn build_parser_by_engine(engine: ParserEngine, domain: &str) -> Box<dyn WebNovelParser> {
    match engine {
        ParserEngine::Narou => Box::new(NarouParser::new(domain.to_string())),
        ParserEngine::Kakuyomu => Box::new(KakuyomuParser::new(domain.to_string())),
        ParserEngine::NovelUpPlus => Box::new(NovelUpPlusParser::new(domain.to_string())),
        ParserEngine::Hameln => Box::new(HamelnParser::new(domain.to_string())),
        ParserEngine::LegacyCompat => Box::new(LegacyCompatParser::new(domain.to_string())),
        ParserEngine::NokogiriCompat => Box::new(NokogiriCompatParser::new(domain.to_string())),
    }
}

pub fn build_parser(domain: &str) -> Box<dyn WebNovelParser> {
    build_parser_by_engine(select_by_domain(domain), domain)
}

#[cfg(test)]
mod tests {
    use super::{ParserEngine, select_by_domain};

    #[test]
    fn domain_default_uses_data_driven_nokogiri_engine() {
        assert_eq!(
            select_by_domain("novelup.plus"),
            ParserEngine::NokogiriCompat
        );
        assert_eq!(
            select_by_domain("kakuyomu.jp"),
            ParserEngine::NokogiriCompat
        );
        assert_eq!(
            select_by_domain("syosetu.org"),
            ParserEngine::NokogiriCompat
        );
        assert_eq!(
            select_by_domain("ncode.syosetu.com"),
            ParserEngine::NokogiriCompat
        );
    }
}
