// nc_download.cpp — unified operations replacing ffi.rs + pipeline.rs +
// section_downloader.rs + class_methods.rs + file_operations.rs +
// database_updater.rs + toc_processor.rs + state.rs + rate_limiter.rs.
//
// One download pipeline serves every entry point (bulk, from-index, reader
// window, browser-captured chapters) via DownloadOptions.
#include "nc_download.h"
#include "nc_config.h"
#include "nc_html.h"
#include "nc_http.h"
#include "nc_rules.h"
#include "nc_storage.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <set>
#include <thread>

namespace fs = std::filesystem;

namespace nc {

std::string apply_fetch_url_template(const Value& preset, const std::string& url,
                                     bool chapter_side = false) {
    const Value* meta = preset.get("metadata");
    std::string tmpl;
    if (meta) {
        // chapter_fetch_url_template is chapter-only; fetch_url_template is for
        // the metadata/TOC fetch (chapter hrefs are already final URLs there).
        tmpl = chapter_side ? meta->get_str("chapter_fetch_url_template", "")
                            : meta->get_str("fetch_url_template", "");
    }
    if (tmpl.empty()) return url;
    // {id} = last path segment, {url} = the original URL
    std::string path = url_path(url);
    std::string id = path;
    auto slash = id.rfind('/');
    if (slash != std::string::npos) id = id.substr(slash + 1);
    std::string out = replace_all(tmpl, "{id}", id);
    out = replace_all(out, "{url}", url);
    return out;
}

// ── progress / cancel ─────────────────────────────────────────────────────
namespace {
std::mutex g_prog_mutex;
Progress g_progress;
std::atomic<bool> g_cancel{false};
void (*g_prog_fn)(const char*, void*) = nullptr;
void* g_prog_userdata = nullptr;
long long g_interval_ms = -1;
} // namespace

Value Progress::to_json() const {
    Value v = Value::map_();
    v.set("total", Value::integer(total));
    v.set("done", Value::integer(done));
    v.set("skipped", Value::integer(skipped));
    v.set("failed", Value::integer(failed));
    v.set("running", Value::boolean(running));
    v.set("current", Value::string(current));
    return v;
}

Progress progress_snapshot() {
    std::lock_guard<std::mutex> lock(g_prog_mutex);
    return g_progress;
}

void progress_set_callback(void (*fn)(const char*, void*), void* userdata) {
    std::lock_guard<std::mutex> lock(g_prog_mutex);
    g_prog_fn = fn;
    g_prog_userdata = userdata;
    if (fn) {
        std::string json = json_dump(g_progress.to_json());
        fn(json.c_str(), userdata);
    }
}

void progress_notify() {
    void (*fn)(const char*, void*) = nullptr;
    void* userdata = nullptr;
    std::string json;
    {
        std::lock_guard<std::mutex> lock(g_prog_mutex);
        fn = g_prog_fn;
        userdata = g_prog_userdata;
        json = json_dump(g_progress.to_json());
    }
    if (fn) fn(json.c_str(), userdata);
}

void cancel_request() { g_cancel = true; }
bool cancel_requested() { return g_cancel.load(); }
void reset_cancel() { g_cancel = false; }

namespace {
void set_progress(long long total, long long done, long long skipped, long long failed,
                  const std::string& current, bool running) {
    {
        std::lock_guard<std::mutex> lock(g_prog_mutex);
        g_progress.total = total;
        g_progress.done = done;
        g_progress.skipped = skipped;
        g_progress.failed = failed;
        g_progress.current = current;
        g_progress.running = running;
    }
    progress_notify();
}

long long download_interval_ms() {
    if (g_interval_ms >= 0) return g_interval_ms;
    const char* env = std::getenv("NOVELDL_DOWNLOAD_INTERVAL_MS");
    return env ? std::atoll(env) : 5000;
}

struct RateLimiter {
    long long interval_ms;
    bool first = true;
    std::chrono::steady_clock::time_point last =
        std::chrono::steady_clock::now() - std::chrono::seconds(20);
    explicit RateLimiter(long long ms) : interval_ms(ms) {}
    bool wait() {
        if (cancel_requested()) return false;
        if (!first) {
            auto deadline = std::chrono::steady_clock::now() +
                            std::chrono::milliseconds(interval_ms);
            while (std::chrono::steady_clock::now() < deadline) {
                if (cancel_requested()) return false;
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
            }
        }
        first = false;
        last = std::chrono::steady_clock::now();
        return !cancel_requested();
    }
};

std::string placeholder_title(const std::string& toc_url) {
    UrlParts p;
    if (url_parse(toc_url, p)) {
        std::string path = p.path;
        while (!path.empty() && path.front() == '/') path.erase(path.begin());
        while (!path.empty() && path.back() == '/') path.pop_back();
        return path.empty() ? p.host : p.host + " / " + path;
    }
    return toc_url;
}

void ensure_dirs(const std::string& output_dir) {
    std::error_code ec;
    fs::create_directories(output_dir, ec);
    fs::create_directories(output_dir + "/cache", ec);
    fs::create_directories(output_dir + "/raw", ec);
}

// ── TOC page queue (pipeline.rs) ──────────────────────────────────────────
struct TocPageQueue {
    std::deque<std::pair<std::string, std::optional<std::string>>> queue;
    std::set<std::string> scheduled;

    void schedule(const std::string& base, const std::string& href) {
        std::string abs = url_absolute(base, href);
        if (scheduled.insert(abs).second) queue.emplace_back(abs, std::nullopt);
    }
};

struct TocResult {
    std::vector<Chapter> chapters;
    std::string title;
    std::string author;
};

TocResult fetch_toc_pages(HttpClient& http, const std::string& toc_url, const std::string& domain,
                          const Value& preset, const std::string& initial_html,
                          const std::function<void(const TocResult&)>& on_page) {
    RulesParser parser(preset);
    TocPageQueue pages;
    pages.scheduled.insert(toc_url);
    if (!initial_html.empty())
        pages.queue.emplace_back(toc_url, initial_html);
    else
        pages.queue.emplace_back(toc_url, std::nullopt);

    TocResult result;
    AccessSettings access = AccessSettings::from_preset(preset);
    while (!pages.queue.empty()) {
        if (cancel_requested()) throw Error("cancelled");
        auto [url, html] = pages.queue.front();
        pages.queue.pop_front();
        std::string body = html ? *html
                              : http.fetch(url == toc_url ? apply_fetch_url_template(preset, url) : url,
                                           access, toc_url);
        ParsedToc toc = parser.parse_toc(body);
        if (result.title.empty() && toc.title) result.title = *toc.title;
        if (result.author.empty() && toc.author) result.author = *toc.author;
        for (auto& ch : toc.chapters) result.chapters.push_back(ch);
        if (on_page) on_page(result);
        for (auto& href : parser.parse_toc_page_hrefs(body)) pages.schedule(url, href);
    }
    return result;
}

std::optional<std::pair<std::string, std::string>> split_pair(const std::string& s, char sep) {
    size_t at = s.find(sep);
    if (at == std::string::npos) return std::nullopt;
    return std::make_pair(s.substr(0, at), s.substr(at + 1));
}

// ── ZIP writer (store only) for txt export ────────────────────────────────
uint32_t crc32_simple(const std::string& data) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            table[i] = c;
        }
        init = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (unsigned char b : data) c = table[(c ^ b) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

void append_u32(std::string& out, uint32_t v) {
    out.push_back((char)(v & 0xFF));
    out.push_back((char)((v >> 8) & 0xFF));
    out.push_back((char)((v >> 16) & 0xFF));
    out.push_back((char)((v >> 24) & 0xFF));
}
void append_u16(std::string& out, uint16_t v) {
    out.push_back((char)(v & 0xFF));
    out.push_back((char)((v >> 8) & 0xFF));
}

std::string build_store_zip(const std::vector<std::pair<std::string, std::string>>& files) {
    std::string zip;
    std::vector<uint32_t> offsets;
    for (auto& [name, content] : files) {
        offsets.push_back((uint32_t)zip.size());
        uint32_t crc = crc32_simple(content);
        append_u32(zip, 0x04034b50);
        append_u16(zip, 20); // version
        append_u16(zip, 0x0800); // utf-8 flag
        append_u16(zip, 0); // store
        append_u16(zip, 0); // time
        append_u16(zip, 0); // date
        append_u32(zip, crc);
        append_u32(zip, (uint32_t)content.size());
        append_u32(zip, (uint32_t)content.size());
        append_u16(zip, (uint16_t)name.size());
        append_u16(zip, 0);
        zip += name;
        zip += content;
    }
    uint32_t cd_start = (uint32_t)zip.size();
    for (size_t k = 0; k < files.size(); ++k) {
        auto& [name, content] = files[k];
        uint32_t crc = crc32_simple(content);
        append_u32(zip, 0x02014b50);
        append_u16(zip, 20);
        append_u16(zip, 20);
        append_u16(zip, 0x0800);
        append_u16(zip, 0);
        append_u16(zip, 0);
        append_u16(zip, 0);
        append_u32(zip, crc);
        append_u32(zip, (uint32_t)content.size());
        append_u32(zip, (uint32_t)content.size());
        append_u16(zip, (uint16_t)name.size());
        append_u16(zip, 0);
        append_u16(zip, 0);
        append_u16(zip, 0);
        append_u16(zip, 0);
        append_u32(zip, 0);
        append_u32(zip, offsets[k]);
        zip += name;
    }
    uint32_t cd_size = (uint32_t)zip.size() - cd_start;
    append_u32(zip, 0x06054b50);
    append_u16(zip, 0);
    append_u16(zip, 0);
    append_u16(zip, (uint16_t)files.size());
    append_u16(zip, (uint16_t)files.size());
    append_u32(zip, cd_size);
    append_u32(zip, cd_start);
    append_u16(zip, 0);
    return zip;
}



Value fetch_metadata_via_rules(const std::string& url, const Value& preset, HttpClient& http) {
    AccessSettings access = AccessSettings::from_preset(preset);
    std::string html = http.fetch(apply_fetch_url_template(preset, url), access, std::nullopt);
    RulesParser parser(preset);
    ParsedToc toc = parser.parse_toc(html);
    Value v = Value::map_();
    v.set("title", Value::string(toc.title.value_or("")));
    v.set("author", Value::string(toc.author.value_or("")));
    v.set("story", Value::string(toc.story.value_or("")));
    v.set("episodes", Value::integer((long long)toc.chapters.size()));
    v.set("toc_url", Value::string(url));
    return v;
}

} // namespace

DownloadOptions DownloadOptions::from_json(const Value& v) {
    DownloadOptions o;
    o.url = v.get_str("url");
    o.output_dir = v.get_str("output_dir");
    o.episodes = v.get_int("episodes", 0) < 0 ? 0 : (size_t)v.get_int("episodes", 0);
    o.from_index = v.get_str("from_index");
    o.mode = v.get_str("mode", "bulk");
    o.toc_html = v.get_str("toc_html");
    o.chapters_json = v.get_str("chapters_json");
    return o;
}

Value op_download(const DownloadOptions& opts) {
    if (opts.url.empty()) throw Error("url is required");
    if (opts.output_dir.empty()) throw Error("output_dir is required");
    reset_cancel();
    set_progress(0, 0, 0, 0, "目次を取得中", true);

    std::string domain = url_host(opts.url);
    if (domain.empty()) throw Error("invalid url: " + opts.url);
    Value preset = config::load_effective_preset(domain);
    AccessSettings access = AccessSettings::from_preset(preset);
    HttpClient http;
    std::string novel_id = novel_id_from_toc_url(opts.url);

    ensure_dirs(opts.output_dir);
    SectionStorage storage(library_database_path(opts.output_dir));

    // resolve chapter list
    std::vector<Chapter> toc;
    std::string title, author;
    Value browser_chapters = Value::array();
    if (!opts.chapters_json.empty()) {
        try {
            browser_chapters = json_parse(opts.chapters_json);
        } catch (...) {
            throw Error("chapters_json is invalid JSON");
        }
    }

    if (browser_chapters.is_array() && browser_chapters.size() > 0) {
        for (auto& c : browser_chapters.arr) {
            Chapter ch;
            ch.index = c.get_str("index", std::to_string(toc.size() + 1));
            ch.href = c.get_str("href");
            ch.subtitle = c.get_str("subtitle");
            ch.chapter = c.get_str_opt("chapter");
            ch.subupdate = c.get_str_opt("subupdate");
            toc.push_back(ch);
        }
    }
    if (toc.empty()) {
        TocResult tr;
        if (!opts.toc_html.empty()) {
            RulesParser parser(preset);
            // walk pages starting from provided html
            tr = fetch_toc_pages(http, opts.url, domain, preset, opts.toc_html, nullptr);
            ParsedToc first = parser.parse_toc(opts.toc_html);
            if (tr.title.empty() && first.title) tr.title = *first.title;
            if (tr.author.empty() && first.author) tr.author = *first.author;
        } else {
            // prefer cached toc for from_index downloads
            auto cached = storage.cached_toc_chapters(novel_id);
            if (!cached.empty() && !opts.from_index.empty()) {
                for (auto& c : cached) {
                    Chapter ch;
                    ch.index = c.index;
                    ch.href = c.href;
                    ch.subtitle = c.subtitle;
                    toc.push_back(ch);
                }
                auto meta = storage.novel_metadata(novel_id);
                if (meta) {
                    title = meta->first;
                    author = meta->second;
                }
                set_progress((long long)toc.size(), 0, (long long)toc.size(), 0,
                             "保存済み目次を使用", true);
            }
            if (toc.empty()) {
                tr = fetch_toc_pages(http, opts.url, domain, preset, "", nullptr);
            }
        }
        if (toc.empty()) {
            toc = tr.chapters;
            title = tr.title;
            author = tr.author;
        }
    }

    // slice from from_index / episodes
    size_t start = 0;
    if (!opts.from_index.empty()) {
        for (size_t k = 0; k < toc.size(); ++k) {
            if (toc[k].index == opts.from_index) {
                start = k;
                break;
            }
        }
    }
    std::vector<Chapter> targets(toc.begin() + (long)start, toc.end());
    if (opts.episodes > 0 && targets.size() > opts.episodes) targets.resize(opts.episodes);

    // register placeholders + fetch prior states
    {
        std::vector<StoredTocChapter> stored;
        for (auto& ch : toc) stored.push_back({ch.index, ch.href, ch.subtitle});
        storage.upsert_novel(novel_id, title, author, opts.url, domain, opts.output_dir,
                             (long long)toc.size(), now_rfc3339());
        storage.upsert_section_placeholders(novel_id, stored, now_rfc3339());
    }
    auto states = storage.section_download_states(novel_id);

    const bool reader_mode = opts.mode == "reader";
    const size_t flush_batch = 5;
    const size_t reader_window = 15;

    RulesParser parser(preset);
    std::vector<SectionUpsert> pending;
    long long skipped = 0, failed = 0, downloaded = 0, updated = 0;
    long long total = (long long)targets.size();
    set_progress(total, 0, 0, 0, "", true);

    auto flush = [&]() {
        if (pending.empty()) return;
        std::vector<SectionUpsert> batch;
        batch.swap(pending);
        storage.upsert_sections(batch);
    };

    RateLimiter limiter(download_interval_ms());
    for (size_t k = 0; k < targets.size(); ++k) {
        if (cancel_requested()) {
            flush();
            throw Error("cancelled");
        }
        Chapter& ch = targets[k];
        set_progress(total, downloaded, skipped, failed, ch.subtitle, true);
        std::string sig = ch.signature();
        auto state_it = states.find(ch.index);
        bool needs = true;
        if (state_it != states.end()) {
            auto& [stored_sig, body_done] = state_it->second;
            if (body_done) {
                if (!stored_sig.empty())
                    needs = stored_sig != sig;
                else
                    needs = false;
            }
        }
        if (!needs) {
            ++skipped;
            set_progress(total, downloaded, skipped, failed, ch.subtitle, true);
            continue;
        }
        if (!limiter.wait()) {
            flush();
            throw Error("cancelled");
        }
        std::string body_html;
        try {
            std::string join_base = opts.url;
        {
            std::string path = url_path(join_base);
            auto sl = path.rfind('/');
            std::string last = sl == std::string::npos ? path : path.substr(sl + 1);
            if (!join_base.empty() && join_base.back() != '/' &&
                !last.empty() && last.find('.') == std::string::npos)
                join_base += '/';
        }
        std::string abs = url_absolute(join_base, ch.href);
            body_html = http.fetch(apply_fetch_url_template(preset, abs, true), access, opts.url);
        } catch (const std::exception& e) {
            if (std::getenv("NC_DEBUG")) std::fprintf(stderr, "[dl-fail] fetch %s: %s\n", ch.href.c_str(), e.what());
            ++failed;
            set_progress(total, downloaded, skipped, failed,
                         "取得失敗: " + ch.subtitle, true);
            continue;
        }
        ParsedSection sec;
        try {
            sec = parser.parse_section(body_html);
        } catch (const std::exception& e) {
            if (std::getenv("NC_DEBUG")) std::fprintf(stderr, "[dl-fail] parse %s: %s\n", ch.href.c_str(), e.what());
            ++failed;
            set_progress(total, downloaded, skipped, failed,
                         "解析失敗: " + ch.subtitle, true);
            continue;
        }
        SectionUpsert up;
        up.novel_id = novel_id;
        up.chapter_index = ch.index;
        up.subtitle = ch.subtitle;
        up.source_url = ch.href;
        up.intro_xhtml =
            sec.introduction ? std::optional<std::string>(xhtml_normalize_fragment(*sec.introduction))
                             : std::nullopt;
        up.body_xhtml = xhtml_normalize_fragment(sec.body);
        up.post_xhtml =
            sec.postscript ? std::optional<std::string>(xhtml_normalize_fragment(*sec.postscript))
                           : std::nullopt;
        up.source_signature = sig;
        up.updated_at = now_rfc3339();
        pending.push_back(std::move(up));

        bool should_flush =
            reader_mode ? (k < reader_window || pending.size() >= flush_batch)
                        : pending.size() >= flush_batch;
        if (should_flush) flush();

        ++downloaded;
        ++updated;
        set_progress(total, downloaded, skipped, failed, ch.subtitle, true);
    }
    flush();
    storage.upsert_novel(novel_id, title, author, opts.url, domain, opts.output_dir,
                         (long long)toc.size(), now_rfc3339());
    set_progress(total, downloaded, skipped, failed, "完了", false);

    Value out = Value::map_();
    out.set("saved", Value::integer(downloaded));
    out.set("updated", Value::integer(updated));
    out.set("skipped", Value::integer(skipped));
    out.set("failed", Value::integer(failed));
    out.set("episodes", Value::integer(total));
    out.set("novel_id", Value::string(novel_id));
    out.set("output_dir", Value::string(opts.output_dir));
    return out;
}

Value op_fetch_toc(const DownloadOptions& opts) {
    if (opts.url.empty()) throw Error("url is required");
    if (opts.output_dir.empty()) throw Error("output_dir is required");
    reset_cancel();
    set_progress(0, 0, 0, 0, "目次を取得中", true);

    std::string domain = url_host(opts.url);
    Value preset = config::load_effective_preset(domain);
    HttpClient http;
    std::string novel_id = novel_id_from_toc_url(opts.url);
    ensure_dirs(opts.output_dir);
    SectionStorage storage(library_database_path(opts.output_dir));

    std::string title, author;
    Value chapters = Value::array();
    TocResult tr = fetch_toc_pages(
        http, opts.url, domain, preset, opts.toc_html,
        [&](const TocResult& partial) {
            std::vector<StoredTocChapter> stored;
            Value arr = Value::array();
            for (auto& ch : partial.chapters) {
                stored.push_back({ch.index, ch.href, ch.subtitle});
                Value c = Value::map_();
                c.set("index", Value::string(ch.index));
                c.set("href", Value::string(ch.href));
                c.set("subtitle", Value::string(ch.subtitle));
                arr.push(std::move(c));
            }
            storage.upsert_novel(novel_id, partial.title, partial.author, opts.url, domain,
                                 opts.output_dir, (long long)partial.chapters.size(),
                                 now_rfc3339());
            storage.upsert_section_placeholders(novel_id, stored, now_rfc3339());
            set_progress((long long)partial.chapters.size(), 0,
                         (long long)partial.chapters.size(), 0, "目次を保存中", true);
        });
    title = tr.title;
    author = tr.author;
    for (auto& ch : tr.chapters) {
        Value c = Value::map_();
        c.set("index", Value::string(ch.index));
        c.set("href", Value::string(ch.href));
        c.set("subtitle", Value::string(ch.subtitle));
        if (ch.chapter) c.set("chapter", Value::string(*ch.chapter));
        if (ch.subupdate) c.set("subupdate", Value::string(*ch.subupdate));
        chapters.push(std::move(c));
    }
    set_progress((long long)tr.chapters.size(), 0, (long long)tr.chapters.size(), 0,
                 "目次取得完了", false);

    Value out = Value::map_();
    out.set("novel_id", Value::string(novel_id));
    out.set("title", Value::string(title));
    out.set("author", Value::string(author));
    out.set("episodes", Value::integer((long long)tr.chapters.size()));
    out.set("chapters", std::move(chapters));
    return out;
}

Value op_novel_info(const std::string& url) {
    std::string domain = url_host(url);
    Value preset = config::load_effective_preset(domain);
    HttpClient http;
    return fetch_metadata_via_rules(url, preset, http);
}

Value op_test_site(const std::string& url, const std::string& yaml) {
    Value preset = yaml_parse(yaml);
    preset = config::resolve_extends(std::move(preset));
    preset = RulesParser::normalize_legacy(std::move(preset));
    std::string domain = url_host(url);
    HttpClient http;
    AccessSettings access = AccessSettings::from_preset(preset);
    std::string html = http.fetch(apply_fetch_url_template(preset, url), access, std::nullopt);
    RulesParser parser(preset);
    ParsedToc toc = parser.parse_toc(html);
    Value out = Value::map_();
    out.set("title", Value::string(toc.title.value_or("")));
    out.set("author", Value::string(toc.author.value_or("")));
    out.set("episodes", Value::integer((long long)toc.chapters.size()));
    Value first = Value::array();
    for (size_t k = 0; k < toc.chapters.size() && k < 5; ++k) {
        Value c = Value::map_();
        c.set("index", Value::string(toc.chapters[k].index));
        c.set("href", Value::string(toc.chapters[k].href));
        c.set("subtitle", Value::string(toc.chapters[k].subtitle));
        first.push(std::move(c));
    }
    out.set("first_chapters", std::move(first));
    if (!toc.chapters.empty()) {
        try {
            std::string abs = url_absolute(url, toc.chapters[0].href);
            std::string body_html = http.fetch(abs, access, url);
            ParsedSection sec = parser.parse_section(body_html);
            out.set("body_sample", Value::string(utf8_substr(sec.body, 0, 400)));
        } catch (const std::exception& e) {
            out.set("body_error", Value::string(e.what()));
        }
    }
    return out;
}

Value op_library_list(const std::string& root_dir) {
    auto items = discover_downloaded_novels(root_dir);
    Value arr = Value::array();
    for (auto& item : items) {
        Value v = Value::map_();
        v.set("novel_id", Value::string(item.novel_id));
        v.set("title", Value::string(item.title));
        v.set("author", Value::string(item.author));
        v.set("toc_url", Value::string(item.toc_url));
        v.set("domain", Value::string(item.domain));
        v.set("episode_count", Value::integer(item.episode_count));
        v.set("updated_at", Value::string(item.updated_at));
        v.set("output_dir", Value::string(item.output_dir));
        v.set("storage_path", Value::string(item.storage_path));
        // downloaded count from shards
        long long downloaded = 0;
        try {
            SectionStorage storage(item.storage_path);
            auto states = storage.section_download_states(item.novel_id);
            for (auto& kv : states)
                if (kv.second.second) ++downloaded;
        } catch (...) {
        }
        v.set("downloaded_count", Value::integer(downloaded));
        arr.push(std::move(v));
    }
    Value out = Value::map_();
    out.set("novels", std::move(arr));
    return out;
}

Value op_library_novel(const std::string& root_dir, const std::string& novel_id) {
    std::string master = root_dir + "/master.db";
    std::error_code ec;
    if (!fs::exists(master, ec)) master = root_dir + "/sections.sqlite3";
    if (!fs::exists(master, ec)) throw Error("library not found at " + root_dir);
    SectionStorage storage(master);
    auto meta = storage.novel_metadata(novel_id);
    if (!meta) throw Error("novel not found: " + novel_id);

    Value novel = Value::map_();
    novel.set("novel_id", Value::string(novel_id));
    novel.set("title", Value::string(meta->first));
    novel.set("author", Value::string(meta->second));
    novel.set("domain", Value::string(storage.novel_domain(novel_id)));
    novel.set("output_dir", Value::string(storage.novel_output_dir(novel_id)));

    auto toc = storage.cached_toc_chapters(novel_id);
    auto states = storage.section_download_states(novel_id);
    Value chapters = Value::array();
    long long downloaded = 0;
    for (auto& ch : toc) {
        Value c = Value::map_();
        c.set("index", Value::string(ch.index));
        c.set("href", Value::string(ch.href));
        c.set("subtitle", Value::string(ch.subtitle));
        c.set("sort_key", Value::real(section_sort_key(ch.index)));
        auto it = states.find(ch.index);
        bool body_done = it != states.end() && it->second.second;
        c.set("body_downloaded", Value::boolean(body_done));
        if (body_done) ++downloaded;
        chapters.push(std::move(c));
    }
    novel.set("episode_count", Value::integer((long long)toc.size()));
    Value out = Value::map_();
    out.set("novel", std::move(novel));
    out.set("chapters", std::move(chapters));
    out.set("downloaded_count", Value::integer(downloaded));
    return out;
}

Value op_library_refresh(const std::string& root_dir) {
    Value listed = op_library_list(root_dir);
    long long refreshed = 0, failed = 0;
    reset_cancel();
    for (auto& item : listed.get("novels")->arr) {
        if (cancel_requested()) break;
        try {
            DownloadOptions opts;
            opts.url = item.get_str("toc_url");
            opts.output_dir = item.get_str("output_dir");
            if (opts.url.empty()) {
                ++failed;
                continue;
            }
            op_fetch_toc(opts);
            ++refreshed;
        } catch (...) {
            ++failed;
        }
    }
    Value out = Value::map_();
    out.set("refreshed", Value::integer(refreshed));
    out.set("failed", Value::integer(failed));
    return out;
}

Value op_section_get(const std::string& root_dir, const std::string& novel_id,
                     const std::string& chapter_index) {
    std::string master = root_dir + "/master.db";
    std::error_code ec;
    if (!fs::exists(master, ec)) master = root_dir + "/sections.sqlite3";
    if (!fs::exists(master, ec)) throw Error("library not found at " + root_dir);
    SectionStorage storage(master);
    auto sec = storage.get_section(novel_id, chapter_index);
    if (!sec) throw Error("section not found: " + novel_id + " / " + chapter_index);
    Value v = Value::map_();
    v.set("index", Value::string(sec->index));
    v.set("subtitle", Value::string(sec->subtitle));
    v.set("intro_xhtml", Value::string(sec->intro_xhtml));
    v.set("body_xhtml", Value::string(sec->body_xhtml));
    v.set("post_xhtml", Value::string(sec->post_xhtml));
    v.set("source_url", Value::string(sec->source_url));
    v.set("body_downloaded", Value::boolean(sec->body_downloaded));
    v.set("updated_at", Value::string(sec->updated_at));
    return v;
}

Value op_export_txt_zip(const Value& options) {
    std::string root_dir = options.get_str("root_dir", config::root_dir());
    std::string novel_id = options.get_str("novel_id");
    if (novel_id.empty()) throw Error("novel_id is required");
    bool aozora = options.get_str("format", "aozora") == "aozora";

    std::string master = root_dir + "/master.db";
    std::error_code ec;
    if (!fs::exists(master, ec)) throw Error("library not found at " + root_dir);
    SectionStorage storage(master);
    auto meta = storage.novel_metadata(novel_id);
    if (!meta) throw Error("novel not found: " + novel_id);
    auto toc = storage.cached_toc_chapters(novel_id);
    if (toc.empty()) throw Error("no chapters to export");

    std::string title = replace_filename_special_chars(
        truncate_path_component(meta->first.empty() ? novel_id : meta->first, 120));
    std::string author = replace_filename_special_chars(meta->second);
    std::vector<std::pair<std::string, std::string>> files;
    std::string combined;
    if (!author.empty()) combined += "作者: " + author + "\n\n";
    combined += meta->first + "\n\n----\n\n";

    long long missing = 0;
    long long count = 0;
    for (auto& ch : toc) {
        auto sec = storage.get_section(novel_id, ch.index);
        if (!sec || !sec->body_downloaded || sec->body_xhtml.empty()) {
            ++missing;
            continue;
        }
        std::string text;
        if (!sec->intro_xhtml.empty())
            text += html_to_aozora(sec->intro_xhtml, false, false) + "\n\n";
        text += html_to_aozora(sec->body_xhtml, false, false);
        if (!sec->post_xhtml.empty())
            text += "\n\n" + html_to_aozora(sec->post_xhtml, false, false);
        if (!aozora) text = sanitize_fragment_text(text);

        std::string num = ch.index;
        while (num.size() < 4) num = "0" + num;
        std::string name = replace_filename_special_chars(
            truncate_path_component(num + "_" + ch.subtitle, 120));
        files.emplace_back(title + "/" + name + ".txt",
                           sec->subtitle + "\n\n" + text + "\n");
        combined += "【" + sec->subtitle + "】\n\n" + text + "\n\n";
        ++count;
    }
    if (files.empty()) throw Error("missing downloaded bodies: " + std::to_string(missing));
    files.emplace_back(title + "/" + title + " 全一話.txt", combined);

    std::string out_zip = options.get_str("output_zip");
    if (out_zip.empty()) {
        out_zip = storage.novel_output_dir(novel_id) + "/" + title + ".zip";
    }
    std::string zip_bytes = build_store_zip(files);
    {
        fs::path p(out_zip);
        fs::create_directories(p.parent_path(), ec);
        std::ofstream out(out_zip, std::ios::binary | std::ios::trunc);
        if (!out) throw Error("cannot write " + out_zip);
        out.write(zip_bytes.data(), (std::streamsize)zip_bytes.size());
    }
    Value out = Value::map_();
    out.set("zip_path", Value::string(out_zip));
    out.set("files", Value::integer((long long)files.size()));
    if (missing > 0) out.set("missing_bodies", Value::integer(missing));
    return out;
}

} // namespace nc
