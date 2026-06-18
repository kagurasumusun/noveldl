use anyhow::{Context, Result};
use novel_core::downloader::pipeline::{DownloadPipeline, DownloadTarget};
use std::path::PathBuf;

const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";

fn main() -> Result<()> {
    let urls: Vec<String> = std::env::args().skip(1).collect();
    let urls = if urls.is_empty() {
        vec![
            "https://kakuyomu.jp/works/1177354054882641261".to_string(),
            "https://ncode.syosetu.com/n6346lq/".to_string(),
            "https://novel18.syosetu.com/n2806hl/".to_string(),
            "https://novel18.syosetu.com/n7547me/".to_string(),
            "https://novel18.syosetu.com/n5594lm/".to_string(),
            "https://novelup.plus/story/459438001".to_string(),
            "https://www.akatsuki-novels.com/stories/index/novel_id~19649".to_string(),
        ]
    } else {
        urls
    };

    let pipeline = DownloadPipeline::new(UA)?;
    for url in urls {
        let parsed = url::Url::parse(&url)?;
        let domain = parsed.host_str().unwrap_or_default().to_ascii_lowercase();
        let target = DownloadTarget {
            domain: domain.clone(),
            toc_url: url.clone(),
            output_dir: PathBuf::from("/tmp/noveldl-live-site-probe"),
        };
        println!("== {url} ({domain}) ==");
        let toc = pipeline
            .fetch_toc_with_metadata(&target)
            .with_context(|| format!("fetch toc {url}"))?;
        println!(
            "toc_count={} title={:?} author={:?}",
            toc.chapters.len(),
            toc.title,
            toc.author
        );
        if toc.chapters.is_empty() {
            anyhow::bail!("toc is empty for {url}");
        }
        let mut indexes = vec![0, toc.chapters.len() / 2, toc.chapters.len() - 1];
        indexes.sort_unstable();
        indexes.dedup();
        for i in indexes {
            let chapter = &toc.chapters[i];
            let downloaded = pipeline
                .fetch_chapter(&target, chapter)
                .with_context(|| format!("fetch chapter {} {}", chapter.index, chapter.href))?;
            let body_len = downloaded.section.body.trim().chars().count();
            let intro_len = downloaded
                .section
                .introduction
                .as_deref()
                .unwrap_or_default()
                .trim()
                .chars()
                .count();
            let post_len = downloaded
                .section
                .postscript
                .as_deref()
                .unwrap_or_default()
                .trim()
                .chars()
                .count();
            println!(
                "chapter ordinal={} index={} href={} title={:?} body_chars={} intro_chars={} post_chars={}",
                i + 1,
                chapter.index,
                chapter.href,
                chapter.subtitle,
                body_len,
                intro_len,
                post_len
            );
            if body_len == 0 {
                anyhow::bail!("body is empty for {url} chapter {}", chapter.index);
            }
        }
    }
    Ok(())
}
