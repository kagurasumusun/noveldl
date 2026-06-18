use anyhow::{Result, anyhow};
use regex::Regex;
use scraper::{Html, Selector};

use super::base::{Chapter, ParsedSection, ParsedToc, WebNovelParser};

pub struct HamelnParser {
    _domain: String,
}

impl HamelnParser {
    pub fn new(domain: String) -> Self {
        Self { _domain: domain }
    }

    fn sel(s: &str) -> Selector {
        Selector::parse(s).unwrap()
    }
}

fn extract_episode_index(href: &str) -> Option<String> {
    let href = href.trim();
    Regex::new(r"(?:^|/)(\d+)\.html(?:$|[?#])")
        .ok()
        .and_then(|re| re.captures(href))
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
}

fn normalize_hameln_href(href: &str) -> String {
    let mut href = href.trim().to_string();
    if let Some((head, _)) = href.split_once(|c| c == '"' || c == '\'' || c == '<') {
        href = head.trim().to_string();
    }
    if href.starts_with('.') && !href.starts_with("./") {
        href = format!(".{}", href.trim_start_matches('.'));
    }
    href
}

impl WebNovelParser for HamelnParser {
    fn parse_toc(&self, html: &str) -> Result<ParsedToc> {
        let doc = Html::parse_document(html);
        let title = doc
            .select(&Self::sel("div#maind [itemprop='name'], [itemprop='name']"))
            .next()
            .map(|n| n.text().collect::<String>().trim().to_string())
            .filter(|s| !s.is_empty())
            .or_else(|| {
                doc.select(&Self::sel(r#"meta[property="og:title"]"#))
                    .next()
                    .and_then(|n| n.value().attr("content"))
                    .map(|s| s.replace(" - ハーメルン", "").trim().to_string())
            })
            .or_else(|| {
                doc.select(&Self::sel("title"))
                    .next()
                    .map(|n| n.text().collect::<String>().trim().to_string())
            });
        let author = doc
            .select(&Self::sel(
                "div#maind [itemprop='author'], [itemprop='author'] a, [itemprop='author']",
            ))
            .next()
            .map(|n| n.text().collect::<String>().trim().to_string())
            .filter(|s| !s.is_empty())
            .or_else(|| {
                doc.select(&Self::sel(
                    r#"span[itemprop="author"] a, span[itemprop="author"]"#,
                ))
                .next()
                .map(|n| n.text().collect::<String>().trim().to_string())
            })
            .filter(|s| !s.is_empty());
        let story = doc
            .select(&Self::sel("div#maind div.ss"))
            .nth(1)
            .map(|n| n.text().collect::<String>().trim().to_string())
            .filter(|s| !s.is_empty());

        // ayati/novel_downloader 準拠: table tr を順走査して章ヘッダーを保持
        let mut chapters = Vec::new();
        let mut current_chapter: Option<String> = None;
        let rows: Vec<_> = doc
            .select(&Self::sel("#maind table tr, table tr"))
            .collect();
        for row in rows {
            if let Some(strong) = row.select(&Self::sel("td[colspan] strong")).next() {
                let ch = strong.text().collect::<String>().trim().to_string();
                if !ch.is_empty() {
                    current_chapter = Some(ch);
                }
                continue;
            }
            let Some(anchor) = row.select(&Self::sel("a[href]")).next() else {
                continue;
            };
            let href = normalize_hameln_href(anchor.value().attr("href").unwrap_or(""));
            let subtitle = anchor.text().collect::<String>().trim().to_string();
            let index = row
                .select(&Self::sel("span[id]"))
                .next()
                .and_then(|n| n.value().attr("id"))
                .map(|s| s.trim().to_string())
                .filter(|s| s.chars().all(|c| c.is_ascii_digit()))
                .or_else(|| extract_episode_index(&href))
                .unwrap_or_default();
            if !index.is_empty() && !href.is_empty() && !subtitle.is_empty() {
                let subupdate = if row.inner_html().contains("改稿")
                    || row.inner_html().contains("<u>改</u>")
                {
                    Some("revised".to_string())
                } else {
                    None
                };
                chapters.push(Chapter {
                    index,
                    href,
                    subtitle,
                    chapter: current_chapter.clone(),
                    subupdate,
                });
            }
        }

        Ok(ParsedToc {
            title,
            author,
            story,
            chapters,
        })
    }

    fn parse_section(&self, html: &str) -> Result<ParsedSection> {
        let doc = Html::parse_document(html);
        let body = doc
            // ayati/novel_downloader 準拠: 本文は #honbun を最優先で扱う
            .select(&Self::sel("#honbun, #novel_honbun, #main, .honbun"))
            .next()
            .map(|n| n.inner_html())
            .or_else(|| {
                // 旧来HTML互換: タイトル直後から後書き手前までを本文とみなす
                Regex::new(r#"(?is)<span[^>]*font-size\s*:\s*120%[^>]*>.*?</span>\s*<br\s*/?>\s*<br\s*/?>\s*(.+?)(?:<div\s+id=\"atogaki\">|</body>)"#)
                    .ok()
                    .and_then(|re| re.captures(html))
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().trim().to_string())
            })
            .or_else(|| {
                // 旧ハーメルン互換: body 直下から前後書き領域を除去して本文化
                Regex::new(r"(?is)<body[^>]*>(.+?)</body>")
                    .ok()
                    .and_then(|re| re.captures(html))
                    .and_then(|c| c.get(1))
                    .map(|m| m.as_str().to_string())
                    .map(|src| {
                        let re_script = Regex::new(r"(?is)<script[\s\S]*?</script>").unwrap();
                        let re_head = Regex::new(r#"(?is)<div\s+id="maegaki(?:_open)?"[\s\S]*?</div>"#).unwrap();
                        let re_tail = Regex::new(r#"(?is)<div\s+id="atogaki(?:_open)?"[\s\S]*"#).unwrap();
                        let s = re_script.replace_all(&src, "");
                        let s = re_head.replace_all(&s, "");
                        re_tail.replace_all(&s, "").to_string().trim().to_string()
                    })
                    .filter(|s| !s.is_empty())
            })
            .ok_or_else(|| anyhow!("hameln body not found"))?;
        let introduction = doc
            .select(&Self::sel("#maegaki, .maegaki"))
            .next()
            .map(|n| n.inner_html().trim().to_string())
            .filter(|s| !s.is_empty());
        let postscript = doc
            .select(&Self::sel("#atogaki, .atogaki"))
            .next()
            .map(|n| n.inner_html().trim().to_string())
            .filter(|s| !s.is_empty());

        Ok(ParsedSection {
            body,
            introduction,
            postscript,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_hameln_section_body_from_honbun() {
        let html = r#"<html><body><div id='maegaki'>前書き</div><div id='honbun'><p>本文</p></div><div id='atogaki'>後書き</div></body></html>"#;
        let parsed = HamelnParser::new("syosetu.org".to_string())
            .parse_section(html)
            .unwrap();
        assert!(parsed.body.contains("本文"));
        assert!(parsed.introduction.unwrap().contains("前書き"));
        assert!(parsed.postscript.unwrap().contains("後書き"));
    }

    #[test]
    fn parse_hameln_toc_from_maind_layout() {
        let html = r#"<html><body>
        <div id="maind">
          <div itemprop="name">作品名</div>
          <div itemprop="author">作者名</div>
          <div class="ss">skip</div>
          <div class="ss">あらすじ本文</div>
        </div>
        <table>
          <tr><td colspan="2"><strong>第一章</strong></td></tr>
          <tr class="bgcolor1"><td><span id="1"> </span><a href="./1.html">1話</a></td></tr>
        </table>
        </body></html>"#;
        let parsed = HamelnParser::new("syosetu.org".to_string())
            .parse_toc(html)
            .unwrap();
        assert_eq!(parsed.title.as_deref(), Some("作品名"));
        assert_eq!(parsed.author.as_deref(), Some("作者名"));
        assert_eq!(parsed.story.as_deref(), Some("あらすじ本文"));
        assert_eq!(parsed.chapters.len(), 1);
    }

    #[test]
    fn parse_hameln_toc_without_span_id_uses_href_index() {
        let html = r#"<html><body>
        <table>
          <tr><td colspan="2"><strong>第一章</strong></td></tr>
          <tr><td><a href="./12.html">12話</a></td></tr>
        </table>
        </body></html>"#;
        let parsed = HamelnParser::new("syosetu.org".to_string())
            .parse_toc(html)
            .unwrap();
        assert_eq!(parsed.chapters.len(), 1);
        assert_eq!(parsed.chapters[0].index, "12");
        assert_eq!(parsed.chapters[0].chapter.as_deref(), Some("第一章"));
    }
}
