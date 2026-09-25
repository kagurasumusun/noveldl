use anyhow::{Context, Result, anyhow};
use novel_core::downloader::{Downloader, set_extra_cookie_for_domain};
use novel_core::parser_selector::{ParserEngine, build_parser_by_engine};
use novel_core::parsers::{Chapter, WebNovelParser};

const DESKTOP_CHROME_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";

fn main() -> Result<()> {
    let toc_url = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow!("usage: cargo run --example toc_compare -- <toc_url>"))?;
    let domain = url::Url::parse(&toc_url)?
        .host_str()
        .unwrap_or_default()
        .trim_start_matches("www.")
        .to_string();
    if let Ok(cookie) = std::env::var("NOVELDL_COMPARE_COOKIE") {
        if !cookie.trim().is_empty() {
            set_extra_cookie_for_domain(&domain, &cookie);
        }
    }
    let dedicated_engine = dedicated_engine_for_domain(&domain)?;

    let dedicated = build_parser_by_engine(dedicated_engine, &domain);
    let nokogiri = build_parser_by_engine(ParserEngine::NokogiriCompat, &domain);

    let dedicated_chapters = collect_toc(
        Downloader::new(DESKTOP_CHROME_UA)?,
        dedicated.as_ref(),
        &toc_url,
    )
    .with_context(|| format!("dedicated toc {toc_url}"))?;
    let nokogiri_chapters = collect_toc(
        Downloader::new(DESKTOP_CHROME_UA)?,
        nokogiri.as_ref(),
        &toc_url,
    )
    .with_context(|| format!("nokogiri toc {toc_url}"))?;

    println!(
        "toc_compare domain={} dedicated_count={} nokogiri_count={} count_equal={}",
        domain,
        dedicated_chapters.len(),
        nokogiri_chapters.len(),
        dedicated_chapters.len() == nokogiri_chapters.len()
    );
    print_edges("dedicated", &dedicated_chapters);
    print_edges("nokogiri", &nokogiri_chapters);

    let mismatches = dedicated_chapters
        .iter()
        .zip(nokogiri_chapters.iter())
        .filter(|(a, b)| a.href != b.href || a.subtitle != b.subtitle)
        .take(3)
        .count();
    println!("toc_compare first_mismatches_sample={mismatches}");

    Ok(())
}

fn dedicated_engine_for_domain(domain: &str) -> Result<ParserEngine> {
    match domain {
        d if d.contains("kakuyomu.jp") => Ok(ParserEngine::Kakuyomu),
        d if d.contains("novelup.plus") => Ok(ParserEngine::NovelUpPlus),
        d if d.contains("syosetu.org") || d.contains("hameln.jp") => Ok(ParserEngine::Hameln),
        d if d.contains("syosetu.com") => Ok(ParserEngine::Narou),
        _ => Err(anyhow!("no dedicated parser for domain {domain}")),
    }
}

fn collect_toc(
    downloader: Downloader,
    parser: &dyn WebNovelParser,
    start_url: &str,
) -> Result<Vec<Chapter>> {
    let mut url = start_url.to_string();
    let mut visited = std::collections::HashSet::new();
    let mut chapters = Vec::new();
    loop {
        if !visited.insert(url.clone()) {
            break;
        }
        let html = downloader
            .fetch(&url)
            .with_context(|| format!("fetch {url}"))?;
        let toc = parser.parse_toc(&html)?;
        for mut chapter in toc.chapters {
            chapter.index = (chapters.len() + 1).to_string();
            chapters.push(chapter);
        }
        let Some(next_href) = parser.parse_toc_next_page_href(&html)? else {
            break;
        };
        url = absolute_url(&url, &next_href)?;
    }
    Ok(chapters)
}

fn print_edges(label: &str, chapters: &[Chapter]) {
    for chapter in chapters.iter().take(2).chain(chapters.iter().rev().take(2)) {
        println!(
            "{label}_chapter index={} href={} subtitle={}",
            chapter.index, chapter.href, chapter.subtitle
        );
    }
}

fn absolute_url(base: &str, href: &str) -> Result<String> {
    if href.starts_with("http://") || href.starts_with("https://") {
        return Ok(href.to_string());
    }
    if href.starts_with("episodes/") {
        let base = base.trim_end_matches('/');
        return Ok(format!("{base}/{href}"));
    }
    Ok(url::Url::parse(base)?.join(href)?.to_string())
}
