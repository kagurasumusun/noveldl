use anyhow::{Context, Result, anyhow};
use regex::{Regex, RegexBuilder};
use scraper::{ElementRef, Html, Selector};
use serde::Deserialize;
use serde_json::Value as JsonValue;
use serde_yaml::{Mapping as YamlMapping, Value as YamlValue};
use std::collections::HashSet;
use std::sync::OnceLock;

use super::base::{ParsedSection, ParsedToc, WebNovelParser};
use crate::config_manager::ConfigManager;
use crate::parsers::Chapter;

/// YAML のサイト別取得ルールを注入して動作する共通 Nokogiri 互換パーサー。
///
/// 旧実装は serde_yaml::Value を直接たどる手続き型コードだったが、この実装では
/// YAML を型付きルールへコンパイルし、目次・本文・ページング抽出を同じ
/// `DataDrivenNokogiriEngine` に流し込む。サイト差分は presets/parsers/*.yaml のみで
/// 表現し、Rust 側は汎用の抽出プリミティブだけを提供する。
pub struct NokogiriCompatParser {
    domain: String,
    injected_preset: Option<YamlValue>,
    engine_cache: OnceLock<DataDrivenNokogiriEngine>,
}

impl NokogiriCompatParser {
    pub fn new(domain: String) -> Self {
        Self {
            domain,
            injected_preset: None,
            engine_cache: OnceLock::new(),
        }
    }

    /// テスト・FFI・上位アプリから解決済み YAML を直接注入するための入口。
    /// これにより「サイトごとの YAML 取得ルール + 共通パーサー」の構成を、
    /// ファイルシステムに依存せず利用できる。
    pub fn with_preset(domain: String, preset: YamlValue) -> Self {
        Self {
            domain,
            injected_preset: Some(preset),
            engine_cache: OnceLock::new(),
        }
    }

    fn engine(&self) -> Result<&DataDrivenNokogiriEngine> {
        if let Some(engine) = self.engine_cache.get() {
            return Ok(engine);
        }
        let preset = match &self.injected_preset {
            Some(preset) => preset.clone(),
            None => load_effective_preset(&self.domain),
        };
        let engine = DataDrivenNokogiriEngine::from_yaml(preset)
            .with_context(|| format!("compile parser preset for {}", self.domain))?;
        let _ = self.engine_cache.set(engine);
        self.engine_cache
            .get()
            .ok_or_else(|| anyhow!("parser preset cache unavailable for {}", self.domain))
    }
}

impl WebNovelParser for NokogiriCompatParser {
    fn parse_toc(&self, html: &str) -> Result<ParsedToc> {
        self.engine()?.parse_toc(html)
    }

    fn parse_toc_page_hrefs(&self, html: &str) -> Result<Vec<String>> {
        self.engine()?.parse_toc_page_hrefs(html)
    }

    fn parse_toc_next_page_href(&self, html: &str) -> Result<Option<String>> {
        self.engine()?.parse_toc_next_page_href(html)
    }

    fn parse_section(&self, html: &str) -> Result<ParsedSection> {
        self.engine()?.parse_section(html)
    }
}

fn load_effective_preset(domain: &str) -> YamlValue {
    ConfigManager::load_effective_parser_preset(domain).unwrap_or(YamlValue::Null)
}

#[derive(Debug, Clone)]
struct DataDrivenNokogiriEngine {
    rules: ParserRules,
}

impl DataDrivenNokogiriEngine {
    fn from_yaml(value: YamlValue) -> Result<Self> {
        let value = normalize_legacy_yaml(value);
        let rules = if value.is_null() {
            ParserRules::default()
        } else {
            serde_yaml::from_value(value)?
        };
        Ok(Self { rules })
    }

    fn parse_toc(&self, html: &str) -> Result<ParsedToc> {
        let doc = Html::parse_document(html);
        let mut title = self.extract_novel_info(html, &doc, NovelInfoField::Title);
        let mut author = self.extract_novel_info(html, &doc, NovelInfoField::Author);
        self.apply_novel_info_rules(html, &doc, &mut title, &mut author);
        let story = self.extract_novel_info(html, &doc, NovelInfoField::Story);

        let mut chapters = Vec::new();
        let mut chapter_sources = self.effective_toc_sources();
        chapter_sources.sort_by_key(|source| std::cmp::Reverse(source.priority()));
        for source in chapter_sources {
            if !source.collects_chapters() {
                continue;
            }
            self.collect_toc_source(html, &doc, &source, &mut chapters, None);
            if !chapters.is_empty() {
                break;
            }
        }

        Ok(ParsedToc {
            title,
            author,
            story,
            chapters,
        })
    }

    fn parse_toc_page_hrefs(&self, html: &str) -> Result<Vec<String>> {
        let doc = Html::parse_document(html);
        let mut hrefs = Vec::new();
        let mut seen = HashSet::new();

        for source in self.effective_toc_sources() {
            if !source.collects_pages() {
                continue;
            }
            self.collect_toc_source(
                html,
                &doc,
                &source,
                &mut Vec::new(),
                Some((&mut hrefs, &mut seen)),
            );
        }
        Ok(hrefs)
    }

    fn parse_toc_next_page_href(&self, html: &str) -> Result<Option<String>> {
        Ok(self.parse_toc_page_hrefs(html)?.into_iter().next())
    }

    fn parse_section(&self, html: &str) -> Result<ParsedSection> {
        let doc = Html::parse_document(html);
        let body = extract_first_content(html, &doc, &self.rules.body_selectors)
            .ok_or_else(|| anyhow!("body not found"))?;
        let introduction = extract_first_content(html, &doc, &self.rules.introduction_selectors);
        let postscript = extract_first_content(html, &doc, &self.rules.postscript_selectors);
        Ok(ParsedSection {
            body,
            introduction,
            postscript,
        })
    }

    fn extract_novel_info(&self, raw: &str, doc: &Html, field: NovelInfoField) -> Option<String> {
        let selector = match field {
            NovelInfoField::Title => self.rules.novel_info_selectors.title.as_deref(),
            NovelInfoField::Author => self.rules.novel_info_selectors.author.as_deref(),
            NovelInfoField::Story => self.rules.novel_info_selectors.story.as_deref(),
        };
        selector
            .and_then(|expr| select_from_document(raw, doc, expr, ExtractMode::Text))
            .or_else(|| {
                if matches!(field, NovelInfoField::Title) {
                    select_from_document(raw, doc, "title", ExtractMode::Text)
                } else {
                    None
                }
            })
    }

    fn apply_novel_info_rules(
        &self,
        raw: &str,
        doc: &Html,
        title: &mut Option<String>,
        author: &mut Option<String>,
    ) {
        let Some(rules) = &self.rules.novel_info_rules else {
            return;
        };
        let Some(raw) = select_from_document(raw, doc, &rules.source_selector, ExtractMode::Text)
        else {
            return;
        };
        if let Some(delimiter) = &rules.title_split_delimiter {
            if let Some((candidate, _)) = raw.split_once(delimiter) {
                replace_if_non_empty(title, candidate);
            }
        }
        if rules.author_from_source_regex && author.as_deref().unwrap_or_default().is_empty() {
            if let Some(author_regex) = &rules.author_regex {
                if let Some(value) = regex_capture(&raw, author_regex, rules.author_capture_group) {
                    replace_if_non_empty(author, &value);
                }
            }
        }
    }

    fn collect_selector_chapters(
        &self,
        doc: &Html,
        rule: &TocSelectorRule,
        chapters: &mut Vec<Chapter>,
    ) {
        let Ok(list_selector) = Selector::parse(&rule.selector) else {
            return;
        };
        let mut seen = HashSet::new();
        let mut current_chapter: Option<String> = None;
        for item in doc.select(&list_selector) {
            if update_current_chapter(&rule, item, &mut current_chapter) {
                continue;
            }
            let subtitle =
                select_from_element(item, &rule.item_selectors.subtitle).unwrap_or_default();
            let href = select_from_element(item, &rule.item_selectors.href)
                .map(|href| clean_href(href, &rule))
                .unwrap_or_default();
            if !rule.href_allowed(&href) {
                continue;
            }
            let mut index = rule
                .item_selectors
                .index
                .as_deref()
                .and_then(|expr| select_from_element(item, expr))
                .or_else(|| rule.index_from_href(&href))
                .unwrap_or_else(|| (chapters.len() + 1).to_string());
            if index.is_empty() {
                index = (chapters.len() + 1).to_string();
            }
            let chapter = rule
                .item_selectors
                .chapter
                .as_deref()
                .and_then(|expr| select_from_element(item, expr))
                .or_else(|| current_chapter.clone());
            let subupdate = rule
                .item_selectors
                .subupdate
                .as_deref()
                .and_then(|expr| select_from_element(item, expr))
                .or_else(|| rule.subupdate_from_html(item));

            if !href.is_empty() && !subtitle.is_empty() && seen.insert(format!("{index}:{href}")) {
                chapters.push(Chapter {
                    index,
                    href,
                    subtitle,
                    chapter,
                    subupdate,
                });
            }
        }
    }

    fn collect_regex_chapters(
        &self,
        html: &str,
        source: &RegexChapterSource,
        chapters: &mut Vec<Chapter>,
    ) {
        let mut seen = HashSet::new();
        let Ok(re) = Regex::new(&source.pattern) else {
            return;
        };
        for cap in re.captures_iter(html) {
            let Some(id) = source.id_value(&cap) else {
                continue;
            };
            let Some(title) = source.title_value(&cap) else {
                continue;
            };
            let href = decode_html_entities(&apply_capture_template(
                &source.href_template,
                &cap,
                &[("id", id), ("href", id)],
            ));
            let subtitle = decode_jsonish_text(title).trim().to_string();
            if href.is_empty() || subtitle.is_empty() || !seen.insert(href.clone()) {
                continue;
            }
            chapters.push(Chapter {
                index: source
                    .index_value(&cap)
                    .unwrap_or_else(|| (chapters.len() + 1).to_string()),
                href,
                subtitle,
                chapter: source.chapter_value(&cap),
                subupdate: source.subupdate_value(&cap),
            });
        }
    }

    fn effective_toc_sources(&self) -> Vec<TocSource> {
        self.rules.toc_sources.clone()
    }

    fn collect_toc_source(
        &self,
        html: &str,
        doc: &Html,
        source: &TocSource,
        chapters: &mut Vec<Chapter>,
        page_hrefs: Option<(&mut Vec<String>, &mut HashSet<String>)>,
    ) {
        match source {
            TocSource::Selector(rule) => self.collect_selector_chapters(doc, rule, chapters),
            TocSource::Regex(source) => self.collect_regex_chapters(html, source, chapters),
            TocSource::Json(source) => self.collect_json_chapters(html, doc, source, chapters),
            TocSource::Page(rule) => {
                if let Some((hrefs, seen)) = page_hrefs {
                    self.collect_page_hrefs(doc, rule, hrefs, seen);
                }
            }
            TocSource::PageRegex(rule) => {
                if let Some((hrefs, seen)) = page_hrefs {
                    collect_page_regex_hrefs(html, rule, hrefs, seen);
                }
            }
        }
    }

    fn collect_json_chapters(
        &self,
        raw: &str,
        doc: &Html,
        source: &JsonChapterSource,
        chapters: &mut Vec<Chapter>,
    ) {
        let mut seen = HashSet::new();
        let Ok(href_regex) = Regex::new(&source.href_pattern) else {
            return;
        };
        for json_text in source_json_texts(raw, doc, source) {
            if json_text.trim().is_empty() {
                continue;
            }
            if let Ok(json) = serde_json::from_str::<JsonValue>(&json_text) {
                collect_links_from_json(&json, source, &href_regex, chapters, &mut seen);
            }
        }
    }

    fn collect_page_hrefs(
        &self,
        doc: &Html,
        rule: &TocPageSelectorRule,
        hrefs: &mut Vec<String>,
        seen: &mut HashSet<String>,
    ) {
        for href in collect_page_hrefs_from_source(doc, rule) {
            if seen.insert(href.clone()) {
                hrefs.push(href);
            }
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum NovelInfoField {
    Title,
    Author,
    Story,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct ParserRules {
    toc_sources: Vec<TocSource>,
    body_selectors: Vec<ContentSelectorRule>,
    introduction_selectors: Vec<ContentSelectorRule>,
    postscript_selectors: Vec<ContentSelectorRule>,
    novel_info_selectors: NovelInfoSelectors,
    novel_info_rules: Option<NovelInfoRules>,
}

impl Default for ParserRules {
    fn default() -> Self {
        Self {
            toc_sources: Vec::new(),
            body_selectors: Vec::new(),
            introduction_selectors: Vec::new(),
            postscript_selectors: Vec::new(),
            novel_info_selectors: NovelInfoSelectors::default(),
            novel_info_rules: None,
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct NovelInfoSelectors {
    title: Option<String>,
    author: Option<String>,
    story: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct NovelInfoRules {
    source_selector: String,
    title_split_delimiter: Option<String>,
    author_from_source_regex: bool,
    author_regex: Option<String>,
    author_capture_group: usize,
}

impl Default for NovelInfoRules {
    fn default() -> Self {
        Self {
            source_selector: "meta[property='og:title']::attr(content)".to_string(),
            title_split_delimiter: None,
            author_from_source_regex: false,
            author_regex: None,
            author_capture_group: 2,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "source", rename_all = "snake_case")]
enum TocSource {
    Selector(TocSelectorRule),
    Regex(RegexChapterSource),
    Json(JsonChapterSource),
    Page(TocPageSelectorRule),
    PageRegex(TocPageRegexRule),
}

impl TocSource {
    fn collects_chapters(&self) -> bool {
        matches!(self, Self::Selector(_) | Self::Regex(_) | Self::Json(_))
    }

    fn collects_pages(&self) -> bool {
        matches!(self, Self::Page(_) | Self::PageRegex(_))
    }

    fn priority(&self) -> i64 {
        match self {
            Self::Selector(rule) => rule.priority,
            Self::Regex(source) => source.priority,
            Self::Json(source) => source.priority,
            Self::Page(_) | Self::PageRegex(_) => 0,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct TocSelectorRule {
    selector: String,
    priority: i64,
    item_selectors: TocItemSelectors,
    chapter_row_class: Option<String>,
    chapter_header_selector: Option<String>,
    index_from_href_regex: Option<String>,
    index_capture_group: usize,
    href_pattern: Option<String>,
    trim_html_tail: bool,
    hameln_dot_normalize: bool,
    subupdate_if_html_contains: Option<String>,
    subupdate_value: String,
}

impl Default for TocSelectorRule {
    fn default() -> Self {
        Self {
            selector: String::new(),
            priority: 0,
            item_selectors: TocItemSelectors::default(),
            chapter_row_class: None,
            chapter_header_selector: None,
            index_from_href_regex: None,
            index_capture_group: 1,
            href_pattern: None,
            trim_html_tail: false,
            hameln_dot_normalize: false,
            subupdate_if_html_contains: None,
            subupdate_value: "revised".to_string(),
        }
    }
}

impl TocSelectorRule {
    fn index_from_href(&self, href: &str) -> Option<String> {
        self.index_from_href_regex
            .as_deref()
            .and_then(|pattern| regex_capture(href, pattern, self.index_capture_group))
    }

    fn href_allowed(&self, href: &str) -> bool {
        let Some(pattern) = &self.href_pattern else {
            return true;
        };
        let Ok(re) = Regex::new(pattern) else {
            return false;
        };
        let comparable = url::Url::parse(href)
            .ok()
            .map(|url| url.path().to_string())
            .unwrap_or_else(|| href.to_string());
        re.is_match(&comparable)
    }

    fn subupdate_from_html(&self, item: ElementRef<'_>) -> Option<String> {
        self.subupdate_if_html_contains.as_ref().and_then(|needle| {
            if item.inner_html().contains(needle) {
                Some(self.subupdate_value.clone())
            } else {
                None
            }
        })
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct TocItemSelectors {
    subtitle: String,
    href: String,
    chapter: Option<String>,
    index: Option<String>,
    subupdate: Option<String>,
}

impl Default for TocItemSelectors {
    fn default() -> Self {
        Self {
            subtitle: "a".to_string(),
            href: "a::attr(href)".to_string(),
            chapter: None,
            index: None,
            subupdate: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct RegexChapterSource {
    priority: i64,
    pattern: String,
    href_template: String,
    id_group: usize,
    id_name: Option<String>,
    title_group: usize,
    title_name: Option<String>,
    index_group: Option<usize>,
    index_name: Option<String>,
    chapter_group: Option<usize>,
    chapter_name: Option<String>,
    subupdate_group: Option<usize>,
    subupdate_name: Option<String>,
}

impl RegexChapterSource {
    fn capture_value(
        &self,
        cap: &regex::Captures<'_>,
        group: Option<usize>,
        name: &Option<String>,
    ) -> Option<String> {
        name.as_deref()
            .and_then(|name| cap.name(name))
            .or_else(|| group.and_then(|group| cap.get(group)))
            .map(|m| decode_jsonish_text(m.as_str()))
            .map(|s| clean_string(&s))
            .filter(|s| !s.is_empty())
    }

    fn id_value<'a>(&self, cap: &'a regex::Captures<'_>) -> Option<&'a str> {
        self.id_name
            .as_deref()
            .and_then(|name| cap.name(name))
            .or_else(|| cap.get(self.id_group))
            .map(|m| m.as_str())
    }

    fn title_value<'a>(&self, cap: &'a regex::Captures<'_>) -> Option<&'a str> {
        self.title_name
            .as_deref()
            .and_then(|name| cap.name(name))
            .or_else(|| cap.get(self.title_group))
            .map(|m| m.as_str())
    }

    fn index_value(&self, cap: &regex::Captures<'_>) -> Option<String> {
        self.capture_value(cap, self.index_group, &self.index_name)
    }

    fn chapter_value(&self, cap: &regex::Captures<'_>) -> Option<String> {
        self.capture_value(cap, self.chapter_group, &self.chapter_name)
    }

    fn subupdate_value(&self, cap: &regex::Captures<'_>) -> Option<String> {
        self.capture_value(cap, self.subupdate_group, &self.subupdate_name)
    }
}

impl Default for RegexChapterSource {
    fn default() -> Self {
        Self {
            priority: 0,
            pattern: String::new(),
            href_template: "{href}".to_string(),
            id_group: 1,
            id_name: None,
            title_group: 2,
            title_name: None,
            index_group: None,
            index_name: None,
            chapter_group: None,
            chapter_name: None,
            subupdate_group: None,
            subupdate_name: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct JsonChapterSource {
    priority: i64,
    selector: String,
    href_pattern: String,
    path_key: String,
    url_key: String,
    title_key: String,
    name_key: String,
    path_only: bool,
    allowed_hosts: Vec<String>,
    normalize_regex: Option<String>,
    normalize_capture_group: usize,
    list_path: Option<String>,
    href_path: Option<String>,
    title_path: Option<String>,
    index_path: Option<String>,
    chapter_path: Option<String>,
    subupdate_path: Option<String>,
    href_template: Option<String>,
}

impl Default for JsonChapterSource {
    fn default() -> Self {
        Self {
            priority: 0,
            selector: "script#__NEXT_DATA__".to_string(),
            href_pattern: r"^/story/\d+/\d+$".to_string(),
            path_key: "path".to_string(),
            url_key: "url".to_string(),
            title_key: "title".to_string(),
            name_key: "name".to_string(),
            path_only: false,
            allowed_hosts: Vec::new(),
            normalize_regex: None,
            normalize_capture_group: 0,
            list_path: None,
            href_path: None,
            title_path: None,
            index_path: None,
            chapter_path: None,
            subupdate_path: None,
            href_template: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct TocPageRegexRule {
    pattern: String,
    href_template: String,
    href_group: usize,
    href_name: Option<String>,
}

impl Default for TocPageRegexRule {
    fn default() -> Self {
        Self {
            pattern: String::new(),
            href_template: "{href}".to_string(),
            href_group: 1,
            href_name: None,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum TocPageRuleMode {
    NextLink,
    AllLinks,
    Range,
}

impl Default for TocPageRuleMode {
    fn default() -> Self {
        Self::NextLink
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct TocPageSelectorRule {
    mode: TocPageRuleMode,
    selector: String,
    href: String,
    href_pattern: Option<String>,
    text_pattern: Option<String>,
    max_page_selector: Option<String>,
    max_page_pattern: Option<String>,
    max_page_capture_group: usize,
    url_template: Option<String>,
    start_page: usize,
    end_page: Option<usize>,
}

impl Default for TocPageSelectorRule {
    fn default() -> Self {
        Self {
            mode: TocPageRuleMode::NextLink,
            selector: "a[rel='next']".to_string(),
            href: ":self::attr(href)".to_string(),
            href_pattern: None,
            text_pattern: None,
            max_page_selector: None,
            max_page_pattern: None,
            max_page_capture_group: 1,
            url_template: None,
            start_page: 2,
            end_page: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
struct ContentSelectorRule {
    selector: String,
    priority: i64,
    extract: ExtractMode,
    pattern: Option<String>,
    capture_group: usize,
    capture_name: Option<String>,
    json_path: Option<String>,
}

impl Default for ContentSelectorRule {
    fn default() -> Self {
        Self {
            selector: String::new(),
            priority: 0,
            extract: ExtractMode::InnerHtml,
            pattern: None,
            capture_group: 1,
            capture_name: None,
            json_path: None,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ExtractMode {
    Text,
    InnerHtml,
    OuterHtml,
}

impl Default for ExtractMode {
    fn default() -> Self {
        Self::InnerHtml
    }
}

fn extract_first_content(raw: &str, doc: &Html, rules: &[ContentSelectorRule]) -> Option<String> {
    let mut ordered = rules.to_vec();
    ordered.sort_by_key(|rule| std::cmp::Reverse(rule.priority));
    ordered
        .iter()
        .find_map(|rule| extract_content_rule(raw, doc, rule).filter(|s| !s.trim().is_empty()))
}

fn extract_content_rule(raw: &str, doc: &Html, rule: &ContentSelectorRule) -> Option<String> {
    if let Some(path) = &rule.json_path {
        return json_path_from_text(raw, path).map(|value| clean_string(&value));
    }
    if let Some(pattern) = &rule.pattern {
        return regex_capture_named(
            raw,
            pattern,
            rule.capture_name.as_deref(),
            rule.capture_group,
        );
    }
    select_from_document(raw, doc, &rule.selector, rule.extract)
}

fn select_from_document(
    raw: &str,
    doc: &Html,
    selector_expr: &str,
    mode: ExtractMode,
) -> Option<String> {
    if selector_expr.trim_start().starts_with('$') {
        return json_path_from_text(raw, selector_expr).map(|value| clean_string(&value));
    }
    if let Some((selector, attr)) = split_attr_expr(selector_expr) {
        let selector = Selector::parse(selector).ok()?;
        return doc
            .select(&selector)
            .next()
            .and_then(|node| node.value().attr(attr))
            .map(clean_string);
    }
    let selector = Selector::parse(selector_expr).ok()?;
    doc.select(&selector)
        .next()
        .and_then(|node| extract_node(node, mode))
}

fn select_from_element(item: ElementRef<'_>, selector_expr: &str) -> Option<String> {
    if selector_expr == ":self" {
        return extract_node(item, ExtractMode::Text);
    }
    if let Some(attr) = selector_expr
        .strip_prefix(":self::attr(")
        .map(|s| s.trim_end_matches(')').trim())
    {
        return item.value().attr(attr).map(clean_string);
    }
    if let Some((selector, attr)) = split_attr_expr(selector_expr) {
        let selector = Selector::parse(selector).ok()?;
        return item
            .select(&selector)
            .next()
            .and_then(|node| node.value().attr(attr))
            .map(clean_string);
    }
    let selector = Selector::parse(selector_expr).ok()?;
    item.select(&selector)
        .next()
        .and_then(|node| extract_node(node, ExtractMode::Text))
}

fn split_attr_expr(selector_expr: &str) -> Option<(&str, &str)> {
    let (selector, attr) = selector_expr.split_once("::attr(")?;
    Some((selector.trim(), attr.trim_end_matches(')').trim()))
}

fn extract_node(node: ElementRef<'_>, mode: ExtractMode) -> Option<String> {
    let value = match mode {
        ExtractMode::Text => node.text().collect::<String>(),
        ExtractMode::InnerHtml => node.inner_html(),
        ExtractMode::OuterHtml => node.html(),
    };
    Some(clean_string(&value))
}

fn clean_string(value: &str) -> String {
    value.trim().to_string()
}

fn replace_if_non_empty(slot: &mut Option<String>, value: &str) {
    let value = clean_string(value);
    if !value.is_empty() {
        *slot = Some(value);
    }
}

fn update_current_chapter(
    rule: &TocSelectorRule,
    item: ElementRef<'_>,
    current_chapter: &mut Option<String>,
) -> bool {
    if let Some(chapter_class) = &rule.chapter_row_class {
        let class = item.value().attr("class").unwrap_or_default();
        if class.split_whitespace().any(|c| c == chapter_class) {
            replace_if_non_empty(current_chapter, &item.text().collect::<String>());
            return true;
        }
    }
    if let Some(selector) = &rule.chapter_header_selector {
        if let Some(chapter) = select_from_element(item, selector) {
            replace_if_non_empty(current_chapter, &chapter);
            return true;
        }
    }
    false
}

fn clean_href(mut href: String, rule: &TocSelectorRule) -> String {
    href = decode_html_entities(href.trim());
    if rule.trim_html_tail {
        if let Some((head, _)) = href.split_once(|c| c == '"' || c == '\'' || c == '<') {
            href = head.trim().to_string();
        }
    }
    if rule.hameln_dot_normalize && href.starts_with('.') && !href.starts_with("./") {
        href = format!(".{}", href.trim_start_matches('.'));
    }
    href
}

fn collect_page_regex_hrefs(
    html: &str,
    rule: &TocPageRegexRule,
    hrefs: &mut Vec<String>,
    seen: &mut HashSet<String>,
) {
    let Ok(re) = RegexBuilder::new(&rule.pattern)
        .dot_matches_new_line(true)
        .build()
    else {
        return;
    };
    for cap in re.captures_iter(html) {
        let Some(raw_href) = rule
            .href_name
            .as_deref()
            .and_then(|name| cap.name(name))
            .or_else(|| cap.get(rule.href_group))
            .map(|m| m.as_str())
        else {
            continue;
        };
        let href = decode_html_entities(&apply_capture_template(
            &rule.href_template,
            &cap,
            &[("href", raw_href), ("next_page", raw_href)],
        ));
        if !href.trim().is_empty() && seen.insert(href.clone()) {
            hrefs.push(href);
        }
    }
}

fn collect_page_hrefs_from_source(doc: &Html, rule: &TocPageSelectorRule) -> Vec<String> {
    match rule.mode {
        TocPageRuleMode::NextLink => find_first_matching_href(doc, rule).into_iter().collect(),
        TocPageRuleMode::AllLinks => collect_matching_hrefs(doc, rule),
        TocPageRuleMode::Range => collect_range_hrefs(doc, rule),
    }
}

fn find_first_matching_href(doc: &Html, rule: &TocPageSelectorRule) -> Option<String> {
    collect_matching_hrefs(doc, rule).into_iter().next()
}

fn collect_matching_hrefs(doc: &Html, rule: &TocPageSelectorRule) -> Vec<String> {
    let Ok(selector) = Selector::parse(&rule.selector) else {
        return Vec::new();
    };
    let href_re = rule
        .href_pattern
        .as_deref()
        .and_then(|pattern| Regex::new(pattern).ok());
    let text_re = rule
        .text_pattern
        .as_deref()
        .and_then(|pattern| Regex::new(pattern).ok());
    let mut hrefs = Vec::new();
    let mut seen = HashSet::new();
    for item in doc.select(&selector) {
        let Some(href) = select_from_element(item, &rule.href) else {
            continue;
        };
        if let Some(re) = &href_re {
            let comparable = comparable_href(&href);
            if !re.is_match(&comparable) {
                continue;
            }
        }
        if let Some(re) = &text_re {
            let text = item.text().collect::<String>().trim().to_string();
            let aria = item.value().attr("aria-label").unwrap_or_default();
            let title = item.value().attr("title").unwrap_or_default();
            if !re.is_match(&text) && !re.is_match(aria) && !re.is_match(title) {
                continue;
            }
        }
        if seen.insert(href.clone()) {
            hrefs.push(href);
        }
    }
    hrefs
}

fn collect_range_hrefs(doc: &Html, rule: &TocPageSelectorRule) -> Vec<String> {
    let Some(template) = &rule.url_template else {
        return Vec::new();
    };
    let end_page = rule.end_page.or_else(|| extract_max_page(doc, rule));
    let Some(end_page) = end_page else {
        return Vec::new();
    };
    if end_page < rule.start_page {
        return Vec::new();
    }
    (rule.start_page..=end_page)
        .map(|page| template.replace("{page}", &page.to_string()))
        .collect()
}

fn extract_max_page(doc: &Html, rule: &TocPageSelectorRule) -> Option<usize> {
    let selector = rule.max_page_selector.as_deref().unwrap_or(&rule.selector);
    let raw = select_from_document("", doc, selector, ExtractMode::Text)?;
    if let Some(pattern) = &rule.max_page_pattern {
        return regex_capture(&raw, pattern, rule.max_page_capture_group)?
            .parse()
            .ok();
    }
    raw.chars()
        .filter(|ch| ch.is_ascii_digit())
        .collect::<String>()
        .parse()
        .ok()
}

fn comparable_href(href: &str) -> String {
    url::Url::parse(href)
        .ok()
        .map(|url| {
            if let Some(query) = url.query() {
                format!("{}?{}", url.path(), query)
            } else {
                url.path().to_string()
            }
        })
        .unwrap_or_else(|| href.to_string())
}

fn regex_capture(value: &str, pattern: &str, group: usize) -> Option<String> {
    Regex::new(pattern)
        .ok()?
        .captures(value)?
        .get(group)
        .map(|m| clean_string(m.as_str()))
        .filter(|s| !s.is_empty())
}

fn decode_html_entities(value: &str) -> String {
    value
        .replace("&amp;", "&")
        .replace("&#38;", "&")
        .replace("&#x26;", "&")
        .replace("&#X26;", "&")
        .replace("&quot;", "\"")
        .replace("&#34;", "\"")
        .replace("&#x22;", "\"")
        .replace("&#X22;", "\"")
        .replace("&apos;", "'")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
        .replace("&#X27;", "'")
}

fn decode_jsonish_text(raw: &str) -> String {
    let wrapped = format!("\"{}\"", raw.replace('"', "\\\""));
    serde_json::from_str::<String>(&wrapped).unwrap_or_else(|_| raw.to_string())
}

fn apply_template(template: &str, pairs: &[(&str, &str)]) -> String {
    let mut out = template.to_string();
    for (key, value) in pairs {
        out = out.replace(&format!("{{{key}}}"), value);
    }
    out
}

fn apply_capture_template(
    template: &str,
    captures: &regex::Captures<'_>,
    pairs: &[(&str, &str)],
) -> String {
    let mut out = apply_template(template, pairs);
    if let Some(re) = Regex::new(r"\{([A-Za-z_][A-Za-z0-9_]*)\}").ok() {
        out = re
            .replace_all(&out, |caps: &regex::Captures<'_>| {
                let key = caps.get(1).map(|m| m.as_str()).unwrap_or_default();
                captures
                    .name(key)
                    .map(|m| m.as_str().to_string())
                    .unwrap_or_else(|| {
                        caps.get(0)
                            .map(|m| m.as_str())
                            .unwrap_or_default()
                            .to_string()
                    })
            })
            .to_string();
    }
    out
}

fn regex_capture_named(
    value: &str,
    pattern: &str,
    name: Option<&str>,
    group: usize,
) -> Option<String> {
    RegexBuilder::new(pattern)
        .dot_matches_new_line(true)
        .build()
        .ok()?
        .captures(value)
        .and_then(|captures| {
            name.and_then(|name| captures.name(name))
                .or_else(|| captures.get(group))
                .map(|m| clean_string(m.as_str()))
        })
        .filter(|s| !s.is_empty())
}

fn source_json_texts(raw: &str, doc: &Html, source: &JsonChapterSource) -> Vec<String> {
    let selector = source.selector.trim();
    if selector.is_empty() || selector == "$" || raw.trim_start().starts_with(['{', '[']) {
        return vec![raw.to_string()];
    }
    let Ok(selector) = Selector::parse(selector) else {
        return Vec::new();
    };
    doc.select(&selector)
        .map(|node| node.text().collect::<String>())
        .collect()
}

fn json_path_from_text(raw: &str, path: &str) -> Option<String> {
    let json = serde_json::from_str::<JsonValue>(raw).ok()?;
    json_path_value(&json, path).and_then(json_value_to_string)
}

fn json_path_value<'a>(root: &'a JsonValue, path: &str) -> Option<&'a JsonValue> {
    let mut current = root;
    let trimmed = path.trim().trim_start_matches('$').trim_start_matches('.');
    if trimmed.is_empty() {
        return Some(current);
    }
    for part in trimmed.split('.') {
        if part.is_empty() {
            continue;
        }
        let (key, index) = parse_json_path_part(part);
        if !key.is_empty() {
            current = current.get(key)?;
        }
        if let Some(index) = index {
            current = current.get(index)?;
        }
    }
    Some(current)
}

fn parse_json_path_part(part: &str) -> (&str, Option<usize>) {
    if let Some((key, rest)) = part.split_once('[') {
        let index = rest.trim_end_matches(']').parse().ok();
        (key, index)
    } else {
        (part, None)
    }
}

fn json_value_to_string(value: &JsonValue) -> Option<String> {
    match value {
        JsonValue::String(s) => Some(s.clone()),
        JsonValue::Number(n) => Some(n.to_string()),
        JsonValue::Bool(b) => Some(b.to_string()),
        JsonValue::Null => None,
        other => Some(other.to_string()),
    }
}

fn normalize_legacy_yaml(mut value: YamlValue) -> YamlValue {
    let Some(map) = value.as_mapping_mut() else {
        return value;
    };
    if let Some(pattern) = map
        .get(YamlValue::String("body_pattern".to_string()))
        .and_then(|v| v.as_str())
        .map(ToString::to_string)
    {
        insert_regex_content_rule(map, "body_selectors", &pattern, "body");
    }
    if let Some(pattern) = map
        .get(YamlValue::String("introduction_pattern".to_string()))
        .and_then(|v| v.as_str())
        .map(ToString::to_string)
    {
        insert_regex_content_rule(map, "introduction_selectors", &pattern, "introduction");
    }
    if let Some(pattern) = map
        .get(YamlValue::String("postscript_pattern".to_string()))
        .and_then(|v| v.as_str())
        .map(ToString::to_string)
    {
        insert_regex_content_rule(map, "postscript_selectors", &pattern, "postscript");
    }
    if let Some(sources) = legacy_toc_sources(map) {
        map.insert(
            YamlValue::String("toc_sources".to_string()),
            YamlValue::Sequence(sources),
        );
    } else if !map.contains_key(YamlValue::String("toc_sources".to_string())) {
        if let Some(sources) = parser_toc_selectors(map) {
            map.insert(
                YamlValue::String("toc_sources".to_string()),
                YamlValue::Sequence(sources),
            );
        }
    }
    if !map.contains_key(YamlValue::String("novel_info_selectors".to_string())) {
        let mut selectors = YamlMapping::new();
        for (legacy_key, selector_key) in [
            ("title", "title"),
            ("author", "author"),
            ("story", "story"),
            ("t", "title"),
            ("w", "author"),
            ("s", "story"),
        ] {
            if let Some(pattern) = first_legacy_pattern(map, legacy_key) {
                // Regex based metadata remains available through explicit YAML;
                // for legacy patterns we expose a conservative JSON/CSS fallback only.
                if pattern.trim_start().starts_with('$') {
                    selectors.insert(
                        YamlValue::String(selector_key.to_string()),
                        YamlValue::String(pattern),
                    );
                }
            }
        }
        if !selectors.is_empty() {
            map.insert(
                YamlValue::String("novel_info_selectors".to_string()),
                YamlValue::Mapping(selectors),
            );
        }
    }
    value
}

fn insert_regex_content_rule(map: &mut YamlMapping, key: &str, pattern: &str, capture_name: &str) {
    if pattern.trim().is_empty() || pattern.trim() == "null" {
        return;
    }
    let mut rule = YamlMapping::new();
    rule.insert(
        YamlValue::String("pattern".to_string()),
        YamlValue::String(pattern.to_string()),
    );
    rule.insert(
        YamlValue::String("capture_name".to_string()),
        YamlValue::String(capture_name.to_string()),
    );
    rule.insert(
        YamlValue::String("extract".to_string()),
        YamlValue::String("inner_html".to_string()),
    );
    map.insert(
        YamlValue::String(key.to_string()),
        YamlValue::Sequence(vec![YamlValue::Mapping(rule)]),
    );
}

fn parser_toc_selectors(map: &YamlMapping) -> Option<Vec<YamlValue>> {
    let selectors = map
        .get(YamlValue::String("toc_selectors".to_string()))?
        .as_sequence()?;
    let sources = selectors
        .iter()
        .filter_map(|item| {
            let mut mapping = item.as_mapping()?.clone();
            mapping.insert(
                YamlValue::String("source".to_string()),
                YamlValue::String("selector".to_string()),
            );
            Some(YamlValue::Mapping(mapping))
        })
        .collect::<Vec<_>>();
    if sources.is_empty() {
        None
    } else {
        Some(sources)
    }
}

fn legacy_next_toc_source(map: &YamlMapping) -> Option<YamlValue> {
    let pattern = first_legacy_pattern(map, "next_toc")?;
    let mut href_template = map
        .get(YamlValue::String("next_url".to_string()))
        .and_then(|v| v.as_str())
        .map(legacy_template)
        .unwrap_or_else(|| "{next_page}".to_string());
    if let Some(domain) = map
        .get(YamlValue::String("domain".to_string()))
        .and_then(|v| v.as_str())
    {
        href_template = href_template.replace("{domain}", domain);
    }
    let mut source = YamlMapping::new();
    source.insert(
        YamlValue::String("source".to_string()),
        YamlValue::String("page_regex".to_string()),
    );
    source.insert(
        YamlValue::String("pattern".to_string()),
        YamlValue::String(pattern),
    );
    source.insert(
        YamlValue::String("href_template".to_string()),
        YamlValue::String(href_template),
    );
    source.insert(
        YamlValue::String("href_name".to_string()),
        YamlValue::String("next_page".to_string()),
    );
    Some(YamlValue::Mapping(source))
}

fn legacy_toc_sources(map: &YamlMapping) -> Option<Vec<YamlValue>> {
    let mut sources = Vec::new();
    if let Some(source) = legacy_toc_source(map) {
        sources.push(source);
    }
    if let Some(source) = legacy_next_toc_source(map) {
        sources.push(source);
    }
    if sources.is_empty() {
        None
    } else {
        Some(sources)
    }
}

fn legacy_toc_source(map: &YamlMapping) -> Option<YamlValue> {
    let pattern = first_legacy_pattern(map, "subtitles")?;
    let href = map
        .get(YamlValue::String("href".to_string()))
        .and_then(|v| v.as_str())
        .unwrap_or("{index}");
    let mut source = YamlMapping::new();
    source.insert(
        YamlValue::String("source".to_string()),
        YamlValue::String("regex".to_string()),
    );
    source.insert(
        YamlValue::String("priority".to_string()),
        YamlValue::Number(10.into()),
    );
    source.insert(
        YamlValue::String("pattern".to_string()),
        YamlValue::String(pattern),
    );
    source.insert(
        YamlValue::String("href_template".to_string()),
        YamlValue::String(legacy_template(href)),
    );
    source.insert(
        YamlValue::String("id_name".to_string()),
        YamlValue::String("index".to_string()),
    );
    source.insert(
        YamlValue::String("index_name".to_string()),
        YamlValue::String("index".to_string()),
    );
    source.insert(
        YamlValue::String("title_name".to_string()),
        YamlValue::String("subtitle".to_string()),
    );
    source.insert(
        YamlValue::String("chapter_name".to_string()),
        YamlValue::String("chapter".to_string()),
    );
    source.insert(
        YamlValue::String("subupdate_name".to_string()),
        YamlValue::String("subupdate".to_string()),
    );
    Some(YamlValue::Mapping(source))
}

fn first_legacy_pattern(map: &YamlMapping, key: &str) -> Option<String> {
    match map.get(YamlValue::String(key.to_string()))? {
        YamlValue::String(s) => Some(s.clone()),
        YamlValue::Sequence(items) => items
            .iter()
            .find_map(|item| item.as_str().map(ToString::to_string)),
        _ => None,
    }
}

fn legacy_template(template: &str) -> String {
    Regex::new(r"\\k<([A-Za-z_][A-Za-z0-9_]*)>")
        .map(|re| re.replace_all(template, "{$1}").to_string())
        .unwrap_or_else(|_| template.to_string())
}

fn collect_links_from_json(
    node: &JsonValue,
    source: &JsonChapterSource,
    href_regex: &Regex,
    chapters: &mut Vec<Chapter>,
    seen: &mut HashSet<String>,
) {
    if let Some(list_path) = &source.list_path {
        if let Some(JsonValue::Array(items)) = json_path_value(node, list_path) {
            for item in items {
                maybe_push_json_path_chapter(item, source, href_regex, chapters, seen);
            }
        }
        return;
    }
    match node {
        JsonValue::Object(map) => {
            if let Some(JsonValue::String(path)) = map.get(&source.path_key) {
                maybe_push_json_chapter(
                    path,
                    map.get(&source.title_key).and_then(|v| v.as_str()),
                    source,
                    href_regex,
                    chapters,
                    seen,
                );
            }
            if let Some(JsonValue::String(url)) = map.get(&source.url_key) {
                maybe_push_json_chapter(
                    url,
                    map.get(&source.name_key).and_then(|v| v.as_str()),
                    source,
                    href_regex,
                    chapters,
                    seen,
                );
            }
            for value in map.values() {
                collect_links_from_json(value, source, href_regex, chapters, seen);
            }
        }
        JsonValue::Array(items) => {
            for value in items {
                collect_links_from_json(value, source, href_regex, chapters, seen);
            }
        }
        _ => {}
    }
}

fn maybe_push_json_path_chapter(
    item: &JsonValue,
    source: &JsonChapterSource,
    href_regex: &Regex,
    chapters: &mut Vec<Chapter>,
    seen: &mut HashSet<String>,
) {
    let href = source
        .href_path
        .as_deref()
        .and_then(|path| json_path_value(item, path))
        .and_then(json_value_to_string)
        .unwrap_or_default();
    let mut normalized = normalize_json_href(&href, source).unwrap_or_default();
    if let Some(template) = &source.href_template {
        normalized = template.replace("{href}", &normalized);
        if let Some(index) = source
            .index_path
            .as_deref()
            .and_then(|path| json_path_value(item, path))
            .and_then(json_value_to_string)
        {
            normalized = normalized.replace("{index}", &index);
        }
    }
    if normalized.is_empty()
        || !href_regex.is_match(&normalized)
        || !seen.insert(normalized.clone())
    {
        return;
    }
    let title = source
        .title_path
        .as_deref()
        .and_then(|path| json_path_value(item, path))
        .and_then(json_value_to_string)
        .unwrap_or_else(|| "(untitled)".to_string());
    let index = source
        .index_path
        .as_deref()
        .and_then(|path| json_path_value(item, path))
        .and_then(json_value_to_string)
        .unwrap_or_else(|| (chapters.len() + 1).to_string());
    chapters.push(Chapter {
        index,
        href: normalized,
        subtitle: title.trim().to_string(),
        chapter: source
            .chapter_path
            .as_deref()
            .and_then(|path| json_path_value(item, path))
            .and_then(json_value_to_string),
        subupdate: source
            .subupdate_path
            .as_deref()
            .and_then(|path| json_path_value(item, path))
            .and_then(json_value_to_string),
    });
}

fn maybe_push_json_chapter(
    href: &str,
    title_hint: Option<&str>,
    source: &JsonChapterSource,
    href_regex: &Regex,
    chapters: &mut Vec<Chapter>,
    seen: &mut HashSet<String>,
) {
    let Some(normalized) = normalize_json_href(href, source) else {
        return;
    };
    if !href_regex.is_match(&normalized) || !seen.insert(normalized.clone()) {
        return;
    }
    chapters.push(Chapter {
        index: (chapters.len() + 1).to_string(),
        href: normalized,
        subtitle: title_hint.unwrap_or("(untitled)").trim().to_string(),
        chapter: None,
        subupdate: None,
    });
}

fn normalize_json_href(href: &str, source: &JsonChapterSource) -> Option<String> {
    if !host_allowed(href, &source.allowed_hosts) {
        return None;
    }
    let mut normalized = if source.path_only {
        url::Url::parse(href)
            .ok()
            .map(|url| url.path().to_string())
            .unwrap_or_else(|| href.trim().to_string())
    } else {
        href.trim().to_string()
    };
    if let Some(pattern) = &source.normalize_regex {
        normalized = regex_capture(&normalized, pattern, source.normalize_capture_group)?;
    }
    Some(normalized)
}

fn host_allowed(href: &str, allowed_hosts: &[String]) -> bool {
    if allowed_hosts.is_empty() || !href.starts_with("http") {
        return true;
    }
    url::Url::parse(href)
        .ok()
        .and_then(|url| url.host_str().map(|host| host.to_ascii_lowercase()))
        .map(|host| {
            allowed_hosts
                .iter()
                .any(|allowed| allowed.eq_ignore_ascii_case(&host))
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn yaml_rules_can_be_injected_without_filesystem() {
        let yaml = serde_yaml::from_str(
            r#"
novel_info_selectors:
  title: "h1"
toc_sources:
  - source: selector
    selector: "li.episode"
    item_selectors:
      subtitle: "a"
      href: "a::attr(href)"
body_selectors:
  - selector: "article.body"
    extract: inner_html
"#,
        )
        .unwrap();
        let parser = NokogiriCompatParser::with_preset("example.test".to_string(), yaml);
        let toc = parser
            .parse_toc(r#"<h1>Injected</h1><ul><li class="episode"><a href="/1">One</a></li></ul>"#)
            .unwrap();
        assert_eq!(toc.title.as_deref(), Some("Injected"));
        assert_eq!(toc.chapters[0].href, "/1");
        let section = parser
            .parse_section(r#"<article class="body"><p>本文</p></article>"#)
            .unwrap();
        assert_eq!(section.body, "<p>本文</p>");
    }

    #[test]
    fn regex_toc_source_decodes_html_entities_in_href() {
        let yaml = serde_yaml::from_str(
            r#"
toc_sources:
  - source: regex
    pattern: '<a href="(?<href>[^"]+)">(?<subtitle>[^<]+)</a>'
    href_template: "{href}"
    id_name: href
    title_name: subtitle
body_selectors:
  - selector: article
"#,
        )
        .unwrap();
        let parser = NokogiriCompatParser::with_preset("example.test".to_string(), yaml);
        let toc = parser
            .parse_toc(r#"<a href="/bbs/sst/sst.php?act=dump&amp;cate=all&amp;all=4919&amp;n=0#kiji">第一話</a>"#)
            .unwrap();
        assert_eq!(
            toc.chapters[0].href,
            "/bbs/sst/sst.php?act=dump&cate=all&all=4919&n=0#kiji"
        );
    }

    #[test]
    fn yaml_parser_collects_all_toc_pages_from_site_yaml() {
        let yaml = serde_yaml::from_str(
            r#"
toc_sources:
  - source: page
    mode: all_links
    selector: "nav.pages a[href*='?p=']"
    href: ":self::attr(href)"
    href_pattern: "^\\?p="
body_selectors:
  - selector: "article"
"#,
        )
        .unwrap();
        let parser = NokogiriCompatParser::with_preset("example.test".to_string(), yaml);
        let html = r#"
        <nav class="pages">
          <a href="?p=1">1</a>
          <a href="?p=2">2</a>
          <a href="?p=3">3</a>
          <a href="?p=2">duplicate</a>
        </nav>
        "#;
        assert_eq!(
            parser.parse_toc_page_hrefs(html).unwrap(),
            vec!["?p=1".to_string(), "?p=2".to_string(), "?p=3".to_string()]
        );
        assert_eq!(
            parser.parse_toc_next_page_href(html).unwrap().as_deref(),
            Some("?p=1")
        );
    }

    #[test]
    fn yaml_parser_generates_toc_page_range_from_site_yaml() {
        let yaml = serde_yaml::from_str(
            r#"
toc_sources:
  - source: page
    mode: range
    max_page_selector: "a.last::attr(href)"
    max_page_pattern: "p=(\\d+)"
    url_template: "?p={page}"
    start_page: 2
body_selectors:
  - selector: "article"
"#,
        )
        .unwrap();
        let parser = NokogiriCompatParser::with_preset("example.test".to_string(), yaml);
        let html = r#"<a class="last" href="?p=4">最後</a>"#;
        assert_eq!(
            parser.parse_toc_page_hrefs(html).unwrap(),
            vec!["?p=2".to_string(), "?p=3".to_string(), "?p=4".to_string()]
        );
    }

    #[test]
    fn custom_sites_do_not_use_hardcoded_toc_page_defaults() {
        let parser = NokogiriCompatParser::new("custom.example".to_string());
        let html = r#"<nav><a href="?p=2">次へ</a></nav>"#;
        assert_eq!(
            parser.parse_toc_page_hrefs(html).unwrap(),
            Vec::<String>::new()
        );
    }

    #[test]
    fn yaml_parser_extracts_toc_and_body_from_api_json() {
        let yaml = serde_yaml::from_str(
            r#"
novel_info_selectors:
  title: "$.work.title"
  author: "$.work.author"
toc_sources:
  - source: json
    selector: "$"
    list_path: "$.episodes"
    href_path: "url"
    title_path: "title"
    index_path: "id"
    href_pattern: "^/api/episodes/"
body_selectors:
  - json_path: "$.episode.bodyHtml"
"#,
        )
        .unwrap();
        let parser = NokogiriCompatParser::with_preset("api.example".to_string(), yaml);
        let toc_json = r#"{
          "work":{"title":"API作品","author":"API作者"},
          "episodes":[
            {"id":10,"url":"/api/episodes/10","title":"API第一話"},
            {"id":11,"url":"/api/episodes/11","title":"API第二話"}
          ]
        }"#;
        let toc = parser.parse_toc(toc_json).unwrap();
        assert_eq!(toc.title.as_deref(), Some("API作品"));
        assert_eq!(toc.author.as_deref(), Some("API作者"));
        assert_eq!(toc.chapters[0].index, "10");
        assert_eq!(toc.chapters[0].href, "/api/episodes/10");
        assert_eq!(toc.chapters[1].subtitle, "API第二話");

        let section = parser
            .parse_section(r#"{"episode":{"bodyHtml":"<p>JSON本文</p>"}}"#)
            .unwrap();
        assert_eq!(section.body, "<p>JSON本文</p>");
    }

    #[test]
    fn legacy_webnovel_yaml_keys_are_normalized_for_custom_sites() {
        let yaml = serde_yaml::from_str(
            r#"
name: legacy
subtitles: '(?s)Episode;(?<index>\d+);(?<subupdate>[^;]+);(?<subtitle>.+?)$'
href: '/episodes/\k<index>'
body_pattern: '(?s)<main>(?<body>.+?)</main>'
"#,
        )
        .unwrap();
        let parser = NokogiriCompatParser::with_preset("legacy.example".to_string(), yaml);
        let toc = parser.parse_toc("Episode;42;updated;レガシー話").unwrap();
        assert_eq!(toc.chapters[0].index, "42");
        assert_eq!(toc.chapters[0].href, "/episodes/42");
        assert_eq!(toc.chapters[0].subupdate.as_deref(), Some("updated"));
        let section = parser
            .parse_section("<main><p>legacy body</p></main>")
            .unwrap();
        assert_eq!(section.body, "<p>legacy body</p>");
    }

    #[test]
    fn yaml_parser_extracts_novelup_next_data_json_and_next_page() {
        let html = r#"<html><head>
        <meta property="og:title" content="作品タイトル（作者名） | 小説投稿サイトノベルアップ＋">
        </head><body>
        <script id='__NEXT_DATA__' type='application/json'>
        {"props":{"pageProps":{"episodes":[
          {"path":"/story/982784058/292750332","title":"第一話"},
          {"url":"https://novelup.plus/story/982784058/292750333","name":"第二話"}
        ]}}}
        </script>
        <link rel='next' href='/story/982784058?p=2'>
        </body></html>"#;
        let parser = NokogiriCompatParser::new("novelup.plus".to_string());
        let parsed = parser.parse_toc(html).unwrap();
        assert_eq!(parsed.title.as_deref(), Some("作品タイトル"));
        assert_eq!(parsed.author.as_deref(), Some("作者名"));
        assert_eq!(parsed.chapters.len(), 2);
        assert_eq!(parsed.chapters[1].href, "/story/982784058/292750333");
        assert_eq!(
            parser.parse_toc_next_page_href(html).unwrap(),
            Some("/story/982784058?p=2".to_string())
        );
    }

    #[test]
    fn yaml_parser_detects_narou_next_page() {
        let html = r#"
            <div class="c-pager">
              <a href="/n4830bu/?p=2" class="c-pager__item c-pager__item--next">次へ</a>
            </div>
        "#;
        let parser = NokogiriCompatParser::new("ncode.syosetu.com".to_string());
        assert_eq!(
            parser.parse_toc_next_page_href(html).unwrap().as_deref(),
            Some("/n4830bu/?p=2")
        );
    }

    #[test]
    fn yaml_parser_detects_novelup_query_only_next_page_by_label() {
        let html = r#"<html><body>
        <div class="pager">
          <a href="?p=1">1</a>
          <a href="?p=2">次へ</a>
        </div>
        </body></html>"#;
        let parser = NokogiriCompatParser::new("novelup.plus".to_string());
        assert_eq!(
            parser.parse_toc_next_page_href(html).unwrap().as_deref(),
            Some("?p=2")
        );
    }

    #[test]
    fn yaml_parser_detects_narou_query_only_next_page_by_label() {
        let html = r#"<html><body>
        <div class="c-pager">
          <a href="?p=1">1</a>
          <a href="?p=2">次へ</a>
        </div>
        </body></html>"#;
        let parser = NokogiriCompatParser::new("ncode.syosetu.com".to_string());
        assert_eq!(
            parser.parse_toc_next_page_href(html).unwrap().as_deref(),
            Some("?p=2")
        );
    }

    #[test]
    fn yaml_parser_extracts_kakuyomu_episode_json_like_dedicated_parser() {
        let html = r#"
            <html><head><title>作品 - カクヨム</title></head><body>
            <a href="/works/16817139555994570519/episodes/16817330666680479196">2022年6月20日 12:00</a>
            <script>{"__typename":"Episode","id":"16817330666680479196","title":"第1話　名前"}</script>
            <script>{"__typename":"Episode","id":"16817330666680479197","title":"第2話　続き"}</script>
            <div class="widget-episodeBody js-episode-body"><p>body</p></div>
            </body></html>
        "#;
        let parser = NokogiriCompatParser::new("kakuyomu.jp".to_string());
        let parsed = parser.parse_toc(html).unwrap();
        assert_eq!(parsed.chapters.len(), 2);
        assert_eq!(parsed.chapters[0].href, "episodes/16817330666680479196");
        assert_eq!(parsed.chapters[0].subtitle, "第1話　名前");
        assert_ne!(parsed.chapters[0].subtitle, "2022年6月20日 12:00");
    }

    #[test]
    fn legacy_webnovel_next_toc_is_normalized_into_page_hrefs() {
        let yaml = serde_yaml::from_str(
            r#"
domain: ncode.syosetu.com
subtitles: '<a href="(?<href>/n0001aa/(?<index>\d+)/)">(?<subtitle>.+?)</a>'
href: '\k<href>'
next_toc: '<a href="/(?<next_page>n0001aa/\?p=2)" class="c-pager__item c-pager__item--next">'
next_url: 'https://\k<domain>/\k<next_page>'
body_pattern: '(?s)<main>(?<body>.+?)</main>'
"#,
        )
        .unwrap();
        let parser = NokogiriCompatParser::with_preset("ncode.syosetu.com".to_string(), yaml);
        assert_eq!(
            parser
                .parse_toc_page_hrefs(
                    r#"<a href="/n0001aa/?p=2" class="c-pager__item c-pager__item--next">次へ</a>"#
                )
                .unwrap(),
            vec!["https://ncode.syosetu.com/n0001aa/?p=2".to_string()]
        );
    }

    #[test]
    fn legacy_keys_override_merged_parser_rules() {
        let yaml = serde_yaml::from_str(
            r#"
toc_sources:
  - source: selector
    selector: "li.new"
    item_selectors:
      subtitle: "a"
      href: "a::attr(href)"
body_selectors:
  - selector: "article.new"
subtitles: 'Episode;(?<index>\d+);(?<subtitle>.+)'
href: '/legacy/\k<index>'
body_pattern: '(?s)<main>(?<body>.+?)</main>'
"#,
        )
        .unwrap();
        let parser = NokogiriCompatParser::with_preset("legacy.example".to_string(), yaml);
        let toc = parser.parse_toc("Episode;7;旧YAML").unwrap();
        assert_eq!(toc.chapters[0].href, "/legacy/7");
        let section = parser.parse_section("<main><p>旧本文</p></main>").unwrap();
        assert_eq!(section.body, "<p>旧本文</p>");
    }

    #[test]
    fn parser_toc_selectors_are_normalized_for_unified_yaml() {
        let yaml = serde_yaml::from_str(
            r#"
toc_selectors:
  - selector: "li.episode"
    item_selectors:
      subtitle: "a"
      href: "a::attr(href)"
body_selectors:
  - selector: "article"
"#,
        )
        .unwrap();
        let parser = NokogiriCompatParser::with_preset("parser.example".to_string(), yaml);
        let toc = parser
            .parse_toc(r#"<li class="episode"><a href="/1">一話</a></li>"#)
            .unwrap();
        assert_eq!(toc.chapters[0].subtitle, "一話");
    }

    #[test]
    fn yaml_parser_extracts_hameln_table_rows() {
        let html = r#"<html><body>
        <div id="maind">
          <div itemprop="name">作品名</div>
          <div itemprop="author">作者名</div>
          <div class="ss">skip</div>
          <div class="ss">あらすじ本文</div>
        </div>
        <table>
          <tr><td colspan="2"><strong>第一章</strong></td></tr>
          <tr class="bgcolor1"><td><span id="1"> </span><a href=".//1.html">1話</a>改稿</td></tr>
        </table>
        </body></html>"#;
        let parsed = NokogiriCompatParser::new("syosetu.org".to_string())
            .parse_toc(html)
            .unwrap();
        assert_eq!(parsed.title.as_deref(), Some("作品名"));
        assert_eq!(parsed.author.as_deref(), Some("作者名"));
        assert_eq!(parsed.chapters.len(), 1);
        assert_eq!(parsed.chapters[0].chapter.as_deref(), Some("第一章"));
        assert_eq!(parsed.chapters[0].subupdate.as_deref(), Some("revised"));
    }
}
