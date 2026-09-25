use anyhow::Result;

use super::base::{ParsedSection, ParsedToc, WebNovelParser};
use super::narou::NarouParser;

pub struct LegacyCompatParser {
    _domain: String,
}

impl LegacyCompatParser {
    pub fn new(domain: String) -> Self {
        Self { _domain: domain }
    }
}

impl WebNovelParser for LegacyCompatParser {
    fn parse_toc(&self, html: &str) -> Result<ParsedToc> {
        let parser = NarouParser::new(self._domain.clone());
        parser.parse_toc(html)
    }

    fn parse_section(&self, html: &str) -> Result<ParsedSection> {
        let parser = NarouParser::new(self._domain.clone());
        parser.parse_section(html)
    }
}
