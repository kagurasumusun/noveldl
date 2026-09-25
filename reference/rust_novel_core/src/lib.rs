pub mod api;
pub mod config_manager;
pub mod conversion_html;
pub mod downloader;
pub mod extensions;
pub mod ffi;
pub mod file_lock;
pub mod helper;
pub mod novel_info;
pub mod parser_selector;
pub mod parsers;
pub mod process_manager;
pub mod rate_limiter;
pub mod runtime;
pub mod sanitize;
pub mod search;
pub mod section_cache;
pub mod storage;
pub mod uniffi_api;
pub mod xhtml;
pub mod yaml_loader;

pub use runtime::Runtime;
pub use uniffi_api::{
    cancel_download, create_library_placeholder, decompress_zstd_data,
    decompress_zstd_data_with_dictionary, decompress_zstd_file, download_cached_from_chapter,
    download_first_n, download_first_n_from_html, download_from_chapter,
    download_reader_cached_from_chapter, fetch_toc_only, get_download_progress,
    list_downloaded_novels, refresh_downloaded_tocs, save_user_parser_yaml,
    save_user_webnovel_yaml, search_novels, set_browser_fetch_command, set_domain_engine,
    test_site_definition,
    set_extra_cookie_for_domain, set_root_dir, supported_search_sites,
};
uniffi::include_scaffolding!("novel_core");

#[cfg(test)]
mod migration_parity_tests;
