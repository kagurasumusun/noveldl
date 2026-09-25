use crate::ffi;
use std::ffi::{CStr, CString};
use std::fs;
use std::io;
use std::os::raw::c_char;

fn cstring_arg(name: &str, value: String) -> Result<CString, String> {
    CString::new(value).map_err(|_| format!("ERR:{name} contains an embedded NUL byte"))
}

fn call_ffi(f: impl FnOnce() -> *mut c_char) -> String {
    let p = f();
    if p.is_null() {
        return "ERR:null response".to_string();
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().to_string();
    ffi::novel_core_string_free(p);
    s
}

fn decompress_zstd_internal(input_path: &str, output_path: &str) -> io::Result<()> {
    let input_file = fs::File::open(input_path)?;
    let output_file = fs::File::create(output_path)?;
    zstd::stream::copy_decode(input_file, output_file)?;
    Ok(())
}

// ── uniffi-exported functions ──────────────────────────────────────────────

pub fn search_novels(query: String, limit: u32) -> String {
    let q = match cstring_arg("query", query) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_search_novels(q.as_ptr(), limit))
}

pub fn supported_search_sites() -> String {
    call_ffi(|| ffi::novel_core_supported_search_sites())
}

pub fn download_first_n(url: String, episodes: u32, output_dir: String) -> String {
    let u = match cstring_arg("url", url) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let o = match cstring_arg("output_dir", output_dir) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_download_first_n(u.as_ptr(), episodes, o.as_ptr()))
}

pub fn create_library_placeholder(url: String, output_dir: String) -> String {
    let u = match cstring_arg("url", url) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let o = match cstring_arg("output_dir", output_dir) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_create_library_placeholder(u.as_ptr(), o.as_ptr()))
}

pub fn fetch_toc_only(url: String, output_dir: String) -> String {
    let u = match cstring_arg("url", url) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let o = match cstring_arg("output_dir", output_dir) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_fetch_toc_only(u.as_ptr(), o.as_ptr()))
}

pub fn download_from_chapter(url: String, chapter_index: String, output_dir: String) -> String {
    let u = match cstring_arg("url", url) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let c = match cstring_arg("chapter_index", chapter_index) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let o = match cstring_arg("output_dir", output_dir) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_download_from_chapter(u.as_ptr(), c.as_ptr(), o.as_ptr()))
}

pub fn download_cached_from_chapter(
    url: String,
    chapter_index: String,
    output_dir: String,
) -> String {
    let u = match cstring_arg("url", url) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let c = match cstring_arg("chapter_index", chapter_index) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let o = match cstring_arg("output_dir", output_dir) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_download_cached_from_chapter(u.as_ptr(), c.as_ptr(), o.as_ptr()))
}

pub fn download_reader_cached_from_chapter(
    url: String,
    chapter_index: String,
    output_dir: String,
) -> String {
    let u = match cstring_arg("url", url) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let c = match cstring_arg("chapter_index", chapter_index) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let o = match cstring_arg("output_dir", output_dir) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| {
        ffi::novel_core_download_reader_cached_from_chapter(u.as_ptr(), c.as_ptr(), o.as_ptr())
    })
}

pub fn download_first_n_from_html(
    url: String,
    toc_html: String,
    chapters_json: String,
    episodes: u32,
    output_dir: String,
) -> String {
    let u = match cstring_arg("url", url) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let t = match cstring_arg("toc_html", toc_html) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let c = match cstring_arg("chapters_json", chapters_json) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let o = match cstring_arg("output_dir", output_dir) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| {
        ffi::novel_core_download_first_n_from_html(
            u.as_ptr(),
            t.as_ptr(),
            c.as_ptr(),
            episodes,
            o.as_ptr(),
        )
    })
}

pub fn cancel_download() -> String {
    call_ffi(|| ffi::novel_core_cancel_download())
}

pub fn set_extra_cookie_for_domain(domain: String, cookie: String) -> String {
    let d = match cstring_arg("domain", domain) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let c = match cstring_arg("cookie", cookie) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_set_extra_cookie_for_domain(d.as_ptr(), c.as_ptr()))
}

pub fn set_browser_fetch_command(command: String) -> String {
    let c = match cstring_arg("command", command) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_set_browser_fetch_command(c.as_ptr()))
}

pub fn set_domain_engine(domain: String, engine: String) -> String {
    let d = match cstring_arg("domain", domain) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let e = match cstring_arg("engine", engine) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_set_domain_engine(d.as_ptr(), e.as_ptr()))
}

pub fn save_user_parser_yaml(domain: String, yaml: String) -> String {
    let d = match cstring_arg("domain", domain) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let y = match cstring_arg("yaml", yaml) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_save_user_parser_yaml(d.as_ptr(), y.as_ptr()))
}

pub fn save_user_webnovel_yaml(domain: String, yaml: String) -> String {
    let d = match cstring_arg("domain", domain) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let y = match cstring_arg("yaml", yaml) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_save_user_webnovel_yaml(d.as_ptr(), y.as_ptr()))
}

pub fn set_root_dir(root_dir: String) -> String {
    let r = match cstring_arg("root_dir", root_dir) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_set_root_dir(r.as_ptr()))
}

pub fn decompress_zstd_file(input_path: String, output_path: String) -> String {
    match decompress_zstd_internal(&input_path, &output_path) {
        Ok(_) => format!("OK:Decompressed {} to {}", input_path, output_path),
        Err(e) => format!("ERR:{}", e),
    }
}

/// Decompress a zstd-compressed byte blob in memory, returning the UTF-8 string.
/// Returns "OK:<content>" or "ERR:<reason>".
pub fn decompress_zstd_data(data: Vec<u8>) -> String {
    if data.is_empty() {
        return "ERR:empty data".to_string();
    }
    let p = ffi::novel_core_decompress_zstd_blob(data.as_ptr(), data.len());
    if p.is_null() {
        return "ERR:null response".to_string();
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().to_string();
    ffi::novel_core_string_free(p);
    s
}

/// Returns live download progress as "OK:<total>:<done>:<skipped>:<running>:<current>".

/// Decompress a zstd-compressed UTF-8 byte blob with a trained dictionary.
/// Returns "OK:<content>" or "ERR:<reason>".
pub fn decompress_zstd_data_with_dictionary(data: Vec<u8>, dictionary: Vec<u8>) -> String {
    if data.is_empty() {
        return "ERR:empty data".to_string();
    }
    match crate::storage::decompress_zstd_with_dictionary(&data, &dictionary) {
        Ok(text) => format!("OK:{text}"),
        Err(error) => format!("ERR:{error}"),
    }
}

pub fn get_download_progress() -> String {
    call_ffi(|| ffi::novel_core_get_download_progress())
}

/// Returns downloaded novels under `root_dir` as `OK:[...]`.
/// The lookup scans only existing `sections.sqlite3` files and never creates an empty database.
pub fn list_downloaded_novels(root_dir: String) -> String {
    let r = match cstring_arg("root_dir", root_dir) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_list_downloaded_novels(r.as_ptr()))
}

/// Refreshes TOC placeholders for already-downloaded novels. Intended for app startup/background refresh.
pub fn refresh_downloaded_tocs(root_dir: String) -> String {
    let r = match cstring_arg("root_dir", root_dir) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_refresh_downloaded_tocs(r.as_ptr()))
}

#[cfg(test)]
mod tests {
    use super::cstring_arg;

    #[test]
    fn cstring_arg_rejects_embedded_nul_without_panicking() {
        let err = cstring_arg("url", "https://example.com/\0bad".to_string())
            .expect_err("embedded NUL should be reported as an ERR string");
        assert_eq!(err, "ERR:url contains an embedded NUL byte");
    }
}

pub fn test_site_definition(url: String, yaml: String) -> String {
    let u = match cstring_arg("url", url) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let y = match cstring_arg("yaml", yaml) {
        Ok(v) => v,
        Err(e) => return e,
    };
    call_ffi(|| ffi::novel_core_test_site_definition(u.as_ptr(), y.as_ptr()))
}
