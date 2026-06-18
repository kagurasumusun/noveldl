use anyhow::Result;

use crate::downloader::pipeline::{DownloadPipeline, DownloadTarget};
use crate::parsers::Chapter;

pub fn fetch_latest_table_of_contents(
    pipeline: &DownloadPipeline,
    target: &DownloadTarget,
) -> Result<Vec<Chapter>> {
    pipeline.fetch_toc(target)
}
