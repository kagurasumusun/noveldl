// nc_common.h — shared internal declarations for the novel_core C++ engine.
#pragma once

#include <map>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace nc {

// ── errors ────────────────────────────────────────────────────────────────
struct Error : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// ── small string utilities ────────────────────────────────────────────────
std::string trim(const std::string& s);
std::string lower(std::string s);
std::string upper(std::string s);
bool starts_with(const std::string& s, const std::string& prefix);
bool ends_with(const std::string& s, const std::string& suffix);
std::string replace_all(std::string s, const std::string& from, const std::string& to);
std::vector<std::string> split(const std::string& s, char sep);
std::vector<std::string> split_ws(const std::string& s);
std::string join(const std::vector<std::string>& parts, const std::string& sep);
bool contains_ci(const std::string& haystack, const std::string& needle);
std::string to_str(double v);

// UTF-8 aware helpers
size_t utf8_length(const std::string& s);
std::string utf8_substr(const std::string& s, size_t start, size_t len);

// ── HTML entities / text normalization (helper.rs + sanitize.rs) ─────────
std::string decode_entities(const std::string& s);   // named + numeric
std::string escape_markup_text(const std::string& s); // < > & only
std::string restore_entity(const std::string& s);
std::string sanitize_fragment_text(const std::string& html); // strip tags, collapse ws
std::string normalize_ws(const std::string& s);
std::string decode_jsonish_text(const std::string& raw);

// ── templates ─────────────────────────────────────────────────────────────
std::string apply_template(const std::string& tmpl,
                           const std::vector<std::pair<std::string, std::string>>& pairs);
std::string legacy_template(const std::string& tmpl); // \k<name> -> {name}

// ── XHTML subset normalizer (xhtml.rs) ────────────────────────────────────
std::string xhtml_normalize_fragment(const std::string& fragment);

// ── HTML -> Aozora conversion (conversion_html.rs) ────────────────────────
std::string html_to_aozora(const std::string& html, bool pre_html, bool strip_decoration);

// ── misc helpers (helper.rs subset actually used) ─────────────────────────
std::string restore_newlines(const std::string& s); // \r\n,\r -> \n
std::string replace_filename_special_chars(const std::string& s);
std::string truncate_path_component(const std::string& s, size_t limit);
std::string now_rfc3339();

// ── URL helpers ───────────────────────────────────────────────────────────
struct UrlParts {
    std::string scheme;   // http / https
    std::string host;     // lowercase, no port
    std::string port;
    std::string path;     // starts with '/'
    std::string query;    // without '?'
    std::string fragment;
};
bool url_parse(const std::string& url, UrlParts& out);
std::string url_host(const std::string& url);
std::string url_path(const std::string& url);
std::string url_path_query(const std::string& url);
std::string url_absolute(const std::string& base, const std::string& ref);
std::string url_query_set(const std::string& url,
                          const std::vector<std::pair<std::string, std::string>>& params);
std::string percent_encode(const std::string& s, bool keep_slash);
std::string percent_decode(const std::string& s);

} // namespace nc
