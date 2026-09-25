use anyhow::{Context, Result};
use novel_core::downloader::Downloader;
use novel_core::parser_selector::{ParserEngine, build_parser_by_engine};
use novel_core::parsers::{Chapter, ParsedToc, WebNovelParser};

const DEFAULT_URL: &str = "https://novelup.plus/story/220474819";
const DESKTOP_CHROME_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";

fn main() -> Result<()> {
    let toc_url = std::env::args()
        .nth(1)
        .unwrap_or_else(|| DEFAULT_URL.to_string());
    let downloader = Downloader::new(DESKTOP_CHROME_UA)?;
    let toc_html = downloader
        .fetch(&toc_url)
        .with_context(|| format!("fetch toc {toc_url}"))?;

    let dedicated = build_parser_by_engine(ParserEngine::NovelUpPlus, "novelup.plus");
    let nokogiri = build_parser_by_engine(ParserEngine::NokogiriCompat, "novelup.plus");

    let dedicated_toc = dedicated.parse_toc(&toc_html)?;
    let nokogiri_toc = nokogiri.parse_toc(&toc_html)?;
    print_toc("dedicated", &dedicated_toc);
    print_toc("nokogiri", &nokogiri_toc);
    compare_toc(&dedicated_toc, &nokogiri_toc);

    if let (Some(dedicated_first), Some(nokogiri_first)) = (
        dedicated_toc.chapters.first(),
        nokogiri_toc.chapters.first(),
    ) {
        let dedicated_url = absolute_url(&toc_url, &dedicated_first.href)?;
        let nokogiri_url = absolute_url(&toc_url, &nokogiri_first.href)?;
        println!("first_urls dedicated={dedicated_url} nokogiri={nokogiri_url}");

        let chapter_html = downloader
            .fetch(&dedicated_url)
            .with_context(|| format!("fetch first chapter {dedicated_url}"))?;
        print_section("dedicated", dedicated.as_ref(), &chapter_html)?;
        print_section("nokogiri", nokogiri.as_ref(), &chapter_html)?;
    }

    Ok(())
}

fn print_toc(label: &str, toc: &ParsedToc) {
    println!(
        "{label}_toc title={:?} author={:?} count={}",
        toc.title,
        toc.author,
        toc.chapters.len()
    );
    for chapter in toc.chapters.iter().take(3) {
        println!(
            "{label}_chapter index={} href={} subtitle={} chapter={:?}",
            chapter.index, chapter.href, chapter.subtitle, chapter.chapter
        );
    }
}

fn compare_toc(dedicated: &ParsedToc, nokogiri: &ParsedToc) {
    let matching_prefix = dedicated
        .chapters
        .iter()
        .zip(nokogiri.chapters.iter())
        .take_while(|(a, b)| chapter_key(a) == chapter_key(b))
        .count();
    println!(
        "toc_compare count_equal={} matching_prefix={}",
        dedicated.chapters.len() == nokogiri.chapters.len(),
        matching_prefix
    );
}

fn chapter_key(chapter: &Chapter) -> (&str, &str) {
    (chapter.href.as_str(), chapter.subtitle.as_str())
}

fn print_section(label: &str, parser: &dyn WebNovelParser, html: &str) -> Result<()> {
    let section = parser.parse_section(html)?;
    println!(
        "{label}_section intro_bytes={} body_bytes={} post_bytes={}",
        section.introduction.as_deref().unwrap_or_default().len(),
        section.body.len(),
        section.postscript.as_deref().unwrap_or_default().len()
    );
    Ok(())
}

fn absolute_url(base: &str, href: &str) -> Result<String> {
    if href.starts_with("http://") || href.starts_with("https://") {
        return Ok(href.to_string());
    }
    Ok(url::Url::parse(base)?.join(href)?.to_string())
}
