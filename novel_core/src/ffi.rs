use crate::parsers::nokogiri_compat::NokogiriCompatParser;
use crate::parsers::base::WebNovelParser;
use crate::config_manager::ConfigManager;
use crate::downloader::class_methods::create_subdirectory_name;
use crate::downloader::file_operations;
use crate::downloader::pipeline::{DownloadPipeline, DownloadTarget};
use crate::downloader::{
    clear_access_caches, set_browser_fetch_command, set_extra_cookie_for_domain,
};
use crate::parser_selector::build_parser;
use crate::parsers::Chapter;
use crate::rate_limiter::RateLimiter;
use crate::storage::{
    SectionStorage, SectionUpsert, StoredTocChapter, decompress_zstd, discover_downloaded_novels,
    library_database_path,
};
use crate::xhtml::XhtmlSubsetNormalizer;
use serde::{Deserialize, Serialize};
use serde_yaml::Value;
use std::collections::{BTreeMap, HashMap};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::{env, fs};

// ── cancellation ───────────────────────────────────────────────────────────
static CANCEL_REQUESTED: AtomicBool = AtomicBool::new(false);

// ── live progress ──────────────────────────────────────────────────────────
static PROG_TOTAL: AtomicUsize = AtomicUsize::new(0);
static PROG_DONE: AtomicUsize = AtomicUsize::new(0);
static PROG_SKIPPED: AtomicUsize = AtomicUsize::new(0);
static PROG_FAILED: AtomicUsize = AtomicUsize::new(0);
static PROG_CURRENT: OnceLock<Mutex<String>> = OnceLock::new();
static PROG_RUNNING: AtomicBool = AtomicBool::new(false);
static PROGRESS_CALLBACK: OnceLock<Mutex<Option<extern "C" fn(*const c_char)>>> = OnceLock::new();
static STORAGE_WRITE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn storage_write_lock() -> std::sync::MutexGuard<'static, ()> {
    STORAGE_WRITE_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn progress_snapshot_string() -> String {
    let total = PROG_TOTAL.load(Ordering::Relaxed);
    let done = PROG_DONE.load(Ordering::Relaxed);
    let skipped = PROG_SKIPPED.load(Ordering::Relaxed);
    let failed = PROG_FAILED.load(Ordering::Relaxed);
    let running = PROG_RUNNING.load(Ordering::Relaxed);
    let current = PROG_CURRENT
        .get_or_init(|| Mutex::new(String::new()))
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default();
    format!(
        "OK:{}:{}:{}:{}:{}:{}",
        total,
        done,
        skipped,
        failed,
        if running { 1 } else { 0 },
        current
    )
}

fn notify_progress_observer() {
    let Some(lock) = PROGRESS_CALLBACK.get() else {
        return;
    };
    let Ok(guard) = lock.lock() else {
        return;
    };
    let Some(callback) = *guard else {
        return;
    };
    drop(guard);

    let Ok(snapshot) = CString::new(progress_snapshot_string()) else {
        return;
    };
    callback(snapshot.as_ptr());
}

fn set_progress_running(running: bool) {
    PROG_RUNNING.store(running, Ordering::Relaxed);
    notify_progress_observer();
}

fn set_progress(total: usize, done: usize, skipped: usize, current: &str) {
    let failed = if total == 0 && done == 0 && skipped == 0 {
        0
    } else {
        PROG_FAILED.load(Ordering::Relaxed)
    };
    set_progress_with_failed(total, done, skipped, failed, current);
}

fn set_progress_with_failed(
    total: usize,
    done: usize,
    skipped: usize,
    failed: usize,
    current: &str,
) {
    PROG_TOTAL.store(total, Ordering::Relaxed);
    PROG_DONE.store(done, Ordering::Relaxed);
    PROG_SKIPPED.store(skipped, Ordering::Relaxed);
    PROG_FAILED.store(failed, Ordering::Relaxed);
    if let Ok(mut g) = PROG_CURRENT
        .get_or_init(|| Mutex::new(String::new()))
        .lock()
    {
        *g = current.to_string();
    }
    notify_progress_observer();
}

const DEFAULT_BROWSER_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) \
     AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";

// ── novel_id derivation ────────────────────────────────────────────────────
/// Stable, human-readable novel identifier derived from TOC URL.
/// e.g. "ncode.syosetu.com:/n1234ab"  or  "kakuyomu.jp:/works/123"
pub fn novel_id_from_toc_url(toc_url: &str) -> String {
    if let Ok(u) = url::Url::parse(toc_url) {
        let host = u
            .host_str()
            .unwrap_or("unknown")
            .to_ascii_lowercase()
            .trim_start_matches("www.")
            .to_string();
        let path = u.path().trim_end_matches('/').to_string();
        format!("{}:{}", host, path)
    } else {
        toc_url.to_ascii_lowercase()
    }
}

// ── internal download state ────────────────────────────────────────────────
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct LocalDownloadState {
    chapter_signatures: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct HtmlChapterInput {
    index: String,
    href: String,
    subtitle: String,
    chapter: Option<String>,
    subupdate: Option<String>,
    html: String,
}

fn chapter_signature(ch: &crate::parsers::Chapter) -> String {
    format!(
        "{}|{}|{}|{}",
        ch.href,
        ch.subtitle,
        ch.chapter.clone().unwrap_or_default(),
        ch.subupdate.clone().unwrap_or_default()
    )
}

#[cfg(test)]
fn should_download_chapter(
    storage: &SectionStorage,
    _prev_state: &LocalDownloadState,
    _scoped_key: &str,
    novel_id: &str,
    chapter_index: &str,
    signature: &str,
) -> Result<bool, String> {
    match storage
        .section_download_state(novel_id, chapter_index)
        .map_err(|e| e.to_string())?
    {
        Some((_, false)) | None => Ok(true),
        Some((stored, true)) if !stored.is_empty() => Ok(stored != signature),
        Some((_, true)) => Ok(false),
    }
}

fn should_download_chapter_from_state(
    states: &HashMap<String, (String, bool)>,
    chapter_index: &str,
    signature: &str,
) -> bool {
    match states.get(chapter_index) {
        Some((_, false)) | None => true,
        Some((stored, true)) if !stored.is_empty() => stored != signature,
        Some((_, true)) => false,
    }
}

// ── FFI helpers ────────────────────────────────────────────────────────────
fn cstr_to_string(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("null pointer".to_string());
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|e| e.to_string())
        .map(|s| s.to_string())
}

fn into_c_string(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("invalid utf8").unwrap())
        .into_raw()
}

fn build_target_from_url(url: &str, output_dir: PathBuf) -> Result<DownloadTarget, String> {
    let domain = extract_domain(url)?;
    Ok(DownloadTarget {
        domain,
        toc_url: url.to_string(),
        output_dir,
    })
}

// ── public C exports ───────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}

/// In-memory zstd decompression. Returns "OK:<utf8 text>" or "ERR:<msg>".
#[unsafe(no_mangle)]
pub extern "C" fn novel_core_decompress_zstd_blob(data: *const u8, len: usize) -> *mut c_char {
    if data.is_null() || len == 0 {
        return into_c_string("ERR:empty input".to_string());
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    match decompress_zstd(bytes) {
        Ok(s) => into_c_string(format!("OK:{}", s)),
        Err(e) => into_c_string(format!("ERR:{}", e)),
    }
}

/// Returns live download progress as "OK:<total>:<done>:<skipped>:<failed>:<running>:<current_subtitle>"
#[unsafe(no_mangle)]
pub extern "C" fn novel_core_get_download_progress() -> *mut c_char {
    into_c_string(progress_snapshot_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_set_download_progress_callback(
    callback: Option<extern "C" fn(*const c_char)>,
) {
    if let Ok(mut guard) = PROGRESS_CALLBACK.get_or_init(|| Mutex::new(None)).lock() {
        *guard = callback;
    }
    notify_progress_observer();
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_download_first_n(
    url: *const c_char,
    episodes: u32,
    output_dir: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        CANCEL_REQUESTED.store(false, Ordering::Relaxed);
        set_progress_running(true);
        set_progress(0, 0, 0, "目次を取得中");
        let url = cstr_to_string(url)?;
        let output_dir = PathBuf::from(cstr_to_string(output_dir)?);
        let target = build_target_from_url(&url, output_dir)?;
        let pipeline = DownloadPipeline::new(DEFAULT_BROWSER_UA).map_err(|e| e.to_string())?;

        let (toc, title, author) = fetch_toc_and_metadata(&pipeline, &target)?;

        let res = download_chapters_with_state(
            &pipeline,
            &target,
            toc,
            episodes as usize,
            &title,
            &author,
            SectionFlushPolicy::bulk(),
        );
        set_progress_running(false);
        res
    })();
    set_progress_running(false);
    match result {
        Ok(msg) => into_c_string(format!("OK:{msg}")),
        Err(err) => {
            set_progress(0, 0, 0, "エラー");
            into_c_string(format!("ERR:{err}"))
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_create_library_placeholder(
    url: *const c_char,
    output_dir: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let url = cstr_to_string(url)?;
        let output_dir = PathBuf::from(cstr_to_string(output_dir)?);
        let target = build_target_from_url(&url, output_dir)?;
        ensure_dirs(&target)?;
        let sqlite_path = library_database_path(&target.output_dir);
        let storage = SectionStorage::open(&sqlite_path).map_err(|e| e.to_string())?;
        let novel_id = novel_id_from_toc_url(&target.toc_url);
        let title = placeholder_title_for_url(&target.toc_url);
        let _write_guard = storage_write_lock();
        storage
            .upsert_novel(
                &novel_id,
                &title,
                "",
                &target.toc_url,
                &target.domain,
                &target.output_dir,
                0,
                &chrono::Utc::now().to_rfc3339(),
            )
            .map_err(|e| e.to_string())?;
        Ok(format!(
            "placeholder saved into {}",
            target.output_dir.display()
        ))
    })();
    match result {
        Ok(msg) => into_c_string(format!("OK:{msg}")),
        Err(err) => into_c_string(format!("ERR:{err}")),
    }
}

fn placeholder_title_for_url(toc_url: &str) -> String {
    if let Ok(url) = url::Url::parse(toc_url) {
        let host = url.host_str().unwrap_or("小説");
        let path = url.path().trim_matches('/');
        if path.is_empty() {
            return host.to_string();
        }
        return format!("{} / {}", host, path);
    }
    toc_url.to_string()
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_fetch_toc_only(
    url: *const c_char,
    output_dir: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        CANCEL_REQUESTED.store(false, Ordering::Relaxed);
        set_progress_running(true);
        set_progress(0, 0, 0, "目次を取得中");
        let url = cstr_to_string(url)?;
        let output_dir = PathBuf::from(cstr_to_string(output_dir)?);
        let target = build_target_from_url(&url, output_dir)?;
        ensure_dirs(&target)?;
        let sqlite_path = library_database_path(&target.output_dir);
        let mut storage = SectionStorage::open(&sqlite_path).map_err(|e| e.to_string())?;
        let novel_id = novel_id_from_toc_url(&target.toc_url);
        let pipeline = DownloadPipeline::new(DEFAULT_BROWSER_UA).map_err(|e| e.to_string())?;
        let toc = pipeline
            .fetch_toc_with_metadata_incremental(&target, |chapters, title, author| {
                {
                    let _write_guard = storage_write_lock();
                    upsert_toc_placeholders(
                        &mut storage,
                        &target,
                        &novel_id,
                        title,
                        author,
                        chapters,
                    )
                    .map_err(anyhow::Error::msg)?;
                }
                set_progress(chapters.len(), 0, chapters.len(), "目次を保存中");
                Ok(())
            })
            .map_err(|e| e.to_string())?;
        set_progress(toc.chapters.len(), 0, toc.chapters.len(), "目次取得完了");
        Ok(format!(
            "saved toc {} episodes into {}",
            toc.chapters.len(),
            target.output_dir.display()
        ))
    })();
    set_progress_running(false);
    match result {
        Ok(msg) => into_c_string(format!("OK:{msg}")),
        Err(err) => {
            set_progress(0, 0, 0, "エラー");
            into_c_string(format!("ERR:{err}"))
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_download_from_chapter(
    url: *const c_char,
    chapter_index: *const c_char,
    output_dir: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        CANCEL_REQUESTED.store(false, Ordering::Relaxed);
        set_progress_running(true);
        set_progress(0, 0, 0, "目次を取得中");
        let url = cstr_to_string(url)?;
        let start_index = cstr_to_string(chapter_index)?;
        let output_dir = PathBuf::from(cstr_to_string(output_dir)?);
        let target = build_target_from_url(&url, output_dir)?;
        let pipeline = DownloadPipeline::new(DEFAULT_BROWSER_UA).map_err(|e| e.to_string())?;
        let (toc, title, author) = fetch_toc_and_metadata_prefer_cache(&pipeline, &target)?;
        let start = toc
            .iter()
            .position(|chapter| chapter.index == start_index)
            .unwrap_or(0);
        let chapters_from_start = toc[start..].to_vec();
        let res = download_chapters_with_state(
            &pipeline,
            &target,
            chapters_from_start,
            usize::MAX,
            &title,
            &author,
            SectionFlushPolicy::bulk(),
        );
        set_progress_running(false);
        res
    })();
    set_progress_running(false);
    match result {
        Ok(msg) => into_c_string(format!("OK:{msg}")),
        Err(err) => {
            set_progress(0, 0, 0, "エラー");
            into_c_string(format!("ERR:{err}"))
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_download_cached_from_chapter(
    url: *const c_char,
    chapter_index: *const c_char,
    output_dir: *const c_char,
) -> *mut c_char {
    download_cached_from_chapter_with_policy(
        url,
        chapter_index,
        output_dir,
        SectionFlushPolicy::bulk(),
        "保存済み目次から本文DLを開始",
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_download_reader_cached_from_chapter(
    url: *const c_char,
    chapter_index: *const c_char,
    output_dir: *const c_char,
) -> *mut c_char {
    download_cached_from_chapter_with_policy(
        url,
        chapter_index,
        output_dir,
        SectionFlushPolicy::reader_bound(),
        "リーダー向け本文DLを開始",
    )
}

fn download_cached_from_chapter_with_policy(
    url: *const c_char,
    chapter_index: *const c_char,
    output_dir: *const c_char,
    flush_policy: SectionFlushPolicy,
    start_message: &str,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        CANCEL_REQUESTED.store(false, Ordering::Relaxed);
        set_progress_running(true);
        set_progress(0, 0, 0, start_message);
        let url = cstr_to_string(url)?;
        let start_index = cstr_to_string(chapter_index)?;
        let output_dir = PathBuf::from(cstr_to_string(output_dir)?);
        let target = build_target_from_url(&url, output_dir)?;
        let pipeline = DownloadPipeline::new(DEFAULT_BROWSER_UA).map_err(|e| e.to_string())?;
        let (toc, title, author) = fetch_toc_and_metadata_for_body_download(&pipeline, &target)?;
        let start = if start_index.is_empty() {
            0
        } else {
            toc.iter()
                .position(|chapter| chapter.index == start_index)
                .unwrap_or(0)
        };
        let chapters_from_start = toc[start..].to_vec();
        let res = download_chapters_with_state(
            &pipeline,
            &target,
            chapters_from_start,
            usize::MAX,
            &title,
            &author,
            flush_policy,
        );
        set_progress_running(false);
        res
    })();
    match result {
        Ok(msg) => into_c_string(format!("OK:{msg}")),
        Err(err) => {
            set_progress_running(false);
            set_progress(0, 0, 0, "エラー");
            into_c_string(format!("ERR:{err}"))
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_download_first_n_from_html(
    url: *const c_char,
    toc_html: *const c_char,
    chapters_json: *const c_char,
    episodes: u32,
    output_dir: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        CANCEL_REQUESTED.store(false, Ordering::Relaxed);
        set_progress_running(true);
        set_progress(0, 0, 0, "目次を解析中");
        let url = cstr_to_string(url)?;
        let toc_html = cstr_to_string(toc_html)?;
        let chapters_json = cstr_to_string(chapters_json)?;
        let output_dir = PathBuf::from(cstr_to_string(output_dir)?);
        let target = build_target_from_url(&url, output_dir)?;
        let parser = build_parser(&target.domain);
        let toc = parser.parse_toc(&toc_html).map_err(|e| e.to_string())?;
        let mut title = toc.title.clone().unwrap_or_default();
        let mut author = toc.author.clone().unwrap_or_default();
        let parsed_inputs: Vec<HtmlChapterInput> =
            serde_json::from_str(&chapters_json).map_err(|e| e.to_string())?;
        let browser_input_chapters: Vec<_> = parsed_inputs
            .iter()
            .map(|input| crate::parsers::Chapter {
                index: input.index.clone(),
                href: input.href.clone(),
                subtitle: input.subtitle.clone(),
                chapter: input.chapter.clone(),
                subupdate: input.subupdate.clone(),
            })
            .collect();
        let toc_chapters = if browser_input_chapters.is_empty() {
            if episodes == 0 && !toc_html.trim().is_empty() && !toc.chapters.is_empty() {
                toc.chapters.clone()
            } else {
                let pipeline =
                    DownloadPipeline::new(DEFAULT_BROWSER_UA).map_err(|e| e.to_string())?;
                let (chapters, fetched_title, fetched_author) = fetch_toc_from_html_or_network(
                    &pipeline,
                    &target,
                    &toc_html,
                    toc.chapters.clone(),
                )?;
                if !fetched_title.is_empty() {
                    title = fetched_title;
                }
                if !fetched_author.is_empty() {
                    author = fetched_author;
                }
                chapters
            }
        } else {
            browser_input_chapters
        };
        let res = download_chapters_from_html_with_state(
            &target,
            toc_chapters,
            parsed_inputs,
            episodes as usize,
            &title,
            &author,
        );
        set_progress_running(false);
        res
    })();
    set_progress_running(false);
    match result {
        Ok(msg) => into_c_string(format!("OK:{msg}")),
        Err(err) => {
            set_progress(0, 0, 0, "エラー");
            into_c_string(format!("ERR:{err}"))
        }
    }
}

// ── download helpers ───────────────────────────────────────────────────────

fn upsert_toc_placeholders(
    storage: &mut SectionStorage,
    target: &DownloadTarget,
    novel_id: &str,
    title: &str,
    author: &str,
    toc: &[crate::parsers::Chapter],
) -> Result<(), String> {
    let now = chrono::Utc::now().to_rfc3339();
    storage
        .upsert_novel(
            novel_id,
            title,
            author,
            &target.toc_url,
            &target.domain,
            &target.output_dir,
            toc.len(),
            &now,
        )
        .map_err(|e| e.to_string())?;

    let chapters = toc
        .iter()
        .map(|chapter| StoredTocChapter {
            index: chapter.index.clone(),
            href: chapter.href.clone(),
            subtitle: chapter.subtitle.clone(),
        })
        .collect::<Vec<_>>();
    storage
        .upsert_section_placeholders(novel_id, &chapters, &now)
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn cached_toc_and_metadata(
    target: &DownloadTarget,
) -> Result<Option<(Vec<Chapter>, String, String)>, String> {
    let sqlite_path = library_database_path(&target.output_dir);
    if !sqlite_path.is_file() {
        return Ok(None);
    }

    set_progress(0, 0, 0, "保存済み目次を確認中");
    let storage = SectionStorage::open(&sqlite_path).map_err(|e| e.to_string())?;
    let novel_id = novel_id_from_toc_url(&target.toc_url);
    let cached = storage
        .cached_toc_chapters(&novel_id)
        .map_err(|e| e.to_string())?;
    if cached.is_empty() {
        return Ok(None);
    }

    let meta = storage
        .novel_metadata(&novel_id)
        .map_err(|e| e.to_string())?
        .unwrap_or(crate::storage::StoredNovelMetadata {
            title: String::new(),
            author: String::new(),
        });
    let toc = cached
        .into_iter()
        .map(|chapter| Chapter {
            index: chapter.index,
            href: chapter.href,
            subtitle: chapter.subtitle,
            chapter: None,
            subupdate: None,
        })
        .collect();
    Ok(Some((toc, meta.title, meta.author)))
}

fn fetch_toc_and_metadata(
    pipeline: &DownloadPipeline,
    target: &DownloadTarget,
) -> Result<(Vec<crate::parsers::Chapter>, String, String), String> {
    let toc = pipeline
        .fetch_toc_with_metadata(target)
        .map_err(|e| e.to_string())?;
    Ok((toc.chapters, toc.title, toc.author))
}

fn fetch_toc_from_html_or_network(
    pipeline: &DownloadPipeline,
    target: &DownloadTarget,
    toc_html: &str,
    parsed_fallback_chapters: Vec<crate::parsers::Chapter>,
) -> Result<(Vec<crate::parsers::Chapter>, String, String), String> {
    if !toc_html.trim().is_empty() {
        let chapters = pipeline
            .fetch_toc_from_initial_html(target, toc_html)
            .unwrap_or(parsed_fallback_chapters);
        if !chapters.is_empty() {
            return Ok((chapters, String::new(), String::new()));
        }
    }

    set_progress(0, 0, 0, "目次URLから再取得中");
    fetch_toc_and_metadata(pipeline, target)
}

fn fetch_toc_and_metadata_prefer_cache(
    pipeline: &DownloadPipeline,
    target: &DownloadTarget,
) -> Result<(Vec<crate::parsers::Chapter>, String, String), String> {
    if let Some(cached) = cached_toc_and_metadata(target)? {
        set_progress(cached.0.len(), 0, cached.0.len(), "保存済み目次を使用");
        return Ok(cached);
    }
    fetch_toc_and_metadata(pipeline, target)
}

fn fetch_toc_and_metadata_for_body_download(
    pipeline: &DownloadPipeline,
    target: &DownloadTarget,
) -> Result<(Vec<crate::parsers::Chapter>, String, String), String> {
    if let Some(cached) = cached_toc_and_metadata(target)? {
        set_progress(
            cached.0.len(),
            0,
            cached.0.len(),
            "保存済み目次から本文DLを開始",
        );
        return Ok(cached);
    }
    set_progress(0, 0, 0, "保存済み目次なし: 目次を取得中");
    fetch_toc_and_metadata(pipeline, target)
}

fn flush_pending_section_upserts(
    storage: &SectionStorage,
    pending: &mut Vec<SectionUpsert>,
) -> Result<(), String> {
    if pending.is_empty() {
        return Ok(());
    }
    let batch = std::mem::take(pending);
    let _write_guard = storage_write_lock();
    storage.upsert_sections(&batch).map_err(|e| e.to_string())
}

const SECTION_UPSERT_FLUSH_BATCH: usize = 5;
const READER_IMMEDIATE_FLUSH_WINDOW: usize = 15;

#[derive(Clone, Copy)]
enum SectionFlushPolicy {
    Batch {
        batch_size: usize,
    },
    ReaderImmediateWindow {
        immediate_chapters: usize,
        batch_size: usize,
    },
}

impl SectionFlushPolicy {
    fn bulk() -> Self {
        Self::Batch {
            batch_size: SECTION_UPSERT_FLUSH_BATCH,
        }
    }

    fn reader_bound() -> Self {
        Self::ReaderImmediateWindow {
            immediate_chapters: READER_IMMEDIATE_FLUSH_WINDOW,
            batch_size: SECTION_UPSERT_FLUSH_BATCH,
        }
    }

    fn should_flush(self, chapter_offset_from_start: usize, pending_len: usize) -> bool {
        match self {
            Self::Batch { batch_size } => pending_len >= batch_size,
            Self::ReaderImmediateWindow {
                immediate_chapters,
                batch_size,
            } => chapter_offset_from_start < immediate_chapters || pending_len >= batch_size,
        }
    }
}

fn download_interval_ms() -> u64 {
    std::env::var("NOVELDL_DOWNLOAD_INTERVAL_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(5_000)
}

fn ensure_dirs(target: &DownloadTarget) -> Result<(), String> {
    file_operations::ensure_dir(&target.output_dir).map_err(|e| e.to_string())?;
    let section_parent = file_operations::section_file_path(&target.output_dir, "", "")
        .parent()
        .unwrap_or(&target.output_dir)
        .to_path_buf();
    file_operations::ensure_dir(&section_parent).map_err(|e| e.to_string())?;
    file_operations::ensure_dir(&file_operations::cache_dir(&target.output_dir))
        .map_err(|e| e.to_string())?;
    file_operations::ensure_dir(&target.output_dir.join(file_operations::RAW_DATA_DIR_NAME))
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn write_download_state_atomic(
    path: &std::path::Path,
    state: &LocalDownloadState,
) -> Result<(), String> {
    let tmp_path = path.with_extension("json.tmp");
    let payload = serde_json::to_string_pretty(state).map_err(|e| e.to_string())?;
    fs::write(&tmp_path, payload).map_err(|e| e.to_string())?;
    fs::rename(&tmp_path, path)
        .or_else(|_| {
            let _ = fs::remove_file(path);
            fs::rename(&tmp_path, path)
        })
        .map_err(|e| e.to_string())
}

fn download_chapters_with_state(
    pipeline: &DownloadPipeline,
    target: &DownloadTarget,
    toc: Vec<crate::parsers::Chapter>,
    episodes: usize,
    title: &str,
    author: &str,
    flush_policy: SectionFlushPolicy,
) -> Result<String, String> {
    let novel_id = novel_id_from_toc_url(&target.toc_url);
    let state_path = target.output_dir.join(".download_state.json");
    let sqlite_path = library_database_path(&target.output_dir);

    ensure_dirs(target)?;
    let mut storage = SectionStorage::open(&sqlite_path).map_err(|e| e.to_string())?;
    let download_states = {
        let _write_guard = storage_write_lock();
        upsert_toc_placeholders(&mut storage, target, &novel_id, title, author, &toc)?;
        storage
            .section_download_states(&novel_id)
            .map_err(|e| e.to_string())?
    };

    let mut pending_section_upserts: Vec<SectionUpsert> = Vec::new();

    let toc_count = toc.len();
    let chapters_to_dl: Vec<_> = toc.into_iter().take(episodes).collect();
    let total = chapters_to_dl.len();
    set_progress(total, 0, 0, "");

    let mut next_state = LocalDownloadState::default();
    let mut skipped = 0usize;
    let mut failed = 0usize;
    let mut updated = 0usize;
    let mut downloaded = 0usize;
    let mut limiter = RateLimiter::new_millis(download_interval_ms());

    for (chapter_offset, chapter) in chapters_to_dl.into_iter().enumerate() {
        if CANCEL_REQUESTED.load(Ordering::Relaxed) {
            flush_pending_section_upserts(&storage, &mut pending_section_upserts)?;
            return Err("cancelled".to_string());
        }

        set_progress_with_failed(total, downloaded, skipped, failed, &chapter.subtitle);

        let sig = chapter_signature(&chapter);
        let scoped_key = format!("{}::{}", novel_id, chapter.index);
        let needs_refresh =
            should_download_chapter_from_state(&download_states, &chapter.index, &sig);

        if !needs_refresh {
            next_state
                .chapter_signatures
                .insert(scoped_key.clone(), sig.clone());
            skipped += 1;
            set_progress_with_failed(total, downloaded, skipped, failed, &chapter.subtitle);
            continue;
        }

        // Rate-limit: no wait on first episode, configurable wait on subsequent network fetches.
        if !limiter.wait_interruptible(|| CANCEL_REQUESTED.load(Ordering::Relaxed)) {
            flush_pending_section_upserts(&storage, &mut pending_section_upserts)?;
            return Err("cancelled".to_string());
        }

        let dl = match pipeline.fetch_chapter(target, &chapter) {
            Ok(downloaded) => downloaded,
            Err(_err) => {
                failed += 1;
                set_progress_with_failed(
                    total,
                    downloaded,
                    skipped,
                    failed,
                    &format!("取得失敗: {}", chapter.subtitle),
                );
                continue;
            }
        };
        let norm = XhtmlSubsetNormalizer::normalize_section(
            dl.section.introduction,
            dl.section.body,
            dl.section.postscript,
        );
        pending_section_upserts.push(SectionUpsert {
            novel_id: novel_id.clone(),
            chapter_index: chapter.index.clone(),
            subtitle: chapter.subtitle.clone(),
            source_url: chapter.href.clone(),
            intro_xhtml: norm.introduction_xhtml.clone(),
            body_xhtml: norm.body_xhtml.clone(),
            post_xhtml: norm.postscript_xhtml.clone(),
            source_signature: sig.clone(),
            updated_at: chrono::Utc::now().to_rfc3339(),
        });
        if flush_policy.should_flush(chapter_offset, pending_section_upserts.len()) {
            flush_pending_section_upserts(&storage, &mut pending_section_upserts)?;
        }
        next_state
            .chapter_signatures
            .insert(scoped_key.clone(), sig.clone());

        downloaded += 1;
        if needs_refresh {
            updated += 1;
        }
        set_progress_with_failed(total, downloaded, skipped, failed, &chapter.subtitle);
    }

    flush_pending_section_upserts(&storage, &mut pending_section_upserts)?;

    // Persist novel metadata for the downloaded-novel list.
    {
        let _write_guard = storage_write_lock();
        storage
            .upsert_novel(
                &novel_id,
                title,
                author,
                &target.toc_url,
                &target.domain,
                &target.output_dir,
                toc_count,
                &chrono::Utc::now().to_rfc3339(),
            )
            .map_err(|e| e.to_string())?;
    }

    write_download_state_atomic(&state_path, &next_state)?;

    set_progress_with_failed(total, downloaded, skipped, failed, "完了");

    Ok(format!(
        "saved {} episodes (updated {}), skipped {} existing, failed {} into {}",
        downloaded,
        updated,
        skipped,
        failed,
        target.output_dir.display()
    ))
}

fn download_chapters_from_html_with_state(
    target: &DownloadTarget,
    toc: Vec<crate::parsers::Chapter>,
    html_inputs: Vec<HtmlChapterInput>,
    episodes: usize,
    title: &str,
    author: &str,
) -> Result<String, String> {
    let novel_id = novel_id_from_toc_url(&target.toc_url);
    let parser = build_parser(&target.domain);
    let mut html_map = BTreeMap::new();
    for i in html_inputs {
        html_map.insert(i.index.clone(), i);
    }

    let state_path = target.output_dir.join(".download_state.json");
    let sqlite_path = library_database_path(&target.output_dir);

    ensure_dirs(target)?;
    let mut storage = SectionStorage::open(&sqlite_path).map_err(|e| e.to_string())?;
    let download_states = {
        let _write_guard = storage_write_lock();
        upsert_toc_placeholders(&mut storage, target, &novel_id, title, author, &toc)?;
        storage
            .section_download_states(&novel_id)
            .map_err(|e| e.to_string())?
    };

    let mut pending_section_upserts: Vec<SectionUpsert> = Vec::new();

    let toc_count = toc.len();
    let chapters_to_dl: Vec<_> = toc.into_iter().take(episodes).collect();
    let total = chapters_to_dl.len();
    set_progress(total, 0, 0, "");

    let mut next_state = LocalDownloadState::default();
    let mut skipped = 0usize;
    let mut failed = 0usize;
    let mut updated = 0usize;
    let mut downloaded = 0usize;

    for (_chapter_offset, chapter) in chapters_to_dl.into_iter().enumerate() {
        if CANCEL_REQUESTED.load(Ordering::Relaxed) {
            flush_pending_section_upserts(&storage, &mut pending_section_upserts)?;
            return Err("cancelled".to_string());
        }
        set_progress_with_failed(total, downloaded, skipped, failed, &chapter.subtitle);

        let sig = chapter_signature(&chapter);
        let scoped_key = format!("{}::{}", novel_id, chapter.index);
        let needs_refresh =
            should_download_chapter_from_state(&download_states, &chapter.index, &sig);

        if !needs_refresh {
            next_state
                .chapter_signatures
                .insert(scoped_key.clone(), sig.clone());
            skipped += 1;
            set_progress_with_failed(total, downloaded, skipped, failed, &chapter.subtitle);
            continue;
        }

        let Some(html_entry) = html_map.get(&chapter.index) else {
            continue;
        };
        if html_entry.html.trim().is_empty() {
            continue;
        }
        let section = match parser.parse_section(&html_entry.html) {
            Ok(section) => section,
            Err(_err) => {
                failed += 1;
                set_progress_with_failed(
                    total,
                    downloaded,
                    skipped,
                    failed,
                    &format!("解析失敗: {}", chapter.subtitle),
                );
                continue;
            }
        };
        let norm = XhtmlSubsetNormalizer::normalize_section(
            section.introduction,
            section.body,
            section.postscript,
        );
        pending_section_upserts.push(SectionUpsert {
            novel_id: novel_id.clone(),
            chapter_index: chapter.index.clone(),
            subtitle: chapter.subtitle.clone(),
            source_url: chapter.href.clone(),
            intro_xhtml: norm.introduction_xhtml.clone(),
            body_xhtml: norm.body_xhtml.clone(),
            post_xhtml: norm.postscript_xhtml.clone(),
            source_signature: sig.clone(),
            updated_at: chrono::Utc::now().to_rfc3339(),
        });
        if downloaded == 0 || pending_section_upserts.len() >= SECTION_UPSERT_FLUSH_BATCH {
            flush_pending_section_upserts(&storage, &mut pending_section_upserts)?;
        }
        next_state
            .chapter_signatures
            .insert(scoped_key.clone(), sig.clone());
        downloaded += 1;
        if needs_refresh {
            updated += 1;
        }
        set_progress_with_failed(total, downloaded, skipped, failed, &chapter.subtitle);
    }

    flush_pending_section_upserts(&storage, &mut pending_section_upserts)?;

    {
        let _write_guard = storage_write_lock();
        storage
            .upsert_novel(
                &novel_id,
                title,
                author,
                &target.toc_url,
                &target.domain,
                &target.output_dir,
                toc_count,
                &chrono::Utc::now().to_rfc3339(),
            )
            .map_err(|e| e.to_string())?;
    }

    write_download_state_atomic(&state_path, &next_state)?;

    set_progress_with_failed(total, downloaded, skipped, failed, "完了");

    Ok(format!(
        "saved {} episodes (updated {}), skipped {} existing, failed {} into {}",
        downloaded,
        updated,
        skipped,
        failed,
        target.output_dir.display()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;
    use std::time::{SystemTime, UNIX_EPOCH};

    static CALLBACK_COUNT: AtomicUsize = AtomicUsize::new(0);
    static CALLBACK_DONE: AtomicUsize = AtomicUsize::new(0);

    extern "C" fn record_progress_callback(snapshot: *const c_char) {
        if snapshot.is_null() {
            return;
        }
        let snapshot = unsafe { CStr::from_ptr(snapshot) }.to_string_lossy();
        let parts = snapshot
            .strip_prefix("OK:")
            .unwrap_or_default()
            .splitn(6, ':')
            .collect::<Vec<_>>();
        CALLBACK_COUNT.fetch_add(1, Ordering::Relaxed);
        CALLBACK_DONE.store(
            parts
                .get(1)
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(0),
            Ordering::Relaxed,
        );
    }

    fn temp_dir(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("novel_core_ffi_{name}_{unique}"));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn progress_callback_receives_live_snapshots() {
        CALLBACK_COUNT.store(0, Ordering::Relaxed);
        CALLBACK_DONE.store(0, Ordering::Relaxed);

        novel_core_set_download_progress_callback(Some(record_progress_callback));
        set_progress_running(true);
        set_progress_with_failed(3, 1, 0, 0, "Chapter 1");
        novel_core_set_download_progress_callback(None);
        set_progress_running(false);
        set_progress(0, 0, 0, "");

        assert!(CALLBACK_COUNT.load(Ordering::Relaxed) >= 2);
        assert_eq!(CALLBACK_DONE.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn existing_section_without_state_is_skipped_and_signature_changes_refresh() {
        let root = temp_dir("skip_existing");
        let db_path = root.join("master.db");
        let storage = SectionStorage::open(&db_path).unwrap();
        let prev_state = LocalDownloadState::default();
        storage
            .upsert_novel(
                "example.com:/works/1",
                "Example",
                "Author",
                "https://example.com/works/1",
                "example.com",
                &root,
                1,
                "2026-05-28T00:00:00Z",
            )
            .unwrap();

        storage
            .upsert_section(
                "example.com:/works/1",
                "1",
                "Chapter 1",
                "chapter-1",
                None,
                "<p>body</p>",
                None,
                "sig-a",
                "2026-05-28T00:00:00Z",
            )
            .unwrap();

        assert!(
            !should_download_chapter(
                &storage,
                &prev_state,
                "example.com:/works/1::1",
                "example.com:/works/1",
                "1",
                "sig-a",
            )
            .unwrap()
        );
        assert!(
            should_download_chapter(
                &storage,
                &prev_state,
                "example.com:/works/1::1",
                "example.com:/works/1",
                "1",
                "sig-b",
            )
            .unwrap()
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn legacy_existing_section_without_signature_is_skipped_once() {
        let root = temp_dir("skip_legacy_existing");
        let db_path = root.join("sections.sqlite3");
        let storage = SectionStorage::open(&db_path).unwrap();
        let prev_state = LocalDownloadState::default();
        storage
            .upsert_novel(
                "example.com:/works/1",
                "Example",
                "Author",
                "https://example.com/works/1",
                "example.com",
                &root,
                1,
                "2026-05-28T00:00:00Z",
            )
            .unwrap();

        storage
            .upsert_section(
                "example.com:/works/1",
                "1",
                "Chapter 1",
                "chapter-1",
                None,
                "<p>body</p>",
                None,
                "",
                "2026-05-28T00:00:00Z",
            )
            .unwrap();

        assert!(
            !should_download_chapter(
                &storage,
                &prev_state,
                "example.com:/works/1::1",
                "example.com:/works/1",
                "1",
                "new-signature",
            )
            .unwrap()
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn body_downloaded_false_forces_download_even_with_matching_signature() {
        let root = temp_dir("state_false_with_signature");
        let db_path = root.join("sections.sqlite3");
        let storage = SectionStorage::open(&db_path).unwrap();
        storage
            .upsert_novel(
                "example.com:/works/1",
                "Example",
                "Author",
                "https://example.com/works/1",
                "example.com",
                &root,
                1,
                "2026-05-28T00:00:00Z",
            )
            .unwrap();
        storage
            .upsert_section_placeholder(
                "example.com:/works/1",
                "1",
                "Chapter 1",
                "chapter-1",
                "2026-05-28T00:00:00Z",
            )
            .unwrap();
        let shard_path = storage.shard_path_for_chapter("example.com:/works/1", "1");
        drop(storage);
        let conn = rusqlite::Connection::open(&shard_path).unwrap();
        conn.execute(
            "UPDATE sections SET source_signature = ?1, body_downloaded = 0, body_xhtml_zstd = ?2 WHERE novel_id = ?3 AND chapter_index = ?4",
            rusqlite::params![
                "sig-a",
                crate::storage::compress_zstd("<p>stale body must not be used as state</p>").unwrap(),
                "example.com:/works/1",
                "1"
            ],
        )
        .unwrap();
        drop(conn);

        let storage = SectionStorage::open(&db_path).unwrap();
        let mut prev_state = LocalDownloadState::default();
        prev_state
            .chapter_signatures
            .insert("example.com:/works/1::1".to_string(), "sig-a".to_string());

        assert_eq!(
            storage
                .section_download_state("example.com:/works/1", "1")
                .unwrap(),
            Some(("sig-a".to_string(), false))
        );
        assert!(
            should_download_chapter(
                &storage,
                &prev_state,
                "example.com:/works/1::1",
                "example.com:/works/1",
                "1",
                "sig-a",
            )
            .unwrap()
        );

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn previous_state_signature_downloads_when_database_body_is_missing() {
        let root = temp_dir("skip_state");
        let db_path = root.join("sections.sqlite3");
        let storage = SectionStorage::open(&db_path).unwrap();
        let mut prev_state = LocalDownloadState::default();
        prev_state
            .chapter_signatures
            .insert("example.com:/works/1::1".to_string(), "sig-a".to_string());

        assert!(
            should_download_chapter(
                &storage,
                &prev_state,
                "example.com:/works/1::1",
                "example.com:/works/1",
                "1",
                "sig-a",
            )
            .unwrap()
        );

        std::fs::remove_dir_all(root).unwrap();
    }
}

// ── remaining C exports ────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_search_novels(query: *const c_char, limit: u32) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let query = cstr_to_string(query)?;
        let response =
            crate::search::search_webnovels(&query, limit as usize).map_err(|e| e.to_string())?;
        serde_json::to_string(&response).map_err(|e| e.to_string())
    })();
    match result {
        Ok(v) => into_c_string(format!("OK:{v}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_supported_search_sites() -> *mut c_char {
    match serde_json::to_string(&crate::search::supported_webnovels_sites()) {
        Ok(v) => into_c_string(format!("OK:{v}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_list_downloaded_novels(root_dir: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let root_dir = PathBuf::from(cstr_to_string(root_dir)?);
        let novels = discover_downloaded_novels(&root_dir).map_err(|e| e.to_string())?;
        serde_json::to_string(&novels).map_err(|e| e.to_string())
    })();
    match result {
        Ok(v) => into_c_string(format!("OK:{v}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[derive(Serialize)]
struct RefreshDownloadedTocsResult {
    refreshed: usize,
    failed: usize,
    skipped: usize,
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_refresh_downloaded_tocs(root_dir: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let root_dir = PathBuf::from(cstr_to_string(root_dir)?);
        let novels = discover_downloaded_novels(&root_dir).map_err(|e| e.to_string())?;
        let pipeline = DownloadPipeline::new(DEFAULT_BROWSER_UA).map_err(|e| e.to_string())?;
        let mut refreshed = 0usize;
        let mut failed = 0usize;
        let mut skipped = 0usize;

        for novel in novels {
            if novel.toc_url.is_empty() || novel.output_dir.is_empty() {
                skipped += 1;
                continue;
            }
            let target = DownloadTarget {
                domain: novel.domain,
                toc_url: novel.toc_url,
                output_dir: PathBuf::from(novel.output_dir),
            };
            match fetch_toc_and_metadata(&pipeline, &target) {
                Ok((toc, title, author)) if !toc.is_empty() => {
                    ensure_dirs(&target)?;
                    let sqlite_path = library_database_path(&target.output_dir);
                    let mut storage =
                        SectionStorage::open(&sqlite_path).map_err(|e| e.to_string())?;
                    let novel_id = novel_id_from_toc_url(&target.toc_url);
                    {
                        let _write_guard = storage_write_lock();
                        upsert_toc_placeholders(
                            &mut storage,
                            &target,
                            &novel_id,
                            &title,
                            &author,
                            &toc,
                        )?;
                    }
                    refreshed += 1;
                }
                _ => failed += 1,
            }
        }

        serde_json::to_string(&RefreshDownloadedTocsResult {
            refreshed,
            failed,
            skipped,
        })
        .map_err(|e| e.to_string())
    })();
    match result {
        Ok(v) => into_c_string(format!("OK:{v}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_set_extra_cookie_for_domain(
    domain: *const c_char,
    cookie: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let domain = cstr_to_string(domain)?;
        let cookie = cstr_to_string(cookie)?;
        set_extra_cookie_for_domain(&domain, &cookie);
        Ok(format!("cookie set for {domain}"))
    })();
    match result {
        Ok(m) => into_c_string(format!("OK:{m}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_set_browser_fetch_command(command: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let command = cstr_to_string(command)?;
        set_browser_fetch_command(&command);
        Ok("browser fetch command updated".to_string())
    })();
    match result {
        Ok(m) => into_c_string(format!("OK:{m}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_cancel_download() -> *mut c_char {
    CANCEL_REQUESTED.store(true, Ordering::Relaxed);
    into_c_string("OK:cancel_requested".to_string())
}

fn extract_domain(url: &str) -> Result<String, String> {
    let u = url::Url::parse(url).map_err(|e| e.to_string())?;
    let host = u
        .host_str()
        .unwrap_or("ncode.syosetu.com")
        .to_ascii_lowercase();
    let normalized = match host.as_str() {
        "www.kakuyomu.jp" => "kakuyomu.jp".to_string(),
        "www.novelup.plus" => "novelup.plus".to_string(),
        _ => host,
    };
    Ok(normalized)
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_set_root_dir(root_dir: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let root = cstr_to_string(root_dir)?;
        fs::create_dir_all(&root).map_err(|e| e.to_string())?;
        unsafe { env::set_var("NOVEL_CORE_ROOT_DIR", &root) };
        Ok(format!("root_dir set to {root}"))
    })();
    match result {
        Ok(m) => into_c_string(format!("OK:{m}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_set_script_dir(script_dir: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let script = cstr_to_string(script_dir)?;
        let presets = PathBuf::from(&script).join("presets");
        if !presets.exists() {
            return Err(format!("script_dir missing presets: {}", presets.display()));
        }
        unsafe { env::set_var("NOVEL_CORE_SCRIPT_DIR", &script) };
        Ok(format!("script_dir set to {script}"))
    })();
    match result {
        Ok(m) => into_c_string(format!("OK:{m}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

fn ensure_nokogiri_engine_for_custom_domain(domain: &str) -> anyhow::Result<()> {
    let mut cfg = ConfigManager::load_global_config()?;
    cfg.domain_engines
        .insert(domain.to_string(), "nokogiri".to_string());
    ConfigManager::save_global_config(&cfg)
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_set_domain_engine(
    domain: *const c_char,
    engine: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let domain = cstr_to_string(domain)?;
        let engine = cstr_to_string(engine)?;
        let mut cfg = ConfigManager::load_global_config().map_err(|e| e.to_string())?;
        cfg.domain_engines.insert(domain.clone(), engine.clone());
        ConfigManager::save_global_config(&cfg).map_err(|e| e.to_string())?;
        Ok(format!("mapped {domain} -> {engine}"))
    })();
    match result {
        Ok(m) => into_c_string(format!("OK:{m}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_set_domain_cookie(
    domain: *const c_char,
    cookie: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let domain = cstr_to_string(domain)?;
        let cookie = cstr_to_string(cookie)?;
        set_extra_cookie_for_domain(&domain, &cookie);
        Ok(format!("cookie set for {domain}"))
    })();
    match result {
        Ok(m) => into_c_string(format!("OK:{m}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_save_user_parser_yaml(
    domain: *const c_char,
    yaml: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let domain = cstr_to_string(domain)?;
        let yaml = cstr_to_string(yaml)?;
        let value: Value = serde_yaml::from_str(&yaml).map_err(|e| e.to_string())?;
        let path =
            ConfigManager::save_user_parser_preset(&domain, &value).map_err(|e| e.to_string())?;
        ensure_nokogiri_engine_for_custom_domain(&domain).map_err(|e| e.to_string())?;
        clear_access_caches();
        Ok(format!(
            "saved {} and mapped {domain} -> nokogiri",
            path.display()
        ))
    })();
    match result {
        Ok(m) => into_c_string(format!("OK:{m}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_save_user_webnovel_yaml(
    domain: *const c_char,
    yaml: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let domain = cstr_to_string(domain)?;
        let yaml = cstr_to_string(yaml)?;
        let value: Value = serde_yaml::from_str(&yaml).map_err(|e| e.to_string())?;
        let path =
            ConfigManager::save_user_site_preset(&domain, &value).map_err(|e| e.to_string())?;
        ensure_nokogiri_engine_for_custom_domain(&domain).map_err(|e| e.to_string())?;
        clear_access_caches();
        Ok(format!(
            "saved {} and mapped {domain} -> nokogiri",
            path.display()
        ))
    })();
    match result {
        Ok(m) => into_c_string(format!("OK:{m}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[derive(Serialize)]
struct NovelMetadata {
    title: String,
    author: String,
    episode_count: usize,
    folder_name: String,
    latest_episode_title: Option<String>,
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_fetch_novel_metadata(url: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let url = cstr_to_string(url)?;
        let domain = extract_domain(&url)?;
        let target = DownloadTarget {
            domain,
            toc_url: url,
            output_dir: PathBuf::new(),
        };
        let pipeline = DownloadPipeline::new(DEFAULT_BROWSER_UA).map_err(|e| e.to_string())?;
        let toc = pipeline
            .fetch_toc_with_metadata(&target)
            .map_err(|e| e.to_string())?;
        let chapters = toc.chapters;
        let title = if toc.title.is_empty() {
            "unknown".to_string()
        } else {
            toc.title
        };
        let author = if toc.author.is_empty() {
            "unknown".to_string()
        } else {
            toc.author
        };
        let folder_name = create_subdirectory_name(&title);
        let meta = NovelMetadata {
            title,
            author,
            episode_count: chapters.len(),
            folder_name,
            latest_episode_title: chapters.last().map(|c| c.subtitle.clone()),
        };
        serde_json::to_string(&meta).map_err(|e| e.to_string())
    })();
    match result {
        Ok(v) => into_c_string(format!("OK:{v}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_fetch_novel_metadata_from_html(
    url: *const c_char,
    toc_html: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let url = cstr_to_string(url)?;
        let toc_html = cstr_to_string(toc_html)?;
        let domain = extract_domain(&url)?;
        let parser = build_parser(&domain);
        let toc = parser.parse_toc(&toc_html).map_err(|e| e.to_string())?;
        let target = DownloadTarget {
            domain,
            toc_url: url,
            output_dir: PathBuf::new(),
        };
        let pipeline = DownloadPipeline::new(DEFAULT_BROWSER_UA).map_err(|e| e.to_string())?;
        let (chapters, fetched_title, fetched_author) =
            fetch_toc_from_html_or_network(&pipeline, &target, &toc_html, toc.chapters.clone())?;
        let title = if fetched_title.is_empty() {
            toc.title
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| "unknown".to_string())
        } else {
            fetched_title
        };
        let author = if fetched_author.is_empty() {
            toc.author
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| "unknown".to_string())
        } else {
            fetched_author
        };
        let folder_name = create_subdirectory_name(&title);
        let meta = NovelMetadata {
            title,
            author,
            episode_count: chapters.len(),
            folder_name,
            latest_episode_title: chapters.last().map(|c| c.subtitle.clone()),
        };
        serde_json::to_string(&meta).map_err(|e| e.to_string())
    })();
    match result {
        Ok(v) => into_c_string(format!("OK:{v}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}

#[derive(Serialize)]
struct SiteTestResult {
    title: String,
    author: String,
    episode_count: usize,
    first_episode_title: Option<String>,
}

#[unsafe(no_mangle)]
pub extern "C" fn novel_core_test_site_definition(
    url: *const c_char,
    yaml: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let url = cstr_to_string(url)?;
        let yaml = cstr_to_string(yaml)?;
        let domain = extract_domain(&url)?;
        let value: Value = serde_yaml::from_str(&yaml).map_err(|e| e.to_string())?;

        // We use NokogiriCompatParser as it's the target for all YAML-based definitions
        let parser = NokogiriCompatParser::with_preset(domain.clone(), value);

        let pipeline = DownloadPipeline::new(DEFAULT_BROWSER_UA).map_err(|e| e.to_string())?;
        let _target = DownloadTarget {
            domain: domain.clone(),
            toc_url: url.clone(),
            output_dir: std::path::PathBuf::new(),
        };
        // Use fetch_toc_from_initial_html as a base if we wanted to be simple,
        // but actually Downloader is accessible via pipeline
        // Actually, let's just use downloader.fetch directly if we can, or just fetch_toc
        let toc_html = pipeline.downloader().fetch(&url).map_err(|e| e.to_string())?;

        let parsed_toc = parser.parse_toc(&toc_html).map_err(|e| e.to_string())?;

        let res = SiteTestResult {
            title: parsed_toc.title.unwrap_or_else(|| "N/A".to_string()),
            author: parsed_toc.author.unwrap_or_else(|| "N/A".to_string()),
            episode_count: parsed_toc.chapters.len(),
            first_episode_title: parsed_toc.chapters.first().map(|c| c.subtitle.clone()),
        };

        serde_json::to_string(&res).map_err(|e| e.to_string())
    })();
    match result {
        Ok(v) => into_c_string(format!("OK:{v}")),
        Err(e) => into_c_string(format!("ERR:{e}")),
    }
}
