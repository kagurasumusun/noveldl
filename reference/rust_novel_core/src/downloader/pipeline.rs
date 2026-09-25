use anyhow::{Context, Result};
use std::collections::{BTreeMap, HashSet, VecDeque};
use std::fs;
use std::path::PathBuf;

use crate::downloader::Downloader;
use crate::parser_selector::build_parser;
use crate::parsers::{Chapter, ParsedSection};

#[derive(Debug, Clone)]
pub struct DownloadTarget {
    pub domain: String,
    pub toc_url: String,
    pub output_dir: PathBuf,
}

#[derive(Debug, Clone)]
pub struct DownloadedChapter {
    pub chapter: Chapter,
    pub section: ParsedSection,
}

#[derive(Debug, Clone)]
pub struct TocWithMetadata {
    pub chapters: Vec<Chapter>,
    pub title: String,
    pub author: String,
}

pub struct DownloadPipeline {
    downloader: Downloader,
}

impl DownloadPipeline {
    pub fn new(user_agent: &str) -> Result<Self> {
        Ok(Self {
            downloader: Downloader::new(user_agent)?,
        })
    }

    pub fn fetch_toc(&self, target: &DownloadTarget) -> Result<Vec<Chapter>> {
        let toc_html = self.downloader.fetch(&target.toc_url)?;
        self.fetch_toc_from_initial_html(target, &toc_html)
    }

    pub fn fetch_toc_with_metadata(&self, target: &DownloadTarget) -> Result<TocWithMetadata> {
        self.fetch_toc_with_metadata_incremental(target, |_, _, _| Ok(()))
    }

    pub fn fetch_toc_with_metadata_incremental<F>(
        &self,
        target: &DownloadTarget,
        mut on_page: F,
    ) -> Result<TocWithMetadata>
    where
        F: FnMut(&[Chapter], &str, &str) -> Result<()>,
    {
        let parser = build_parser(&target.domain);
        let mut pages = TocPageQueue::new(
            &target.toc_url,
            Some(self.downloader.fetch(&target.toc_url)?),
        );
        let mut chapters = Vec::new();
        let mut title = String::new();
        let mut author = String::new();

        while let Some((url, html)) = pages.pop_next() {
            let toc_html = match html {
                Some(html) => html,
                None => self.downloader.fetch(&url)?,
            };
            let toc = parser.parse_toc(&toc_html)?;
            if title.is_empty() {
                title = toc.title.clone().unwrap_or_default();
            }
            if author.is_empty() {
                author = toc.author.clone().unwrap_or_default();
            }
            append_toc_chapters(&mut chapters, toc.chapters);
            on_page(&chapters, &title, &author)?;

            for href in parser.parse_toc_page_hrefs(&toc_html)? {
                pages.schedule(&url, &href);
            }
        }
        Ok(TocWithMetadata {
            chapters,
            title,
            author,
        })
    }

    pub fn fetch_toc_from_initial_html(
        &self,
        target: &DownloadTarget,
        initial_html: &str,
    ) -> Result<Vec<Chapter>> {
        let parser = build_parser(&target.domain);
        let mut pages = TocPageQueue::new(&target.toc_url, Some(initial_html.to_string()));
        let mut chapters = Vec::new();

        while let Some((url, html)) = pages.pop_next() {
            let toc_html = match html {
                Some(html) => html,
                None => self.downloader.fetch(&url)?,
            };
            let toc = parser.parse_toc(&toc_html)?;
            append_toc_chapters(&mut chapters, toc.chapters);

            for href in parser.parse_toc_page_hrefs(&toc_html)? {
                pages.schedule(&url, &href);
            }
        }
        Ok(chapters)
    }

    pub fn fetch_chapter(
        &self,
        target: &DownloadTarget,
        chapter: &Chapter,
    ) -> Result<DownloadedChapter> {
        let html = self.fetch_chapter_html(target, chapter)?;
        self.parse_chapter_html(target, chapter, &html)
    }

    pub fn fetch_chapter_html(&self, target: &DownloadTarget, chapter: &Chapter) -> Result<String> {
        let url = absolute_url(&target.toc_url, &chapter.href);
        self.downloader
            .fetch(&url)
            .with_context(|| format!("fetch {}", url))
    }

    pub fn parse_chapter_html(
        &self,
        target: &DownloadTarget,
        chapter: &Chapter,
        html: &str,
    ) -> Result<DownloadedChapter> {
        let parser = build_parser(&target.domain);
        let section = parser.parse_section(html)?;
        Ok(DownloadedChapter {
            chapter: chapter.clone(),
            section,
        })
    }

    pub fn save_as_text_files(
        &self,
        target: &DownloadTarget,
        items: &BTreeMap<String, DownloadedChapter>,
    ) -> Result<()> {
        fs::create_dir_all(&target.output_dir)?;
        for (index, downloaded) in items {
            let safe_subtitle = sanitize_filename(&downloaded.chapter.subtitle);
            let path = target
                .output_dir
                .join(format!("{} {}.txt", index, safe_subtitle));
            fs::write(path, &downloaded.section.body)?;
        }
        Ok(())
    }

    pub fn fetch_all(
        &self,
        target: &DownloadTarget,
    ) -> Result<BTreeMap<String, DownloadedChapter>> {
        let parser = build_parser(&target.domain);
        let mut map = BTreeMap::new();
        for chapter in self.fetch_toc(target)? {
            let html = self.fetch_chapter_html(target, &chapter)?;
            let section = parser.parse_section(&html)?;
            let index = chapter.index.clone();
            map.insert(index, DownloadedChapter { chapter, section });
        }
        Ok(map)
    }
}

struct TocPageQueue {
    pending: VecDeque<(String, Option<String>)>,
    scheduled: HashSet<String>,
    visited: HashSet<String>,
}

impl TocPageQueue {
    fn new(initial_url: &str, initial_html: Option<String>) -> Self {
        let mut pending = VecDeque::new();
        pending.push_back((initial_url.to_string(), initial_html));
        let mut scheduled = HashSet::new();
        scheduled.insert(initial_url.to_string());
        Self {
            pending,
            scheduled,
            visited: HashSet::new(),
        }
    }

    fn pop_next(&mut self) -> Option<(String, Option<String>)> {
        while let Some((url, html)) = self.pending.pop_front() {
            if self.visited.insert(url.clone()) {
                return Some((url, html));
            }
        }
        None
    }

    fn schedule(&mut self, current_url: &str, href: &str) {
        let url = absolute_url(current_url, href);
        if self.visited.contains(&url) || !self.scheduled.insert(url.clone()) {
            return;
        }
        self.pending.push_back((url, None));
    }
}

fn append_toc_chapters(chapters: &mut Vec<Chapter>, page_chapters: Vec<Chapter>) {
    for mut chapter in page_chapters {
        // Parser-local indexes usually restart on each paginated TOC page.
        // Keep downloader indexes globally unique so later pages are not
        // overwritten when saved in the BTreeMap used by fetch_all().
        chapter.index = (chapters.len() + 1).to_string();
        chapters.push(chapter);
    }
}

fn absolute_url(toc_url: &str, href: &str) -> String {
    if href.starts_with("http://") || href.starts_with("https://") {
        return href.to_string();
    }
    if let Ok(base) = url::Url::parse(toc_url) {
        if href.starts_with("episodes/") && base.path().starts_with("/works/") {
            let work_base = if toc_url.ends_with('/') {
                toc_url.to_string()
            } else {
                format!("{}/", toc_url)
            };
            return format!("{}{}", work_base, href);
        }
        if let Ok(joined) = base.join(href) {
            return joined.into();
        }
        if !toc_url.ends_with('/') {
            if let Ok(base_dir) = url::Url::parse(&format!("{}/", toc_url)) {
                if let Ok(joined) = base_dir.join(href) {
                    return joined.into();
                }
            }
        }
    }
    format!("{}/{}", toc_url.trim_end_matches('/'), href)
}

fn sanitize_filename(input: &str) -> String {
    let sanitized: String = input
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    let trimmed = sanitized.trim();
    if trimmed.is_empty() {
        "untitled".to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toc_page_queue_schedules_multiple_yaml_defined_pages_once() {
        let mut pages = TocPageQueue::new("https://example.test/novel/", Some("first".to_string()));
        assert_eq!(
            pages.pop_next(),
            Some((
                "https://example.test/novel/".to_string(),
                Some("first".to_string())
            ))
        );

        pages.schedule("https://example.test/novel/", "?p=2");
        pages.schedule("https://example.test/novel/", "?p=3");
        pages.schedule("https://example.test/novel/", "?p=2");

        assert_eq!(
            pages.pop_next(),
            Some(("https://example.test/novel/?p=2".to_string(), None))
        );
        assert_eq!(
            pages.pop_next(),
            Some(("https://example.test/novel/?p=3".to_string(), None))
        );
        assert_eq!(pages.pop_next(), None);
    }

    #[test]
    fn append_toc_chapters_renumbers_paginated_pages_globally() {
        let mut chapters = vec![Chapter {
            index: "1".to_string(),
            href: "/story/1/100".to_string(),
            subtitle: "一話".to_string(),
            chapter: None,
            subupdate: None,
        }];
        append_toc_chapters(
            &mut chapters,
            vec![
                Chapter {
                    index: "1".to_string(),
                    href: "/story/1/200".to_string(),
                    subtitle: "二話".to_string(),
                    chapter: None,
                    subupdate: None,
                },
                Chapter {
                    index: "2".to_string(),
                    href: "/story/1/201".to_string(),
                    subtitle: "三話".to_string(),
                    chapter: None,
                    subupdate: None,
                },
            ],
        );

        assert_eq!(
            chapters
                .iter()
                .map(|c| c.index.as_str())
                .collect::<Vec<_>>(),
            vec!["1", "2", "3"]
        );
    }
}

impl DownloadPipeline {
    pub fn downloader(&self) -> &Downloader {
        &self.downloader
    }
}
