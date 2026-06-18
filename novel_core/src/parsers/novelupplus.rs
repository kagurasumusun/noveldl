use anyhow::{Result, anyhow};
use regex::Regex;
use scraper::{Html, Selector};
use serde_json::Value;

use super::base::{Chapter, ParsedSection, ParsedToc, WebNovelParser};

pub struct NovelUpPlusParser {
    _domain: String,
}

impl NovelUpPlusParser {
    pub fn new(domain: String) -> Self {
        Self { _domain: domain }
    }

    fn sel(s: &str) -> Selector {
        Selector::parse(s).unwrap()
    }
}

impl WebNovelParser for NovelUpPlusParser {
    fn parse_toc(&self, html: &str) -> Result<ParsedToc> {
        let doc = Html::parse_document(html);
        let title = doc
            .select(&Self::sel(r#"meta[property="og:title"]"#))
            .next()
            .and_then(|n| n.value().attr("content"))
            .map(|s| {
                // ayati/novel_downloader と同様に "タイトル（著者） | ..." を優先分解
                let raw = s.trim();
                if let Some((t, _)) = raw.split_once('（') {
                    t.trim().to_string()
                } else {
                    raw.to_string()
                }
            })
            .or_else(|| {
                doc.select(&Self::sel("title"))
                    .next()
                    .map(|n| n.text().collect::<String>().trim().to_string())
            });
        let og_title_author = doc
            .select(&Self::sel(r#"meta[property="og:title"]"#))
            .next()
            .and_then(|n| n.value().attr("content"))
            .and_then(|raw| {
                let re = Regex::new(r"^(.+?)（(.+?)）").ok()?;
                let c = re.captures(raw)?;
                Some(c.get(2)?.as_str().trim().to_string())
            });
        let author = og_title_author
            .or_else(|| {
                doc.select(&Self::sel("a.storyAuthor, meta[name='author']"))
                    .next()
                    .map(|n| {
                        n.value()
                            .attr("content")
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| n.text().collect::<String>())
                    })
                    .map(|s| s.trim().to_string())
            })
            .filter(|s| !s.is_empty());

        let mut chapters = Vec::new();
        let mut seen = std::collections::HashSet::new();
        // ayati 実装準拠: episodeListItem を順に読み、chapter クラス行を章見出しとして保持
        let mut current_chapter: Option<String> = None;
        for item in doc.select(&Self::sel("div.episodeList div.episodeListItem")) {
            let class = item.value().attr("class").unwrap_or_default();
            if class.split_whitespace().any(|c| c == "chapter") {
                let chapter = item.text().collect::<String>().trim().to_string();
                if !chapter.is_empty() {
                    current_chapter = Some(chapter);
                }
                continue;
            }
            let Some(anchor) = item.select(&Self::sel("a.episodeTitle[href]")).next() else {
                continue;
            };
            let href = anchor.value().attr("href").unwrap_or("").trim().to_string();
            let subtitle = anchor.text().collect::<String>().trim().to_string();
            if href.is_empty() || subtitle.is_empty() || !seen.insert(href.clone()) {
                continue;
            }
            let index = href.rsplit('/').next().unwrap_or_default().to_string();
            if index.is_empty() {
                continue;
            }
            chapters.push(Chapter {
                index: (chapters.len() + 1).to_string(),
                href,
                subtitle,
                chapter: current_chapter.clone(),
                subupdate: None,
            });
        }

        // フォールバック: 汎用 story アンカー
        if chapters.is_empty() {
            for anchor in doc.select(&Self::sel(
                "a[href^='/story/'], a[href*='novelup.plus/story/']",
            )) {
                let href = anchor.value().attr("href").unwrap_or("").trim().to_string();
                let subtitle = anchor.text().collect::<String>().trim().to_string();
                if href.is_empty() || subtitle.is_empty() {
                    continue;
                }
                maybe_push_chapter(&href, Some(&subtitle), &mut chapters, &mut seen);
            }
        }

        if chapters.is_empty() {
            for script in doc.select(&Self::sel(
                "script#__NEXT_DATA__, script[type='application/ld+json']",
            )) {
                let txt = script.text().collect::<String>();
                if txt.trim().is_empty() {
                    continue;
                }
                extract_chapters_from_json(&txt, &mut chapters, &mut seen);
            }
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
        let next = doc
            .select(&Self::sel(
                "link[rel='next'], a[rel='next'], .pager a.next, a.c-pager__item--next",
            ))
            .next()
            .and_then(|n| n.value().attr("href"))
            .map(|s| s.to_string());
        Ok(next.filter(|href| {
            let path = url::Url::parse(href)
                .ok()
                .map(|url| format!("{}?{}", url.path(), url.query().unwrap_or_default()))
                .unwrap_or_else(|| href.to_string());
            path.starts_with("/story/") && (path.contains("?p=") || path.contains("page="))
        }))
    }

    fn parse_section(&self, html: &str) -> Result<ParsedSection> {
        let doc = Html::parse_document(html);
        let intro = doc
            .select(&Self::sel("div.novel_foreword"))
            .next()
            .map(|n| n.inner_html())
            .filter(|s| !s.trim().is_empty());
        let post = doc
            .select(&Self::sel("div.novel_afterword"))
            .next()
            .map(|n| n.inner_html())
            .filter(|s| !s.trim().is_empty());
        let body = doc
            .select(&Self::sel("p#episode_content, div#episode-content, div.episode-content, article, main article"))
            .next()
            .map(|n| n.inner_html())
            .ok_or_else(|| anyhow!("novelupplus body not found"))?;
        Ok(ParsedSection {
            body,
            introduction: intro,
            postscript: post,
        })
    }
}

fn extract_chapters_from_json(
    json_text: &str,
    chapters: &mut Vec<Chapter>,
    seen: &mut std::collections::HashSet<String>,
) {
    let Ok(v) = serde_json::from_str::<Value>(json_text) else {
        return;
    };
    collect_story_links(&v, chapters, seen);
}

fn collect_story_links(
    node: &Value,
    chapters: &mut Vec<Chapter>,
    seen: &mut std::collections::HashSet<String>,
) {
    match node {
        Value::Object(map) => {
            if let Some(Value::String(path)) = map.get("path") {
                if path.starts_with("/story/") {
                    maybe_push_chapter(
                        path,
                        map.get("title").and_then(|v| v.as_str()),
                        chapters,
                        seen,
                    );
                }
            }
            if let Some(Value::String(url)) = map.get("url") {
                if url.starts_with("/story/") {
                    maybe_push_chapter(
                        url,
                        map.get("name").and_then(|v| v.as_str()),
                        chapters,
                        seen,
                    );
                }
            }
            for v in map.values() {
                collect_story_links(v, chapters, seen);
            }
        }
        Value::Array(items) => {
            for v in items {
                collect_story_links(v, chapters, seen);
            }
        }
        _ => {}
    }
}

fn maybe_push_chapter(
    href: &str,
    title_hint: Option<&str>,
    chapters: &mut Vec<Chapter>,
    seen: &mut std::collections::HashSet<String>,
) {
    let path = if let Ok(url) = url::Url::parse(href) {
        if !url
            .host_str()
            .map(|host| host == "novelup.plus" || host == "www.novelup.plus")
            .unwrap_or(false)
        {
            return;
        }
        url.path().to_string()
    } else {
        href.to_string()
    };
    let parts: Vec<_> = path.trim_matches('/').split('/').collect();
    if parts.len() != 3
        || parts[0] != "story"
        || !parts[1].chars().all(|c| c.is_ascii_digit())
        || !parts[2].chars().all(|c| c.is_ascii_digit())
    {
        return;
    }
    let normalized = format!("/{}/{}/{}", parts[0], parts[1], parts[2]);
    if !seen.insert(normalized.clone()) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_novelup_toc_and_next_page() {
        let html = r#"<html><body>
        <a href='/story/982784058/292750332'>第一話</a>
        <a href='/story/982784058/292750333'>第二話</a>
        <a rel='next' href='/story/982784058?p=2'>次へ</a>
        </body></html>"#;
        let parsed = NovelUpPlusParser::new("novelup.plus".to_string())
            .parse_toc(html)
            .unwrap();
        assert_eq!(parsed.chapters.len(), 2);
        assert_eq!(parsed.chapters[0].index, "1");
        assert_eq!(parsed.chapters[0].href, "/story/982784058/292750332");
        assert_eq!(
            NovelUpPlusParser::new("novelup.plus".to_string())
                .parse_toc_next_page_href(html)
                .unwrap(),
            Some("/story/982784058?p=2".to_string())
        );
    }

    #[test]
    fn parse_novelup_toc_from_next_data_json() {
        let html = r#"<html><body><script id='__NEXT_DATA__' type='application/json'>
        {"props":{"pageProps":{"episodes":[
          {"path":"/story/982784058/292750332","title":"第一話"},
          {"path":"/story/982784058/292750333","title":"第二話"}
        ]}}}
        </script></body></html>"#;
        let parsed = NovelUpPlusParser::new("novelup.plus".to_string())
            .parse_toc(html)
            .unwrap();
        assert_eq!(parsed.chapters.len(), 2);
        assert_eq!(parsed.chapters[1].index, "2");
    }

    #[test]
    fn parse_novelup_toc_absolute_links_without_episode_next_pagination() {
        let html = r#"<html><body>
        <div class="episodeList">
          <div class="episodeListItem"><a class="episodeTitle" href="https://novelup.plus/story/358484397/820764892">はじまりの日</a></div>
          <div class="episodeListItem"><a class="episodeTitle" href="https://novelup.plus/story/358484397/803303164">現実を知って</a></div>
        </div>
        <a href="https://novelup.plus/story/358484397/803303164">次のエピソード</a>
        </body></html>"#;
        let parser = NovelUpPlusParser::new("novelup.plus".to_string());
        let parsed = parser.parse_toc(html).unwrap();
        assert_eq!(parsed.chapters.len(), 2);
        assert_eq!(
            parsed.chapters[0].href,
            "https://novelup.plus/story/358484397/820764892"
        );
        assert_eq!(parser.parse_toc_next_page_href(html).unwrap(), None);
    }

    #[test]
    fn parse_novelup_episode_list_with_chapter_headers() {
        let html = r#"<html><head>
        <meta property="og:title" content="作品タイトル（作者名） | 小説投稿サイトノベルアップ＋">
        </head><body>
        <div class="episodeList">
          <div class="episodeListItem chapter">第一章</div>
          <div class="episodeListItem"><a class="episodeTitle" href="/story/1/100">1話</a></div>
          <div class="episodeListItem"><a class="episodeTitle" href="/story/1/101">2話</a></div>
        </div>
        </body></html>"#;
        let parsed = NovelUpPlusParser::new("novelup.plus".to_string())
            .parse_toc(html)
            .unwrap();
        assert_eq!(parsed.title.as_deref(), Some("作品タイトル"));
        assert_eq!(parsed.author.as_deref(), Some("作者名"));
        assert_eq!(parsed.chapters.len(), 2);
        assert_eq!(parsed.chapters[0].chapter.as_deref(), Some("第一章"));
    }
}
