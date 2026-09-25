use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

use crate::downloader::file_operations::{
    move_to_cache_dir, remove_cache_dir, save_raw_data, save_yaml, section_file_path,
};
use crate::downloader::pipeline::{DownloadPipeline, DownloadTarget};
use crate::downloader::state::DownloadState;
use crate::parser_selector::build_parser;
use crate::parsers::WebNovelParser;
use crate::rate_limiter::RateLimiter;
use crate::storage::{SectionStorage, SectionUpsert, library_database_path};
use crate::xhtml::{NormalizedSection, XhtmlSubsetNormalizer};

pub trait DownloadEvents {
    fn on_new_arrival(&mut self, _subtitle: &SubtitleInfo) {}
    fn on_hint(&mut self, _message: &str) {}
    fn on_progress(&mut self, _message: &str) {}
}

pub const HINT_503: &str = "503 responses may indicate temporary access restriction; increase download interval and retry later.";
pub const HINT_404: &str =
    "404 response received; confirm the chapter URL and retry later if recently updated.";

const SECTION_UPSERT_FLUSH_BATCH: usize = 5;

pub struct NoopEvents;
impl DownloadEvents for NoopEvents {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubtitleInfo {
    pub index: String,
    pub subtitle: String,
    pub file_subtitle: String,
    pub href: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SectionElement {
    pub data_type: String,
    pub introduction: String,
    pub postscript: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParserInfo {
    pub engine: String,
    pub domain: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SectionRecord {
    pub index: String,
    pub subtitle: String,
    pub element: SectionElement,
    pub parser_info: ParserInfo,
    pub download_time: DateTime<Utc>,
}

pub fn sections_download_and_save(
    pipeline: &DownloadPipeline,
    target: &DownloadTarget,
    subtitles: &[SubtitleInfo],
    limiter: &mut RateLimiter,
    state: &mut DownloadState,
) -> Result<usize> {
    let mut events = NoopEvents;
    sections_download_and_save_with_events(pipeline, target, subtitles, limiter, state, &mut events)
}

pub fn sections_download_and_save_with_events(
    pipeline: &DownloadPipeline,
    target: &DownloadTarget,
    subtitles: &[SubtitleInfo],
    limiter: &mut RateLimiter,
    state: &mut DownloadState,
    events: &mut dyn DownloadEvents,
) -> Result<usize> {
    let mut saved = 0usize;
    let mut save_least_one = false;
    let sqlite_path = library_database_path(&target.output_dir);
    let storage = SectionStorage::open(&sqlite_path)?;

    let parser = build_parser(&target.domain);
    let novel_id = &target.domain;
    let mut existing_states = storage.section_download_states(novel_id)?;
    let mut pending_section_upserts = Vec::new();
    if !subtitles.is_empty() {
        events.on_hint(HINT_503);
    }

    for item in subtitles {
        events.on_progress(&format!("downloading {}", item.index));
        if !limiter.wait_interruptible(|| false) {
            break;
        }
        let chapter = crate::parsers::Chapter {
            index: item.index.clone(),
            href: item.href.clone(),
            subtitle: item.subtitle.clone(),
            chapter: None,
            subupdate: None,
        };
        let html = pipeline.fetch_chapter_html(target, &chapter)?;
        let processed = parse_fetched_section(parser.as_ref(), &target.domain, item, html)?;
        save_processed_section(
            processed,
            target,
            novel_id,
            state,
            events,
            &mut existing_states,
            &mut saved,
            &mut save_least_one,
            &mut pending_section_upserts,
        )?;
        if saved == 1 || pending_section_upserts.len() >= SECTION_UPSERT_FLUSH_BATCH {
            flush_pending_section_upserts(&storage, &mut pending_section_upserts)?;
        }
    }

    flush_pending_section_upserts(&storage, &mut pending_section_upserts)?;

    if !save_least_one {
        events.on_hint("no sections saved; cache dir cleanup");
        remove_cache_dir(&target.output_dir)?;
    }

    Ok(saved)
}

fn flush_pending_section_upserts(
    storage: &SectionStorage,
    pending: &mut Vec<SectionUpsert>,
) -> Result<()> {
    if pending.is_empty() {
        return Ok(());
    }
    let batch = std::mem::take(pending);
    storage.upsert_sections(&batch)
}

struct ProcessedSectionJob {
    item: SubtitleInfo,
    normalized: NormalizedSection,
    source_signature: String,
    record: SectionRecord,
}

fn parse_fetched_section(
    parser: &dyn WebNovelParser,
    domain: &str,
    item: &SubtitleInfo,
    html: String,
) -> Result<ProcessedSectionJob> {
    let parsed = parser.parse_section(&html)?;
    let normalized = XhtmlSubsetNormalizer::normalize_section(
        parsed.introduction,
        parsed.body,
        parsed.postscript,
    );
    let source_signature = section_signature(
        normalized.introduction_xhtml.as_deref(),
        &normalized.body_xhtml,
        normalized.postscript_xhtml.as_deref(),
    );
    let record = SectionRecord {
        index: item.index.clone(),
        subtitle: item.subtitle.clone(),
        element: SectionElement {
            data_type: "xhtml_subset".to_string(),
            introduction: normalized.introduction_xhtml.clone().unwrap_or_default(),
            postscript: normalized.postscript_xhtml.clone().unwrap_or_default(),
            body: normalized.body_xhtml.clone(),
        },
        parser_info: ParserInfo {
            engine: "rust".to_string(),
            domain: domain.to_string(),
        },
        download_time: Utc::now(),
    };
    Ok(ProcessedSectionJob {
        item: item.clone(),
        normalized,
        source_signature,
        record,
    })
}

fn save_processed_section(
    processed: ProcessedSectionJob,
    target: &DownloadTarget,
    novel_id: &str,
    state: &mut DownloadState,
    events: &mut dyn DownloadEvents,
    existing_states: &mut HashMap<String, (String, bool)>,
    saved: &mut usize,
    save_least_one: &mut bool,
    pending_section_upserts: &mut Vec<SectionUpsert>,
) -> Result<()> {
    let item = processed.item;
    let normalized = processed.normalized;
    let source_signature = processed.source_signature;
    let record = processed.record;

    if let Some((existing_signature, true)) = existing_states.get(&item.index) {
        if existing_signature == &source_signature {
            events.on_progress("unchanged section, keeping cached body");
            state.mark_done(
                item.index.clone(),
                format!("{}:{}", item.subtitle, normalized.body_xhtml.len()),
            );
            *saved += 1;
            *save_least_one = true;
            return Ok(());
        }
    }

    let path = section_file_path(&target.output_dir, &item.index, &item.file_subtitle);
    let had_existing_file = path.exists();
    if had_existing_file {
        events.on_progress("existing section found, moving to diff cache");
        move_to_cache_dir(&target.output_dir, &path)?;
    } else {
        events.on_new_arrival(&item);
    }
    save_yaml(&path, &record)?;
    save_raw_data(
        &target.output_dir,
        &item.index,
        &item.file_subtitle,
        &record.element.body,
        ".xhtml",
    )?;
    pending_section_upserts.push(SectionUpsert {
        novel_id: novel_id.to_string(),
        chapter_index: item.index.clone(),
        subtitle: record.subtitle.clone(),
        source_url: item.href.clone(),
        intro_xhtml: normalized.introduction_xhtml.clone(),
        body_xhtml: normalized.body_xhtml.clone(),
        post_xhtml: normalized.postscript_xhtml.clone(),
        source_signature: source_signature.clone(),
        updated_at: record.download_time.to_rfc3339(),
    });
    existing_states.insert(item.index.clone(), (source_signature, true));
    state.mark_done(
        item.index.clone(),
        format!("{}:{}", record.subtitle, record.element.body.len()),
    );
    *saved += 1;
    *save_least_one = true;
    Ok(())
}

fn section_signature(introduction: Option<&str>, body: &str, postscript: Option<&str>) -> String {
    let mut hasher = Sha256::new();
    hasher.update(introduction.unwrap_or("").as_bytes());
    hasher.update([0]);
    hasher.update(body.as_bytes());
    hasher.update([0]);
    hasher.update(postscript.unwrap_or("").as_bytes());
    format!("sha256:{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::{
        DownloadEvents, ParserInfo, ProcessedSectionJob, SectionElement, SectionRecord,
        SubtitleInfo, save_processed_section, section_signature,
    };
    use crate::downloader::file_operations::{cache_dir, section_file_path};
    use crate::downloader::pipeline::DownloadTarget;
    use crate::downloader::state::DownloadState;
    use crate::storage::{SectionStorage, library_database_path};
    use crate::xhtml::NormalizedSection;
    use chrono::Utc;
    use std::fs;

    #[derive(Default)]
    struct RecordingEvents {
        new_arrivals: usize,
        hints: Vec<String>,
        progress: Vec<String>,
    }

    impl DownloadEvents for RecordingEvents {
        fn on_new_arrival(&mut self, _subtitle: &SubtitleInfo) {
            self.new_arrivals += 1;
        }

        fn on_hint(&mut self, message: &str) {
            self.hints.push(message.to_string());
        }

        fn on_progress(&mut self, message: &str) {
            self.progress.push(message.to_string());
        }
    }

    fn temp_output_dir(name: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "noveldl-{name}-{}-{}-{}",
            std::process::id(),
            Utc::now().timestamp_nanos_opt().unwrap_or_default(),
            NEXT_ID.fetch_add(1, Ordering::Relaxed)
        ));
        let output = path.join("novel");
        fs::create_dir_all(&output).unwrap();
        output
    }

    #[test]
    fn save_processed_section_moves_existing_file_without_reporting_new_arrival() {
        let output_dir = temp_output_dir("existing-section");
        let target = DownloadTarget {
            domain: "example.test".to_string(),
            toc_url: "https://example.test/novel/".to_string(),
            output_dir: output_dir.clone(),
        };
        let item = SubtitleInfo {
            index: "1".to_string(),
            subtitle: "One".to_string(),
            file_subtitle: "One".to_string(),
            href: "/1".to_string(),
        };
        let existing_path = section_file_path(&output_dir, &item.index, &item.file_subtitle);
        fs::create_dir_all(existing_path.parent().unwrap()).unwrap();
        fs::write(&existing_path, "old: body\n").unwrap();

        let storage = SectionStorage::open(&library_database_path(&output_dir)).unwrap();
        storage
            .upsert_novel(
                &target.domain,
                "Example",
                "Author",
                &target.toc_url,
                &target.domain,
                &output_dir,
                1,
                &Utc::now().to_rfc3339(),
            )
            .unwrap();
        let normalized = NormalizedSection {
            introduction_xhtml: None,
            body_xhtml: "<p>new</p>".to_string(),
            postscript_xhtml: None,
        };
        let processed = ProcessedSectionJob {
            item: item.clone(),
            source_signature: section_signature(None, &normalized.body_xhtml, None),
            normalized,
            record: SectionRecord {
                index: item.index.clone(),
                subtitle: item.subtitle.clone(),
                element: SectionElement {
                    data_type: "xhtml_subset".to_string(),
                    introduction: String::new(),
                    postscript: String::new(),
                    body: "<p>new</p>".to_string(),
                },
                parser_info: ParserInfo {
                    engine: "rust".to_string(),
                    domain: target.domain.clone(),
                },
                download_time: Utc::now(),
            },
        };
        let mut state = DownloadState::default();
        let mut events = RecordingEvents::default();
        let mut existing_states = storage.section_download_states(&target.domain).unwrap();
        let mut saved = 0;
        let mut save_least_one = false;
        let mut pending_section_upserts = Vec::new();

        save_processed_section(
            processed,
            &target,
            &target.domain,
            &mut state,
            &mut events,
            &mut existing_states,
            &mut saved,
            &mut save_least_one,
            &mut pending_section_upserts,
        )
        .unwrap();

        assert_eq!(events.new_arrivals, 0);
        let cached_files = fs::read_dir(cache_dir(&output_dir))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert_eq!(cached_files.len(), 1);
        assert!(cached_files[0].starts_with("1 One"));
        assert!(cached_files[0].ends_with(".yaml"));
        assert!(existing_path.exists());
        assert_eq!(saved, 1);
        assert!(save_least_one);
        assert_eq!(pending_section_upserts.len(), 1);
        storage.upsert_sections(&pending_section_upserts).unwrap();
        fs::remove_dir_all(output_dir).unwrap();
    }
    #[test]
    fn section_signature_changes_when_any_part_changes() {
        let base = section_signature(Some("intro"), "body", Some("post"));
        assert_eq!(base, section_signature(Some("intro"), "body", Some("post")));
        assert_ne!(
            base,
            section_signature(Some("intro2"), "body", Some("post"))
        );
        assert_ne!(
            base,
            section_signature(Some("intro"), "body2", Some("post"))
        );
        assert_ne!(
            base,
            section_signature(Some("intro"), "body", Some("post2"))
        );
    }
}
