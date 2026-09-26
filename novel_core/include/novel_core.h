/*
 * novel_core — web novel downloader / library core (C ABI).
 *
 * Single public header.  Every function returning `char*` produces a heap
 * allocated UTF-8 JSON envelope:
 *   success : {"ok":true, "result": ...}
 *   failure : {"ok":false, "error": "..."}
 * Free the return value with novel_core_string_free().
 *
 * Site support is data driven: extraction rules live in YAML presets
 * (presets/parsers/<domain>.yaml).  Adding a new site never requires C/C++.
 */
#ifndef NOVEL_CORE_H
#define NOVEL_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── memory / strings ─────────────────────────────────────────────────── */
void* novel_core_alloc(size_t size);            /* malloc wrapper for transports */
void  novel_core_free(void* ptr);
void  novel_core_string_free(char* ptr);

/* ── HTTP transport (pluggable) ───────────────────────────────────────── */
typedef struct nc_http_response {
    int    status;        /* HTTP status, 0 = transport failure */
    char*  body;          /* heap bytes (NUL terminated is guaranteed) */
    size_t body_len;
    char*  final_url;     /* optional, heap */
    char*  set_cookies;   /* optional, newline separated "name=value; domain=..; path=/" heap */
} nc_http_response;

/* Return 0 on success (response filled, memory owned by core afterwards),
 * non-zero on network error.  header keys/values are NUL terminated. */
typedef int (*nc_http_transport_fn)(const char* url,
                                    const char* const* header_keys,
                                    const char* const* header_values,
                                    size_t header_count,
                                    int timeout_secs,
                                    void* userdata,
                                    nc_http_response* out);

void novel_core_set_http_transport(nc_http_transport_fn fn, void* userdata);

/* ── progress / cancellation ──────────────────────────────────────────── */
typedef void (*novel_core_progress_fn)(const char* json, void* userdata);
void  novel_core_set_progress_callback(novel_core_progress_fn fn, void* userdata);
char* novel_core_progress(void);   /* {"ok":true,"result":{"total":..,"done":..,...}} */
void  novel_core_cancel(void);

/* ── downloads ────────────────────────────────────────────────────────── */
/*
 * options_json:
 * {
 *   "url":         "<toc url>",          (required)
 *   "output_dir":  "<novel dir>",        (required)
 *   "episodes":    0,                    (0 = all / from_index..end)
 *   "from_index":  "",                   (start at chapter index)
 *   "mode":        "bulk" | "reader",    (flush policy)
 *   "toc_html":    "",                   (optional pre-fetched toc html)
 *   "chapters_json": ""                  (optional browser captured chapters)
 * }
 * result: {"saved":n,"updated":n,"skipped":n,"failed":n,"episodes":n,"output_dir":"..."}
 */
char* novel_core_download(const char* options_json);

/*
 * options_json: {"url": "...", "output_dir": "..."} — fetch TOC (all pages),
 * store placeholders + novel metadata, return
 * {"novel_id","title","author","episodes","chapters":[...]}.
 */
char* novel_core_fetch_toc(const char* options_json);

/* result: {"novel_id","title","author","story","episodes","toc_url"} */
char* novel_core_novel_info(const char* url);

/* Dry-run a site YAML against `url` (fetch + parse with the injected preset).
 * result: {"title","author","episodes","first_chapters":[...],"body_sample":"..."} */
char* novel_core_test_site(const char* url, const char* yaml);

/* ── library ──────────────────────────────────────────────────────────── */
/* result: {"novels":[{novel_id,title,author,toc_url,domain,episode_count,
 *                     downloaded_count,updated_at,output_dir}, ...]} */
char* novel_core_library_list(const char* root_dir);

/* result: {"novel":{...},"chapters":[{index,subtitle,href,chapter,downloaded,
 *          body_downloaded,updated_at,sort_key}, ...],"downloaded_count":n} */
char* novel_core_library_novel(const char* root_dir, const char* novel_id);

/* Re-fetch TOCs of all library novels; result: {"refreshed":n,"failed":n} */
char* novel_core_library_refresh(const char* root_dir);

/* One chapter for the reader.
 * result: {index,subtitle,intro_xhtml,body_xhtml,post_xhtml,downloaded,source_url} */
char* novel_core_novel_delete(const char* root_dir, const char* novel_id);
char* novel_core_section_version_get(const char* root_dir, const char* novel_id,
                                     const char* chapter_index, int32_t offset);
char* novel_core_section_get(const char* root_dir, const char* novel_id,
                             const char* chapter_index);

/* Text export. options: {"root_dir","novel_id","output_zip"?,"format":"aozora"|"text"}
 * result: {"zip_path":"...","files":n} */
char* novel_core_export_txt_zip(const char* options_json);

/* ── search (webnovels.jp meta search over preset defined sites) ──────── */
char* novel_core_search(const char* query, uint32_t limit);
char* novel_core_search_sites(void);   /* {"sites":[{key,label,domains:[..]}]} */

/* ── presets / configuration ──────────────────────────────────────────── */
char* novel_core_set_root_dir(const char* path);
char* novel_core_set_script_dir(const char* path);
void  novel_core_set_download_interval_ms(uint32_t ms);

/* Parser presets: YAML extraction rules per domain (user overlay on builtins). */
char* novel_core_save_parser_yaml(const char* domain, const char* yaml);
char* novel_core_load_parser_yaml(const char* domain);   /* effective merged YAML */
char* novel_core_list_parser_yamls(void);               /* {"presets":[{domain,source,...}]} */
char* novel_core_delete_parser_yaml(const char* domain); /* remove user overlay */

void  novel_core_set_domain_cookie(const char* domain, const char* cookie);
void  novel_core_set_browser_fetch_command(const char* command);

/* ── zstd helpers (section blobs) ─────────────────────────────────────── */
char* novel_core_decompress_zstd(const uint8_t* data, size_t len);
char* novel_core_decompress_zstd_dict(const uint8_t* data, size_t len,
                                      const uint8_t* dict, size_t dict_len);

#ifdef __cplusplus
}
#endif
#endif /* NOVEL_CORE_H */
