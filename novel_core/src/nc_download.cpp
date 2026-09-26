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

#include <algorithm>
#include <atomic>
#include <regex>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
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

    // ?p=N / ?page=N の N(無いページは 0=先頭)。
    static long long page_key(const std::string& url) {
        size_t num_start = std::string::npos;
        const char* keys[] = {"?page=", "&page=", "?p=", "&p="};
        for (auto k : keys) {
            size_t at = url.rfind(k);
            if (at != std::string::npos) {
                num_start = at + std::strlen(k);
                break;
            }
        }
        if (num_start == std::string::npos) return 0;
        size_t num_end = num_start;
        while (num_end < url.size() && url[num_end] >= '0' && url[num_end] <= '9') ++num_end;
        if (num_end == num_start) return 0;
        try {
            return std::stoll(url.substr(num_start, num_end - num_start));
        } catch (...) {
            return 0;
        }
    }

    // 取得順をページ番号昇順に固定する。ページ内採番の振り直し順が
    // 実行ごとに変わると更新のたびに index と話の中身がズレるため。
    void sort_queue() {
        std::stable_sort(queue.begin(), queue.end(), [](const auto& a, const auto& b) {
            return page_key(a.first) < page_key(b.first);
        });
    }
};


namespace {
std::string image_ext_for(const std::string& url) {
    std::string path = url;
    auto q = path.find_first_of("?#");
    if (q != std::string::npos) path = path.substr(0, q);
    auto dot = path.rfind('.');
    if (dot != std::string::npos) {
        std::string ext = path.substr(dot + 1);
        for (auto& c : ext) c = (char)::tolower((unsigned char)c);
        if (ext == "png" || ext == "jpg" || ext == "jpeg" || ext == "gif" || ext == "webp")
            return ext == "jpeg" ? "jpg" : ext;
    }
    return "jpg";
}

void rewrite_src(std::string& fragment, const std::string& src, const std::string& local) {
    for (char q : {'"', '\''}) {
        std::string old_s = std::string(1, q) + src + std::string(1, q);
        std::string new_s = std::string(1, q) + local + std::string(1, q);
        size_t pos = 0;
        while ((pos = fragment.find(old_s, pos)) != std::string::npos) {
            fragment.replace(pos, old_s.size(), new_s);
            pos += new_s.size();
        }
    }
}

/// 本文フラグメント内の画像を取得してローカル保存し、src を保存先パスに書き換える。
void fetch_section_images(HttpClient& http, const AccessSettings& access,
                          const RulesParser& parser, const std::string& join_base,
                          const std::string& img_dir, const std::string& chapter_index,
                          std::vector<std::string*>& fragments) {
    std::vector<std::string> srcs;
    {
        // 前書きと後書きに同じ挿絵が貼られることがあるため、絶対URL単位で重複除去
        // (除去しないと同一画像が 2 ファイルに保存され、無駄な通信と容量になる)。
        std::set<std::string> seen_srcs;
        for (auto* frag : fragments) {
            if (!frag || frag->empty()) continue;
            for (auto& src : parser.parse_image_srcs(*frag)) {
                if (seen_srcs.insert(url_absolute(join_base, src)).second) srcs.push_back(src);
            }
        }
    }
    if (srcs.empty()) return;
    std::error_code ec;
    fs::create_directories(img_dir, ec);
    size_t n = 0;
    for (auto& src : srcs) {
        if (++n > 30) break;  // 1 話ぶんの上限
        try {
            std::string abs = url_absolute(join_base, src);
            std::string data = http.fetch(abs, access, join_base);
            char name[64];
            std::snprintf(name, sizeof name, "%s_%02zu.%s", chapter_index.c_str(), n,
                          image_ext_for(src).c_str());
            std::string local = img_dir + "/" + name;
            {
                std::ofstream f(local, std::ios::binary);
                if (!f) continue;
                f.write(data.data(), (std::streamsize)data.size());
            }
            for (auto* frag : fragments) {
                if (frag) rewrite_src(*frag, src, local);
            }
        } catch (const std::exception&) {
            // 画像の失敗で本文取得は失敗させない
        }
    }
}
}  // namespace


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
    // 表紙URL: og:image から汎用抽出する(サイト別ルールがあれば将来ここに追加)。
    std::string cover;
    {
        static const std::regex og_re(
            R"(property=["']og:image["'][^>]*content=["']([^"']+)["']|content=["']([^"']+)["'][^>]*property=["']og:image["'])",
            std::regex::icase);
        std::smatch m;
        if (std::regex_search(html, m, og_re)) {
            cover = m[1].matched ? m[1].str() : m[2].str();
        }
    }
    Value v = Value::map_();
    v.set("title", Value::string(toc.title.value_or("")));
    v.set("author", Value::string(toc.author.value_or("")));
    v.set("story", Value::string(toc.story.value_or("")));
    v.set("cover", Value::string(cover));
    v.set("status", Value::string(toc.status.value_or("")));
    v.set("next_update", Value::string(toc.next_update.value_or("")));
    v.set("comment_count", Value::string(toc.comment_count.value_or("")));
    v.set("updated", Value::string(toc.updated.value_or("")));

    // API 形式のメタ情報(なろう小説API 等)。HTML から取れなかった空欄だけを補う。
    if (const Value* api = preset.get("metadata_api")) {
        std::string tpl = api->get_str("url", "");
        if (!tpl.empty()) {
            static const std::regex ncode_re(R"(/(n[0-9a-z]{4,12})(/|$))", std::regex::icase);
            std::smatch nm;
            std::string ncode;
            std::string path_only = url.substr(0, url.find('?'));
            if (std::regex_search(path_only, nm, ncode_re)) ncode = nm[1].str();
            if (!ncode.empty()) {
                std::string api_url = replace_all(tpl, "{ncode}", ncode);
                try {
                    std::string js = http.fetch(api_url, access, std::nullopt);
                    Value j = json_parse(js);
                    // なろう API は先頭に {allcount:N} を付けてくる → 実データの要素を探す
                    const Value* obj = nullptr;
                    // 実データの要素(=いずれかのキーを持つ要素)を選ぶ。
                    // なろう API は先頭に {allcount:N} を付けてくるため除外される。
                    std::vector<std::string> probe;
                    std::vector<std::pair<std::string, std::string>> fills;  // (target, json path) 空欄のみ
                    if (const Value* fields = api->get("fields")) {
                        for (auto& kv : fields->map) {
                            std::string path = kv.second.is_str() ? kv.second.s : "";
                            if (path.empty()) continue;
                            probe.push_back(path);
                            if (v.get_str(kv.first, "").empty()) fills.emplace_back(kv.first, path);
                        }
                    }
                    std::string status_field = api->get_str("status_field", "");
                    if (!status_field.empty()) probe.push_back(status_field);
                    if (j.is_array()) {
                        for (auto& e : j.arr) {
                            for (auto& w : probe) {
                                if (!w.empty() && json_path_string(e, w)) { obj = &e; break; }
                            }
                            if (obj) break;
                        }
                        if (!obj && j.arr.size() > 1) obj = &j.arr[1];
                    } else {
                        obj = &j;
                    }
                    if (obj) {
                        for (auto& f : fills) {
                            auto got = json_path_string(*obj, f.second);
                            if (got && !trim(*got).empty()) v.set(f.first, Value::string(*got));
                        }
                        if (!status_field.empty() && v.get_str("status", "").empty()) {
                            auto got = json_path_string(*obj, status_field);
                            if (got) {
                                // なろう API: isstop 1=完結済 0=連載中
                                v.set("status", Value::string(trim(*got) == "1" ? "完結済" : "連載中"));
                            }
                        }
                    }
                } catch (...) {
                }
            }
        }
    }

    // API 由来の general_lastup 等も「YYYY/MM/DD」にそろえる。
    {
        std::string u = v.get_str("updated", "");
        static const std::regex date_re2(R"(\d{4}[/-]\d{1,2}[/-]\d{1,2})");
        std::smatch m2;
        if (!u.empty() && std::regex_search(u, m2, date_re2)) {
            std::string y = m2[0].str();
            for (auto& c : y) if (c == '-') c = '/';
            v.set("updated", Value::string(y));
        }
    }
    v.set("episodes", Value::integer((long long)toc.chapters.size()));
    v.set("toc_url", Value::string(url));
    return v;
}

} // namespace
// ── API / 埋め込みJSON 型サイトの共通エンジン(YAML 宣言だけで動く) ────────
//
// toc_api:                # 目次(話のリスト)を JSON から組み立てる
//   from: script          # script(本文書に埋め込み) | url(API を取得)
//   script_marker: "__NEXT_DATA__"      # from: script 時の <script id="...">
//   url: "https://api.example.com/works/{ncode}/episodes"   # from: url 時
//   data_path: "props.pageProps.__APOLLO_STATE__"  # JSON 内の位置(空ならルート)
//   key_prefix: "Episode:"              # data が map のときのキー前方フィルタ
//   fields:                             # 値の取り出し(JSONパス)
//     subtitle: "title"
//     id: "id"
//     chapter: "chapter_title"          # 任意
//     subupdate: "publishedAt"          # 任意
//   href_template: "episodes/{id}"      # 任意({id} を置換)
//   sort_by: "publishedAt"              # 任意。文字列比較で安定ソート
//
// section_api:            # 本文を JSON API から取得する
//   url: "https://api.example.com/episodes/{id}"   # {id} {href} {url} {ncode} が使える
//   data_path: ""         # 任意
//   fields:
//     body: "content"
//     introduction: "preface"           # 任意
//     postscript: "afterword"           # 任意
//
// サイト固有の処理は C++ に書かない。宣言をサイト別 YAML に足すだけ。
struct ApiTocSpec {
    bool from_script = false;
    std::string script_marker;
    std::string url_tpl;
    std::string data_path;
    std::string key_prefix;
    std::vector<std::pair<std::string, std::string>> fields;  // target -> json path
    std::string href_tpl;
    std::string sort_by;
};

static ApiTocSpec parse_api_toc_spec(const Value& tapi) {
    ApiTocSpec sp;
    sp.from_script = tapi.get_str("from", "url") == "script";
    sp.script_marker = tapi.get_str("script_marker", "__NEXT_DATA__");
    sp.url_tpl = tapi.get_str("url", "");
    sp.data_path = tapi.get_str("data_path", "");
    sp.key_prefix = tapi.get_str("key_prefix", "");
    sp.href_tpl = tapi.get_str("href_template", "");
    sp.sort_by = tapi.get_str("sort_by", "");
    if (const Value* f = tapi.get("fields")) {
        for (auto& kv : f->map) {
            if (kv.second.is_str() && !kv.second.s.empty()) {
                sp.fields.emplace_back(kv.first, kv.second.s);
            }
        }
    }
    return sp;
}

static size_t api_toc_from_json(const ApiTocSpec& sp, const Value& j,
                                std::vector<Chapter>& out) {
    const Value* data = sp.data_path.empty() ? &j : json_path(j, sp.data_path);
    if (!data) return 0;
    std::vector<const Value*> items;
    if (data->is_array()) {
        for (auto& e : data->arr) items.push_back(&e);
    } else if (data->is_map()) {
        for (auto& kv : data->map) {
            if (!sp.key_prefix.empty() &&
                kv.first.rfind(sp.key_prefix, 0) != 0) continue;
            items.push_back(&kv.second);
        }
    }
    struct Draft { Chapter ch; std::string sort_key; };
    std::vector<Draft> drafts;
    for (const Value* e : items) {
        std::string subtitle, id, chapter, subupdate;
        for (auto& f : sp.fields) {
            auto v = json_path_string(*e, f.second);
            if (!v) continue;
            if (f.first == "subtitle") subtitle = *v;
            else if (f.first == "id") id = *v;
            else if (f.first == "chapter") chapter = *v;
            else if (f.first == "subupdate") subupdate = *v;
        }
        if (subtitle.empty() && id.empty()) continue;
        Chapter ch;
        ch.subtitle = subtitle;
        ch.href = sp.href_tpl.empty() ? id : replace_all(sp.href_tpl, "{id}", id);
        if (!chapter.empty()) ch.chapter = chapter;
        if (!subupdate.empty()) ch.subupdate = subupdate;
        drafts.push_back({std::move(ch), sp.sort_by.empty() ? std::string()
                                                : json_path_string(*e, sp.sort_by).value_or("")});
    }
    if (!sp.sort_by.empty()) {
        std::stable_sort(drafts.begin(), drafts.end(),
                         [](const Draft& a, const Draft& b) { return a.sort_key < b.sort_key; });
    }
    for (size_t k = 0; k < drafts.size(); ++k) {
        if (drafts[k].ch.index.empty()) drafts[k].ch.index = std::to_string(k + 1);
        out.push_back(std::move(drafts[k].ch));
    }
    return drafts.size();
}

// 埋め込み JSON(<script id="__NEXT_DATA__">{...}</script> 等を HTML から抜く)。
// 正規表現は巨大 HTML でバックトラックが爆発するため、素直な文字列走査で行う。
static std::string embedded_json_from_html(const std::string& marker,
                                           const std::string& html) {
    auto lower_find = [](const std::string& hay, const std::string& needle,
                         size_t from) -> size_t {
        if (needle.empty() || hay.size() < needle.size()) return std::string::npos;
        for (size_t i = from; i + needle.size() <= hay.size(); ++i) {
            size_t j = 0;
            while (j < needle.size() &&
                   std::tolower((unsigned char)hay[i + j]) ==
                       std::tolower((unsigned char)needle[j]))
                ++j;
            if (j == needle.size()) return i;
        }
        return std::string::npos;
    };
    // 1) <script id="marker" ...> JSON </script>
    {
        const std::string pat = "id=\"" + marker + "\"";
        size_t p = lower_find(html, pat, 0);
        if (p == std::string::npos) {
            const std::string pat2 = "id=" + marker;  // 引用符なし
            p = lower_find(html, pat2, 0);
        }
        if (p != std::string::npos) {
            size_t gt = html.find('>', p);
            size_t end = (gt == std::string::npos)
                             ? std::string::npos
                             : lower_find(html, "</script", gt);
            if (gt != std::string::npos && end != std::string::npos) {
                std::string body = trim(html.substr(gt + 1, end - gt - 1));
                if (!body.empty()) return body;
            }
        }
    }
    // 2) marker = {...}; 形式(window.__INITIAL_STATE__ 等)。波括弧の対応で取る。
    {
        size_t p = lower_find(html, marker, 0);
        while (p != std::string::npos) {
            size_t brace = html.find('{', p + marker.size());
            // marker と { の間に '=' が必要(別の語の一部を掴まない)
            if (brace != std::string::npos) {
                std::string between = html.substr(p + marker.size(), brace - p - marker.size());
                if (between.find('=') != std::string::npos &&
                    between.find(';') == std::string::npos) {
                    int depth = 0;
                    bool in_str = false;
                    char quote = 0;
                    for (size_t i = brace; i < html.size(); ++i) {
                        char c = html[i];
                        if (in_str) {
                            if (c == '\\') {
                                ++i;
                            } else if (c == quote) {
                                in_str = false;
                            }
                            continue;
                        }
                        if (c == '"' || c == '\'') {
                            in_str = true;
                            quote = c;
                        } else if (c == '{') {
                            ++depth;
                        } else if (c == '}') {
                            if (--depth == 0) {
                                return html.substr(brace, i - brace + 1);
                            }
                        }
                    }
                }
            }
            p = lower_find(html, marker, p + marker.size());
        }
    }
    return "";
}

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
    std::set<std::string> seen_chapters;
    std::set<std::string> seen_indices;
    AccessSettings access = AccessSettings::from_preset(preset);
    // 目次URL由来の ncode(ページURLテンプレート {ncode} / toc_api url 用の共通解決値)。
    // note: toc_url_pattern が {ncode} を含まないサイト(estar /novels/{id} 等)では空。
    std::string ncode;
    {
        static const std::regex nre(R"(/(n[0-9a-z]{4,12})(/|$))", std::regex::icase);
        std::smatch nm;
        if (std::regex_search(toc_url, nm, nre)) ncode = nm[1].str();
    }
    int fetched_pages = 0;
    bool toc_api_done = false;
    while (!pages.queue.empty()) {
        pages.sort_queue();
        if (++fetched_pages > 400) break;  // 異常なページ連鎖の保険
        if (cancel_requested()) throw Error("cancelled");
        auto [url, html] = pages.queue.front();
        pages.queue.pop_front();
        std::string body = html ? *html
                              : http.fetch(url == toc_url ? apply_fetch_url_template(preset, url) : url,
                                           access, toc_url);
        ParsedToc toc = parser.parse_toc(body);
        if (result.title.empty() && toc.title) result.title = *toc.title;
        if (result.author.empty() && toc.author) result.author = *toc.author;
        // API/埋め込みJSON 型の目次(toc_api): HTML と併用できる(href で重複除去)。
        if (const Value* tapi = preset.get("toc_api")) {
            ApiTocSpec sp = parse_api_toc_spec(*tapi);
            std::string js;
            if (sp.from_script) {
                js = embedded_json_from_html(sp.script_marker, body);
            } else if (!toc_api_done && !sp.url_tpl.empty()) {
                try {
                    js = http.fetch(replace_all(sp.url_tpl, "{ncode}", ncode), access, toc_url);
                } catch (...) {
                }
                toc_api_done = true;
            }
            if (!js.empty()) {
                try {
                    Value j = json_parse(js);
                    std::vector<Chapter> more;
                    api_toc_from_json(sp, j, more);
                    for (auto& ch : more) {
                        if (!seen_chapters.insert(ch.href).second) continue;
                        if (!seen_indices.insert(ch.index).second) {
                            std::string fresh;
                            long long cand = (long long)result.chapters.size() + 1;
                            do { fresh = std::to_string(cand++); }
                            while (!seen_indices.insert(fresh).second);
                            ch.index = fresh;
                        }
                        result.chapters.push_back(ch);
                    }
                } catch (...) {
                    // API が失敗しても HTML 側の目次は生かす
                }
            }
        }
        for (auto& ch : toc.chapters) {
            if (!seen_chapters.insert(ch.href).second) continue;
            // なろう系など、ページ内での連番("1","2",...)しか取れないサイトでは
            // 2ページ目以降も毎回 1 から採番され直すため、そのまま使うと
            // sections テーブルの PRIMARY KEY(novel_id, chapter_index) が
            // 1ページ目の話数と衝突し、後から読んだページ(=最新ページ)の内容で
            // 前のページの話を上書きしてしまう(結果的に最後のページ分しか
            // 残らないように見える)。同じ index が既に使われていた場合のみ、
            // 通し番号(これまでに確定した話数+1)へ振り直して重複を避ける。
            if (!seen_indices.insert(ch.index).second) {
                std::string fresh;
                long long candidate = (long long)result.chapters.size() + 1;
                do {
                    fresh = std::to_string(candidate++);
                } while (!seen_indices.insert(fresh).second);
                ch.index = fresh;
            }
            result.chapters.push_back(ch);
        }
        if (on_page) on_page(result);
        for (auto& href : parser.parse_toc_page_hrefs(body)) {
            // Range/next_link の url_template に残る {ncode} はここで共通解決する
            // (collect_page_hrefs は {page} しか置換しない)。
            pages.schedule(url, ncode.empty() ? href : replace_all(href, "{ncode}", ncode));
        }
    }
    return result;
}

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

// なろう系は同じ ncode が複数ホストに分散(R-18 は novel18 専用など)。
// 取得に失敗したら族ホストを同じパスで順に試す。
std::vector<std::string> family_url_candidates(const std::string& url) {
    static const char* kFamily[] = {"ncode.syosetu.com", "novel18.syosetu.com",
                                    "noc.syosetu.com", "mid.syosetu.com",
                                    "mnlt.syosetu.com"};
    std::string host = lower(url_host(url));
    std::string path = url_path(url);
    bool in_family = false;
    for (auto h : kFamily)
        if (host == h) in_family = true;
    std::vector<std::string> out;
    if (!in_family || path.empty()) {
        out.push_back(url);
        return out;
    }
    out.push_back(url);
    for (auto h : kFamily) {
        std::string cand = std::string("https://") + h + path;
        if (cand != url) out.push_back(cand);
    }
    return out;
}

// 族フォールバック付きの目次取得(op_download 用・ページ解決は追跡しない)。
TocResult fetch_toc_pages_family(HttpClient& http, const std::string& url,
                                 const std::string& toc_html,
                                 std::string* resolved_url, Value* resolved_preset) {
    std::string first_error;
    for (auto& cand : family_url_candidates(url)) {
        try {
            Value p = config::load_effective_preset(url_host(cand));
            TocResult t = fetch_toc_pages(http, cand, url_host(cand), p, toc_html, nullptr);
            if (t.chapters.empty()) throw Error("目次が空でした");
            if (resolved_url) *resolved_url = cand;
            if (resolved_preset) *resolved_preset = p;
            return t;
        } catch (const std::exception& e) {
            if (first_error.empty()) first_error = e.what();
        }
    }
    throw Error(first_error.empty() ? "目次を取得できませんでした" : first_error);
}

Value op_download(const DownloadOptions& opts) {
    if (opts.url.empty()) throw Error("url is required");
    if (opts.output_dir.empty()) throw Error("output_dir is required");
    reset_cancel();
    set_progress(0, 0, 0, 0, "目次を取得中", true);

    std::string domain = url_host(opts.url);
    if (domain.empty()) throw Error("invalid url: " + opts.url);
    std::string toc_url_used = opts.url;
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
                Value resolved_preset;
                tr = fetch_toc_pages_family(http, opts.url, "", &toc_url_used, &resolved_preset);
                if (!resolved_preset.is_null()) {
                    preset = resolved_preset;
                    domain = url_host(toc_url_used);
                    novel_id = novel_id_from_toc_url(toc_url_used);
                    access = AccessSettings::from_preset(preset);
                }
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
        storage.upsert_novel(novel_id, title, author,
                             toc_url_used.empty() ? opts.url : toc_url_used, domain,
                             opts.output_dir,
                             (long long)toc.size(), now_rfc3339());
        storage.upsert_section_placeholders(novel_id, stored, now_rfc3339());
    }

    // 更新取得のたびに詳細メタ(あらすじ・状態・更新日・コメント)も最新化する。
    {
        try {
            Value meta = fetch_metadata_via_rules(
                toc_url_used.empty() ? opts.url : toc_url_used, preset, http);
            std::string story = meta.get_str("story", "");
            NovelMetaExtra mx;
            mx.status = meta.get_str("status", "");
            mx.next_update = meta.get_str("next_update", "");
            mx.comment_count = meta.get_str("comment_count", "");
            mx.updated = meta.get_str("updated", "");
            if (!story.empty()) storage.update_novel_description(novel_id, story);
            storage.update_novel_meta(novel_id, mx);
            // タイトル・作者も空でなければ最新化する(旧データの作者空欄を埋める)。
            storage.update_novel_title_author(novel_id,
                                              meta.get_str("title", ""),
                                              meta.get_str("author", ""));
        } catch (const std::exception&) {
        }
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
        bool was_done = state_it != states.end() && state_it->second.second;
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
        std::string join_base = toc_url_used.empty() ? opts.url : toc_url_used;
        {
            std::string path = url_path(join_base);
            auto sl = path.rfind('/');
            std::string last = sl == std::string::npos ? path : path.substr(sl + 1);
            if (!join_base.empty() && join_base.back() != '/' &&
                !last.empty() && last.find('.') == std::string::npos)
                join_base += '/';
        }
        std::string abs = url_absolute(join_base, ch.href);

        // API型サイト(section_api): 本文を JSON API から(YAML 宣言のみで動く)。
        ParsedSection sec;
        bool sec_from_api = false;
        if (const Value* sapi = preset.get("section_api")) {
            std::string tpl = sapi->get_str("url", "");
            if (!tpl.empty()) {
                try {
                    std::string id = ch.href;
                    {
                        while (!id.empty() && (id.back() == '/' || id.back() == '?')) id.pop_back();
                        auto q = id.find('?');
                        if (q != std::string::npos) id = id.substr(0, q);
                        auto sl2 = id.rfind('/');
                        id = sl2 == std::string::npos ? id : id.substr(sl2 + 1);
                    }
                    std::string ncode;
                    {
                        static const std::regex nre(R"(/(n[0-9a-z]{4,12})(/|$))", std::regex::icase);
                        std::smatch nm;
                        if (std::regex_search(join_base, nm, nre)) ncode = nm[1].str();
                    }
                    std::string api_url = replace_all(tpl, "{id}", id);
                    api_url = replace_all(api_url, "{href}", ch.href);
                    api_url = replace_all(api_url, "{url}", abs);
                    api_url = replace_all(api_url, "{ncode}", ncode);
                    std::string js = http.fetch(api_url, access, opts.url);
                    Value j = json_parse(js);
                    std::string dp = sapi->get_str("data_path", "");
                    const Value* obj = dp.empty() ? &j : json_path(j, dp);
                    if (obj) {
                        std::string body, intro, post;
                        if (const Value* f = sapi->get("fields")) {
                            body = json_path_string(*obj, f->get_str("body", "")).value_or("");
                            intro = json_path_string(*obj, f->get_str("introduction", "")).value_or("");
                            post = json_path_string(*obj, f->get_str("postscript", "")).value_or("");
                        }
                        if (!body.empty()) {
                            sec.body = body;
                            if (!intro.empty()) sec.introduction = intro;
                            if (!post.empty()) sec.postscript = post;
                            sec_from_api = true;
                        }
                    }
                } catch (...) {
                    // 失敗時は通常の HTML 取得へフォールバック
                }
            }
        }
        if (!sec_from_api) {
        std::string body_html;
        try {
            body_html = http.fetch(apply_fetch_url_template(preset, abs, true), access, opts.url);
        } catch (const std::exception& e) {
            if (std::getenv("NC_DEBUG")) std::fprintf(stderr, "[dl-fail] fetch %s: %s\n", ch.href.c_str(), e.what());
            ++failed;
            set_progress(total, downloaded, skipped, failed,
                         "取得失敗: " + ch.subtitle, true);
            continue;
        }
        try {
            sec = parser.parse_section(body_html);
        } catch (const std::exception& e) {
            if (std::getenv("NC_DEBUG")) std::fprintf(stderr, "[dl-fail] parse %s: %s\n", ch.href.c_str(), e.what());
            ++failed;
            set_progress(total, downloaded, skipped, failed,
                         "解析失敗: " + ch.subtitle, true);
            continue;
        }
        }
        // 挿絵・画像は取得時にローカル保存(小説追加=全話取得に伴って揃う)。
        {
            std::string join_base = opts.url;
            {
                std::string path = url_path(join_base);
                auto sl = path.rfind('/');
                std::string last = sl == std::string::npos ? path : path.substr(sl + 1);
                if (!join_base.empty() && join_base.back() != '/' &&
                    !last.empty() && last.find('.') == std::string::npos)
                    join_base += '/';
            }
            std::vector<std::string*> frags = {&sec.body};
            if (sec.introduction) frags.push_back(&*sec.introduction);
            if (sec.postscript) frags.push_back(&*sec.postscript);
            fetch_section_images(http, access, parser, join_base,
                                 novel_shard_dir(opts.output_dir, domain, novel_id) + "/img",
                                 ch.index, frags);
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
        // 改稿(既存話の差し替え)のとき、上書き前に旧本文を版として保存する。
        if (was_done) {
            try { storage.archive_section_version(novel_id, ch.index, now_rfc3339()); }
            catch (const std::exception&) {}
        }
        pending.push_back(std::move(up));

        bool should_flush =
            reader_mode ? (k < reader_window || pending.size() >= flush_batch)
                        : pending.size() >= flush_batch;
        if (should_flush) flush();

        // 新規取得と更新(改稿等の再取得)を分けて数える。
        if (was_done) ++updated;
        else ++downloaded;
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
    TocResult tr;
    std::string active_url = opts.url;
    std::string active_domain = domain;
    std::string active_id = novel_id;
    std::string first_error;
    for (auto& cand : family_url_candidates(opts.url)) {
        active_url = cand;
        active_domain = url_host(cand);
        active_id = novel_id_from_toc_url(cand);
        try {
            Value cand_preset = config::load_effective_preset(url_host(cand));
            TocResult t = fetch_toc_pages(
                http, cand, url_host(cand), cand_preset, opts.toc_html,
                [&](const TocResult& partial) {
                    std::vector<StoredTocChapter> stored;
                    for (auto& ch : partial.chapters)
                        stored.push_back({ch.index, ch.href, ch.subtitle});
                    storage.upsert_novel(active_id, partial.title, partial.author,
                                         active_url, active_domain,
                                         opts.output_dir, (long long)partial.chapters.size(),
                                 now_rfc3339());
                    storage.upsert_section_placeholders(active_id, stored, now_rfc3339());
                    set_progress((long long)partial.chapters.size(), 0,
                                 (long long)partial.chapters.size(), 0, "目次を保存中", true);
                });
            if (t.chapters.empty()) throw Error("目次が空でした");
            tr = std::move(t);
            preset = cand_preset;
            domain = active_domain;
            novel_id = active_id;
            break;
        } catch (const std::exception& e) {
            if (first_error.empty()) first_error = e.what();
            continue;
        }
    }
    if (tr.chapters.empty())
        throw Error(first_error.empty() ? "目次を取得できませんでした" : first_error);
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
    // 詳細ページが表示する情報(あらすじ・状態・更新予定等)もこの時点で取得・保存する。
    // 取得に失敗した場合は保存済みの値を壊さない。
    // NOTE: story は try の外で宣言する(ブロック内宣言のまま out.set で参照すると
    // スコープ外参照でコンパイルエラーになり、アプリ全体がビルドできなくなる)。
    std::string story;
    std::string cover_url;
    {
        try {
            Value meta = fetch_metadata_via_rules(active_url, preset, http);
            story = meta.get_str("story", "");
            cover_url = meta.get_str("cover", "");
            NovelMetaExtra mx;
            mx.status = meta.get_str("status", "");
            mx.next_update = meta.get_str("next_update", "");
            mx.comment_count = meta.get_str("comment_count", "");
            mx.updated = meta.get_str("updated", "");
            if (!story.empty()) storage.update_novel_description(novel_id, story);
            storage.update_novel_meta(novel_id, mx);
            // タイトル・作者も空でなければ最新化する(旧データの作者空欄を埋める)。
            storage.update_novel_title_author(novel_id,
                                              meta.get_str("title", ""),
                                              meta.get_str("author", ""));
        } catch (const std::exception&) {
        }
    }

    set_progress((long long)tr.chapters.size(), 0, (long long)tr.chapters.size(), 0,
                 "目次取得完了", false);

    Value out = Value::map_();
    out.set("novel_id", Value::string(novel_id));
    out.set("title", Value::string(title));
    out.set("author", Value::string(author));
    out.set("episodes", Value::integer((long long)tr.chapters.size()));
    out.set("story", Value::string(story));
    out.set("cover", Value::string(cover_url));
    out.set("chapters", std::move(chapters));
    return out;
}

Value op_novel_info(const std::string& url) {
    HttpClient http;
    // なろう族ホスト(R18作品は mnlt/mid ドメインに実体が無いケースがある)は
    // 目次/ダウンロードと同様に族フォールバックで解決する。
    std::string first_error;
    for (auto& cand : family_url_candidates(url)) {
        try {
            Value preset = config::load_effective_preset(url_host(cand));
            return fetch_metadata_via_rules(cand, preset, http);
        } catch (const std::exception& e) {
            if (first_error.empty()) first_error = e.what();
        }
    }
    throw Error(first_error.empty() ? "info failed" : first_error);
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
    novel.set("description", Value::string(storage.novel_description(novel_id)));
    {
        auto mx = storage.novel_meta(novel_id);
        novel.set("status", Value::string(mx.status));
        novel.set("next_update", Value::string(mx.next_update));
        novel.set("comment_count", Value::string(mx.comment_count));
        novel.set("site_updated", Value::string(mx.updated));
    }

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
            // 過去のバージョンが保存した相対パス(NovelDL-out など)は
            // root_dir 基準に直す。相対のままでは CWD(iOS では書き込み不可)
            // へ向かい、目次の再取得が静かに失敗する。
            if (!opts.output_dir.empty() && opts.output_dir[0] != '/')
                opts.output_dir = root_dir + "/" + opts.output_dir;
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
    try { v.set("versions", Value::integer(storage.section_version_count(novel_id, chapter_index))); }
    catch (const std::exception&) { v.set("versions", Value::integer(0)); }
    return v;
}

Value op_section_version_get(const std::string& root_dir, const std::string& novel_id,
                             const std::string& chapter_index, long long offset) {
    std::string master = root_dir + "/master.db";
    std::error_code ec;
    if (!fs::exists(master, ec)) master = root_dir + "/sections.sqlite3";
    if (!fs::exists(master, ec)) throw Error("library not found at " + root_dir);
    SectionStorage storage(master);
    auto sec = storage.get_section_version(novel_id, chapter_index, offset);
    if (!sec) throw Error("version not found: " + novel_id + " / " + chapter_index);
    Value v = Value::map_();
    v.set("index", Value::string(sec->index));
    v.set("subtitle", Value::string(sec->subtitle));
    v.set("intro_xhtml", Value::string(sec->intro_xhtml));
    v.set("body_xhtml", Value::string(sec->body_xhtml));
    v.set("post_xhtml", Value::string(sec->post_xhtml));
    v.set("updated_at", Value::string(sec->updated_at));
    v.set("versions", Value::integer(storage.section_version_count(novel_id, chapter_index)));
    return v;
}

// 本棚から小説を削除する(保存本文・目次・版履歴・表紙もまとめて)。
Value op_novel_delete(const std::string& root_dir, const std::string& novel_id) {
    std::string master = root_dir + "/master.db";
    std::error_code ec;
    if (!fs::exists(master, ec)) master = root_dir + "/sections.sqlite3";
    if (!fs::exists(master, ec)) throw Error("library not found at " + root_dir);
    SectionStorage storage(master);
    if (!storage.delete_novel(novel_id)) throw Error("novel not found: " + novel_id);
    Value v = Value::map_();
    v.set("deleted", Value::boolean(true));
    v.set("novel_id", Value::string(novel_id));
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
    // 前書き/後書きは既定で含めない(余分なものを書き出さない)。
    // 明示的に include_intro_post: true を渡した場合のみ含める。
    const bool include_extra = options.get_bool("include_intro_post", false);
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
        if (include_extra && !sec->intro_xhtml.empty())
            text += html_to_aozora(sec->intro_xhtml, false, false) + "\n\n";
        text += html_to_aozora(sec->body_xhtml, false, false);
        if (include_extra && !sec->post_xhtml.empty())
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
