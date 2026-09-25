// nc_search.cpp — webnovels.jp meta search across preset-defined sites.
// Replaces search.rs: site list comes from YAML presets (webnovels_site key),
// so new sites join search without any C/C++ change.
#include "nc_common.h"
#include "nc_config.h"
#include "nc_html.h"
#include "nc_http.h"
#include "nc_regex.h"
#include "nc_search.h"
#include "nc_value.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace nc {

namespace {

const char* kSearchEndpoint = "https://webnovels.jp/search";
const int kResultsPerPage = 20;
const int kDefaultLimit = 40;
const int kMaxTotalLimit = 180;
const int kMaxPerSite = 50;

const std::pair<const char*, const char*>& known_label(const std::string& key) {
    static const std::vector<std::pair<const char*, const char*>> labels = {
        {"narou", "小説家になろう"}, {"kakuyomu", "カクヨム"},   {"hameln", "ハーメルン"},
        {"novelup", "ノベルアップ＋"}, {"arcadia", "Arcadia"}, {"akatsuki", "暁"},
    };
    static const std::pair<const char*, const char*> fallback = {"", ""};
    for (auto& kv : labels)
        if (key == kv.first) return kv;
    return fallback;
}

struct Site {
    std::string key;
    std::string label;
    std::vector<std::string> domains;
};

std::vector<Site> load_sites() {
    config::seed_default_presets();
    std::map<std::string, Site> grouped;
    auto ingest = [&](const std::string& dir) {
        std::error_code ec;
        if (!fs::exists(dir, ec)) return;
        std::vector<fs::path> entries;
        for (auto& e : fs::directory_iterator(dir, ec))
            if (e.path().extension() == ".yaml") entries.push_back(e.path());
        std::sort(entries.begin(), entries.end());
        for (auto& path : entries) {
            try {
                std::ifstream in(path, std::ios::binary);
                std::ostringstream ss;
                ss << in.rdbuf();
                Value value = yaml_parse(ss.str());
                value = config::resolve_extends(value);
                auto site_key = value.get_str_opt("webnovels_site");
                if (!site_key) continue;
                std::string key = lower(trim(*site_key));
                std::string domain = value.get_str("domain");
                if (domain.empty()) domain = path.stem().string();
                Site& site = grouped[key];
                if (site.key.empty()) {
                    site.key = key;
                    auto& label = known_label(key);
                    site.label = std::string(label.second);
                    if (site.label.empty())
                        site.label = value.get_str("webnovels_label",
                                                   value.get_str("name",
                                                                 value.get_str("sitename", key)));
                }
                if (std::find(site.domains.begin(), site.domains.end(), domain) ==
                    site.domains.end())
                    site.domains.push_back(domain);
            } catch (...) {
            }
        }
    };
    ingest(config::user_presets_dir() + "/parsers");
    ingest(config::user_presets_dir() + "/webnovel");

    static const char* order[] = {"narou", "kakuyomu", "hameln", "novelup", "arcadia", "akatsuki"};
    std::vector<Site> sites;
    for (const char* key : order) {
        auto it = grouped.find(key);
        if (it != grouped.end()) {
            sites.push_back(it->second);
            grouped.erase(it);
        }
    }
    for (auto& kv : grouped) sites.push_back(kv.second);
    return sites;
}

std::string normalize_query_input(const std::string& query) {
    std::string trimmed = trim(query);
    if (trimmed.find('%') == std::string::npos) return trimmed;
    return trim(percent_decode(replace_all(trimmed, "+", " ")));
}

std::string strip_site_filters(const std::string& query) {
    static const Regex site_re("(?:^|\\s)site:[^\\s]+", false, false);
    std::string s = site_re.replace_all(query, " ");
    return join(split_ws(s), " ");
}

std::string site_scoped_query(const std::string& query, const std::string& site) {
    std::string q = trim(query);
    return q.empty() ? "site:" + site : q + " site:" + site;
}

// クエリ中の site:xxx 指定を抽出して絞り込みに使う(検索範囲の指定)。
std::vector<std::string> extract_site_filters(std::string& query) {
    std::vector<std::string> filters;
    std::string out;
    for (auto& tok : split_ws(query)) {
        if (starts_with(lower(tok), "site:")) {
            std::string key = lower(trim(tok.substr(5)));
            if (!key.empty() && std::find(filters.begin(), filters.end(), key) == filters.end())
                filters.push_back(key);
            continue;
        }
        if (!out.empty()) out += " ";
        out += tok;
    }
    query = out;
    return filters;
}

std::string build_search_url(const std::string& endpoint, const std::string& query, int page) {
    std::string url = endpoint + "?q=" + percent_encode(query, false) + "&type=all";
    if (page > 1) url += "&p=" + std::to_string(page);
    return url;
}

std::string normalize_result_url(const std::string& href) {
    return starts_with(href, "/") ? "https://webnovels.jp" + href : href;
}

std::optional<std::string> site_key_from_webnovels_url(const std::string& href) {
    std::string path;
    if (starts_with(href, "/")) {
        path = href;
    } else {
        if (url_host(href) != "webnovels.jp") return std::nullopt;
        path = url_path(href);
    }
    while (!path.empty() && path[0] == '/') path.erase(path.begin());
    size_t slash = path.find('/');
    std::string first = slash == std::string::npos ? path : path.substr(0, slash);
    if (first.empty() || first == "search") return std::nullopt;
    return first;
}

std::optional<int> extract_episode_count(const std::string& text) {
    static const Regex re("(\\d+)\\s*(?:話|部分)", false, false);
    auto m = re.search(text);
    if (!m) return std::nullopt;
    try {
        return std::stoi(m->get_or(1, ""));
    } catch (...) {
        return std::nullopt;
    }
}

std::string normalized_text(const HtmlNode& n) {
    return join(split_ws(html_text(n)), " ");
}

Value parse_search_results(const std::string& html, const std::optional<std::string>& expected) {
    HtmlDoc doc = parse_html(html);
    Value results = Value::array();
    for (HtmlNode* row : select_all(*doc, "div.list div.row, article.row, li.row")) {
        HtmlNode* title_link = select_first(*row, "div.row-title a, .row-title a, h2 a, h3 a");
        if (!title_link) continue;
        std::string title = normalized_text(*title_link);
        auto href = title_link->attr("href");
        if (!href) continue;
        std::string url = normalize_result_url(*href);
        std::string detail_url;
        HtmlNode* detail = select_first(
            *row, "a.row-link-detail, a[href^='/narou/'], a[href^='/kakuyomu/'], "
                  "a[href^='/hameln/'], a[href^='/novelup/'], a[href^='/arcadia/'], "
                  "a[href^='/akatsuki/']");
        if (detail && detail->attr("href"))
            detail_url = normalize_result_url(detail->attr_or("href"));
        HtmlNode* site_node = select_first(*row, "span.row-site a, .row-site a");
        std::string site_label = site_node ? normalized_text(*site_node) : "";
        std::string site_key;
        if (!detail_url.empty())
            if (auto k = site_key_from_webnovels_url(detail_url)) site_key = *k;
        if (site_key.empty() && site_node && site_node->attr("href"))
            if (auto k = site_key_from_webnovels_url(site_node->attr_or("href"))) site_key = *k;
        if (site_key.empty() && expected) site_key = *expected;
        if (expected && !site_key.empty() && site_key != *expected) continue;

        std::optional<std::string> summary, author, updated;
        if (HtmlNode* n = select_first(*row, "div.row-summary, .row-summary, .summary")) {
            std::string t = normalized_text(*n);
            if (!t.empty()) summary = t;
        }
        if (HtmlNode* n = select_first(*row, "span.row-author a, .row-author a")) {
            std::string t = normalized_text(*n);
            if (!t.empty()) author = t;
        }
        std::vector<std::string> tags;
        for (HtmlNode* n : select_all(*row, "div.row-tag a, .row-tag a, .tags a")) {
            std::string t = normalized_text(*n);
            if (!t.empty()) tags.push_back(t);
        }
        if (HtmlNode* n = select_first(*row, "div.row-update, .row-update")) {
            std::string t = normalized_text(*n);
            if (starts_with(t, "更新:")) t = trim(t.substr(7));
            if (!t.empty()) updated = t;
        }
        std::optional<int> episode_count;
        if (updated) episode_count = extract_episode_count(*updated);

        Value item = Value::map_();
        item.set("title", Value::string(title));
        item.set("url", Value::string(url));
        if (!detail_url.empty()) item.set("detail_url", Value::string(detail_url));
        item.set("site", Value::string(site_label));
        item.set("site_key", Value::string(site_key));
        if (author) item.set("author", Value::string(*author));
        if (summary) item.set("summary", Value::string(*summary));
        Value tag_arr = Value::array();
        for (auto& t : tags) tag_arr.push(Value::string(t));
        item.set("tags", std::move(tag_arr));
        if (updated) item.set("updated", Value::string(*updated));
        if (episode_count) item.set("episode_count", Value::integer(*episode_count));
        results.push(std::move(item));
    }
    return results;
}

} // namespace

Value search_supported_sites() {
    std::vector<Site> sites = load_sites();
    Value arr = Value::array();
    for (auto& s : sites) {
        Value item = Value::map_();
        item.set("key", Value::string(s.key));
        item.set("label", Value::string(s.label));
        Value doms = Value::array();
        for (auto& d : s.domains) doms.push(Value::string(d));
        item.set("domains", std::move(doms));
        arr.push(std::move(item));
    }
    Value root = Value::map_();
    root.set("sites", std::move(arr));
    return root;
}

Value search_novels(const std::string& query, int limit, const std::string& site_filter) {
    std::vector<Site> sites = load_sites();
    if (sites.empty()) throw Error("no searchable sites configured");
    std::string cleaned = normalize_query_input(query);
    // site: 指定(クエリ内 or 引数)で検索範囲を絞る。先に抽出してから除去する。
    std::vector<std::string> filters = extract_site_filters(cleaned);
    if (!site_filter.empty()) {
        std::string key = lower(trim(site_filter));
        if (std::find(filters.begin(), filters.end(), key) == filters.end())
            filters.push_back(key);
    }
    if (!filters.empty()) {
        std::vector<Site> picked;
        for (auto& s : sites) {
            bool wanted = false;
            for (auto& f : filters)
                if (s.key == f || (s.key.find(f) != std::string::npos && f.size() >= 3)) wanted = true;
            if (wanted) picked.push_back(s);
        }
        if (picked.empty()) throw Error("no matching site for: " + join(filters, ", "));
        sites = picked;
    }
    if (limit <= 0) limit = kDefaultLimit;
    limit = std::min(limit, kMaxTotalLimit);
    int per_site = std::min(std::max((limit + (int)sites.size() - 1) / (int)sites.size(), 1),
                            kMaxPerSite);
    if (!filters.empty()) per_site = std::min(limit, kMaxPerSite);

    HttpClient http;
    Value results = Value::array();
    std::vector<std::string> failures;
    Value site_keys = Value::array();
    for (auto& site : sites) {
        site_keys.push(Value::string(site.key));
        int pages = std::max((per_site + kResultsPerPage - 1) / kResultsPerPage, 1);
        Value collected = Value::array();
        try {
            for (int page = 1; page <= pages; ++page) {
                std::string scoped = site_scoped_query(cleaned, site.key);
                std::string url = build_search_url(kSearchEndpoint, scoped, page);
                std::string html = http.fetch(url);
                Value page_results = parse_search_results(html, site.key);
                if (page_results.size() == 0) break;
                for (auto& r : page_results.arr) {
                    if ((int)collected.size() >= per_site) break;
                    collected.push(r);
                }
                if ((int)collected.size() >= per_site) break;
            }
        } catch (const std::exception& e) {
            failures.push_back(site.key + ": " + e.what());
            continue;
        }
        for (auto& r : collected.arr) {
            if ((int)results.size() >= limit) break;
            results.push(r);
        }
    }
    if (results.size() == 0 && failures.size() == sites.size() && !failures.empty())
        throw Error("webnovels.jp search failed for all sites: " + join(failures, "; "));

    Value root = Value::map_();
    root.set("query", Value::string(cleaned));
    root.set("sites", std::move(site_keys));
    root.set("results", std::move(results));
    return root;
}

} // namespace nc
