// nc_download.h — unified download / toc / library operations.
#pragma once

#include "nc_common.h"
#include "nc_value.h"

namespace nc {

struct DownloadOptions {
    std::string url;
    std::string output_dir;
    size_t episodes = 0;          // 0 = all
    std::string from_index;
    std::string mode = "bulk";    // bulk | reader
    std::string toc_html;         // optional pre-fetched
    std::string chapters_json;    // optional browser captured chapters
    static DownloadOptions from_json(const Value& v);
};

Value op_download(const DownloadOptions& opts);
Value op_fetch_toc(const DownloadOptions& opts);
Value op_novel_info(const std::string& url);
Value op_test_site(const std::string& url, const std::string& yaml);

Value op_library_list(const std::string& root_dir);
Value op_library_novel(const std::string& root_dir, const std::string& novel_id);
Value op_library_refresh(const std::string& root_dir);
Value op_section_get(const std::string& root_dir, const std::string& novel_id,
                     const std::string& chapter_index);
Value op_export_txt_zip(const Value& options);

// progress state (shared with C API)
struct Progress {
    long long total = 0, done = 0, skipped = 0, failed = 0;
    bool running = false;
    std::string current;
    Value to_json() const;
};
Progress progress_snapshot();
void progress_set_callback(void (*fn)(const char* json, void* userdata), void* userdata);
void progress_notify();
void cancel_request();
bool cancel_requested();
void reset_cancel();

} // namespace nc
