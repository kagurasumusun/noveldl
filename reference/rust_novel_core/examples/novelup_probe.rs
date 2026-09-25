use anyhow::Result;
use novel_core::downloader::pipeline::{DownloadPipeline, DownloadTarget};
use novel_core::downloader::set_extra_cookie_for_domain;
use std::path::PathBuf;

const DEFAULT_URL: &str = "https://novelup.plus/story/358484397";
const DESKTOP_CHROME_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";

fn main() -> Result<()> {
    let toc_url = std::env::args()
        .nth(1)
        .unwrap_or_else(|| DEFAULT_URL.to_string());
    let episodes = std::env::args()
        .nth(2)
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(1);

    if let Ok(cookie) = std::env::var("NOVELUP_COOKIE") {
        if !cookie.trim().is_empty() {
            set_extra_cookie_for_domain("novelup.plus", &cookie);
        }
    }

    let target = DownloadTarget {
        domain: "novelup.plus".to_string(),
        toc_url,
        output_dir: PathBuf::from("/tmp/novelup_probe"),
    };
    let pipeline = DownloadPipeline::new(DESKTOP_CHROME_UA)?;
    let toc = pipeline.fetch_toc(&target)?;
    println!("toc_count={}", toc.len());

    for chapter in toc.into_iter().take(episodes) {
        let downloaded = pipeline.fetch_chapter(&target, &chapter)?;
        println!(
            "episode={} title={} body_bytes={}",
            downloaded.chapter.index,
            downloaded.chapter.subtitle,
            downloaded.section.body.len()
        );
    }

    Ok(())
}
