use anyhow::{Result, anyhow};
use regex::Regex;
use scraper::{Html, Selector};

use super::base::{Chapter, ParsedSection, ParsedToc, WebNovelParser};

pub struct NarouParser;

impl NarouParser {
    pub fn new(_domain: String) -> Self {
        Self
    }

    fn sel(s: &str) -> Selector {
        Selector::parse(s).unwrap()
    }
}

impl WebNovelParser for NarouParser {
    fn parse_toc(&self, html: &str) -> Result<ParsedToc> {
        let doc = Html::parse_document(html);
        let title = doc
            .select(&Self::sel("title"))
            .next()
            .map(|n| n.text().collect::<String>().trim().to_string());
        let author = doc
            .select(&Self::sel(
                ".p-novel__author a, .novel_writername a, .novel_writername",
            ))
            .next()
            .map(|n| n.text().collect::<String>().trim().to_string())
            .filter(|s| !s.is_empty());

        let subtitle_sel = Self::sel(".p-eplist__sublist .p-eplist__subtitle");
        let re_index = Regex::new(r"/(\d+)/?").unwrap();
        let mut chapters = Vec::new();

        for node in doc.select(&subtitle_sel) {
            let subtitle = node.text().collect::<String>().trim().to_string();
            let href = node.value().attr("href").unwrap_or("").to_string();
            let index = re_index
                .captures(&href)
                .and_then(|c| c.get(1))
                .map(|m| m.as_str().to_string())
                .unwrap_or_else(|| (chapters.len() + 1).to_string());
            chapters.push(Chapter {
                index,
                href,
                subtitle,
                chapter: None,
                subupdate: None,
            });
        }

        Ok(ParsedToc {
            title,
            author,
            story: None,
            chapters,
        })
    }

    fn parse_toc_next_page_href(&self, html: &str) -> Result<Option<String>> {
        let doc = Html::parse_document(html);
        let selectors = [
            ".c-pager__item--next a[href], a.c-pager__item--next[href]",
            "link[rel='next'][href], a[rel='next'][href]",
            "a[aria-label='次へ'][href], a[aria-label='Next'][href], a[aria-label='next'][href]",
        ];
        for selector in selectors {
            if let Some(next) = doc
                .select(&Self::sel(selector))
                .next()
                .and_then(|n| n.value().attr("href"))
                .map(|s| s.to_string())
            {
                return Ok(Some(next));
            }
        }

        let href_re =
            Regex::new(r"^(?:/n[a-z0-9]+/?)?\?(p=|.*page=)|^/n[a-z0-9]+/?\?(p=|.*page=)").unwrap();
        let text_re = Regex::new(r"(?i)^(次へ|next|>|＞)$").unwrap();
        for node in doc.select(&Self::sel("a[href*='?p='], a[href*='?page=']")) {
            let href = node.value().attr("href").unwrap_or("");
            let text = node.text().collect::<String>().trim().to_string();
            if href_re.is_match(href) && text_re.is_match(&text) {
                return Ok(Some(href.to_string()));
            }
        }
        Ok(None)
    }

    fn parse_section(&self, html: &str) -> Result<ParsedSection> {
        let doc = Html::parse_document(html);
        let body = doc
            .select(&Self::sel(".p-novel__body, .js-novel-text.p-novel__text"))
            .next()
            .map(|n| n.inner_html())
            .ok_or_else(|| anyhow!("body not found"))?;
        let intro = doc
            .select(&Self::sel(".p-novel__text--preface"))
            .next()
            .map(|n| n.inner_html());
        let post = doc
            .select(&Self::sel(".p-novel__text--afterword"))
            .next()
            .map(|n| n.inner_html());
        Ok(ParsedSection {
            body,
            introduction: intro,
            postscript: post,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_toc_next_page_uses_rel_next() {
        let html = r#"<html><head><link rel='next' href='?p=2'></head><body></body></html>"#;
        let parser = NarouParser::new("ncode.syosetu.com".to_string());
        assert_eq!(
            parser.parse_toc_next_page_href(html).unwrap().as_deref(),
            Some("?p=2")
        );
    }

    #[test]
    fn parse_toc_next_page_uses_labeled_query_link() {
        let html = r#"<html><body><a href='?p=3'>次へ</a></body></html>"#;
        let parser = NarouParser::new("ncode.syosetu.com".to_string());
        assert_eq!(
            parser.parse_toc_next_page_href(html).unwrap().as_deref(),
            Some("?p=3")
        );
    }

    #[test]
    fn parse_section_preserves_ruby_markup() {
        let html = r#"<html><body><div class='p-novel__body'>本文<ruby><rb>漢字</rb><rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby></div></body></html>"#;
        let parsed = NarouParser::new("ncode.syosetu.com".to_string())
            .parse_section(html)
            .unwrap();
        assert!(parsed.body.contains("<ruby>"));
        assert!(parsed.body.contains("<rt>かんじ</rt>"));
    }
}
