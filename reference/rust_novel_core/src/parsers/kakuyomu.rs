use anyhow::{Result, anyhow};
use regex::Regex;
use scraper::{Html, Selector};

use super::base::{Chapter, ParsedSection, ParsedToc, WebNovelParser};

pub struct KakuyomuParser {
    _domain: String,
}

impl KakuyomuParser {
    pub fn new(domain: String) -> Self {
        Self { _domain: domain }
    }
}

impl WebNovelParser for KakuyomuParser {
    fn parse_toc(&self, html: &str) -> Result<ParsedToc> {
        let doc = Html::parse_document(html);
        let og_title = Selector::parse(r#"meta[property="og:title"]"#).unwrap();
        let title_sel = Selector::parse("title").unwrap();
        let title_re = Regex::new(r"^(.*?)\s*[-|｜]\s*カクヨム").unwrap();
        let ep_re = Regex::new(r#""__typename":"Episode","id":"(.*?)","title":"(.*?)""#).unwrap();

        let title = doc
            .select(&og_title)
            .next()
            .and_then(|n| n.value().attr("content"))
            .map(|s| s.trim().to_string())
            .or_else(|| {
                doc.select(&title_sel)
                    .next()
                    .map(|n| n.text().collect::<String>().trim().to_string())
            })
            .map(|raw| {
                title_re
                    .captures(&raw)
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().trim().to_string())
                    .unwrap_or(raw)
            });
        let author = Regex::new(r#"<span id="workAuthor-activityName"[^>]*>(.*?)</span>"#)
            .unwrap()
            .captures(html)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().trim().to_string())
            .filter(|s| !s.is_empty());
        let mut chapters = Vec::new();
        for (idx, cap) in ep_re.captures_iter(html).enumerate() {
            let episode_id = cap.get(1).unwrap().as_str().to_string();
            let subtitle = cap.get(2).unwrap().as_str().to_string();
            chapters.push(Chapter {
                index: (idx + 1).to_string(),
                href: format!("episodes/{}", episode_id),
                subtitle,
                chapter: None,
                subupdate: None,
            });
        }

        // Fallback: parse episode anchors directly from HTML when JSON payload format changes.
        if chapters.is_empty() {
            let episode_link = Selector::parse(r#"a[href*="/episodes/"]"#).unwrap();
            let mut seen = std::collections::HashSet::new();
            for node in doc.select(&episode_link) {
                let Some(href_raw) = node.value().attr("href") else {
                    continue;
                };
                let href = href_raw.trim_start_matches('/').to_string();
                if !href.contains("/episodes/") && !href.starts_with("episodes/") {
                    continue;
                }
                if !seen.insert(href.clone()) {
                    continue;
                }
                let subtitle = node.text().collect::<String>().trim().to_string();
                chapters.push(Chapter {
                    index: chapters.len().saturating_add(1).to_string(),
                    href,
                    subtitle: if subtitle.is_empty() {
                        "(untitled)".to_string()
                    } else {
                        subtitle
                    },
                    chapter: None,
                    subupdate: None,
                });
            }
        }
        Ok(ParsedToc {
            title,
            author,
            story: None,
            chapters,
        })
    }

    fn parse_section(&self, html: &str) -> Result<ParsedSection> {
        let body_re =
            Regex::new(r#"<div class="widget-episodeBody js-episode-body".*?>(?s)(.*?)</div>"#)
                .unwrap();
        let body = body_re
            .captures(html)
            .and_then(|c| c.get(1))
            .map(|m| m.as_str().to_string())
            .ok_or_else(|| anyhow!("kakuyomu body not found"))?;
        Ok(ParsedSection {
            body,
            introduction: None,
            postscript: None,
        })
    }
}
