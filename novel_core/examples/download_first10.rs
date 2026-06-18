use anyhow::Result;
use novel_core::downloader::pipeline::{DownloadPipeline, DownloadTarget};
use std::collections::BTreeMap;
use std::path::PathBuf;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let toc_url = args
        .next()
        .unwrap_or_else(|| "https://ncode.syosetu.com/n3726bt/".to_string());
    let output_dir = args
        .next()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("./tmp/n3726bt_first10"));
    let limit = args.next().map_or(Some(10), |value| parse_limit(&value));
    let delay = args
        .next()
        .and_then(|value| value.parse::<u64>().ok())
        .map(std::time::Duration::from_millis)
        .unwrap_or_default();
    let domain = url::Url::parse(&toc_url)?
        .host_str()
        .unwrap_or("ncode.syosetu.com")
        .to_ascii_lowercase();

    let target = DownloadTarget {
        domain,
        toc_url,
        output_dir,
    };

    let pipeline = DownloadPipeline::new("noveldl-rust-example/0.1")?;
    let toc = pipeline.fetch_toc(&target)?;
    println!("domain={} toc_count={}", target.domain, toc.len());
    std::fs::create_dir_all(&target.output_dir)?;
    let mut items = BTreeMap::new();

    let selected: Vec<_> = match limit {
        Some(limit) => toc.into_iter().take(limit).collect(),
        None => toc,
    };
    let selected_count = selected.len();

    for (chapter_index, chapter) in selected.into_iter().enumerate() {
        let downloaded = pipeline.fetch_chapter(&target, &chapter)?;
        items.insert(downloaded.chapter.index.clone(), downloaded);
        if limit.is_none() {
            pipeline.save_as_text_files(&target, &items)?;
        }
        if delay.as_millis() > 0 && chapter_index + 1 < selected_count {
            std::thread::sleep(delay);
        }
    }

    pipeline.save_as_text_files(&target, &items)?;
    println!(
        "saved {} episodes into {}",
        items.len(),
        target.output_dir.display()
    );
    Ok(())
}

fn parse_limit(value: &str) -> Option<usize> {
    if value.eq_ignore_ascii_case("all") || value == "0" {
        None
    } else {
        value.parse::<usize>().ok()
    }
}
