// nc_rules.cpp — YAML-driven extraction engine (nokogiri_compat.rs replacement).
#include "nc_rules.h"
#include "nc_html.h"
#include "nc_regex.h"

#include <algorithm>
#include <set>

namespace nc {

namespace {

enum class ExtractMode { Text, InnerHtml, OuterHtml };

ExtractMode parse_mode(const std::string& s) {
    if (s == "text") return ExtractMode::Text;
    if (s == "outer_html") return ExtractMode::OuterHtml;
    return ExtractMode::InnerHtml;
}

std::string clean_string(const std::string& v) { return trim(v); }

void replace_if_nonempty(std::optional<std::string>& slot, const std::string& value) {
    std::string v = clean_string(value);
    if (!v.empty()) slot = v;
}

struct ContentRule {
    std::string selector;
    long long priority = 0;
    ExtractMode extract = ExtractMode::InnerHtml;
    std::optional<std::string> pattern;
    size_t capture_group = 1;
    std::optional<std::string> capture_name;
    std::optional<std::string> json_path;
};

struct TocItemSelectors {
    std::string subtitle = "a";
    std::string href = "a::attr(href)";
    std::optional<std::string> chapter;
    std::optional<std::string> index;
    std::optional<std::string> subupdate;
};

struct TocSelectorRule {
    std::string selector;
    long long priority = 0;
    TocItemSelectors items;
    std::optional<std::string> chapter_row_class;
    std::optional<std::string> chapter_header_selector;
    std::optional<std::string> index_from_href_regex;
    size_t index_capture_group = 1;
    std::optional<std::string> href_pattern;
    bool trim_html_tail = false;
    bool hameln_dot_normalize = false;
    std::optional<std::string> subupdate_if_html_contains;
    std::string subupdate_value = "revised";
};

struct RegexChapterSource {
    long long priority = 0;
    std::string pattern;
    std::string href_template = "{href}";
    size_t id_group = 1;
    std::optional<std::string> id_name;
    size_t title_group = 2;
    std::optional<std::string> title_name;
    std::optional<size_t> index_group;
    std::optional<std::string> index_name;
    std::optional<size_t> chapter_group;
    std::optional<std::string> chapter_name;
    std::optional<size_t> subupdate_group;
    std::optional<std::string> subupdate_name;
};

struct JsonChapterSource {
    long long priority = 0;
    std::string selector = "script#__NEXT_DATA__";
    std::string href_pattern = "^/story/\\d+/\\d+$";
    std::string path_key = "path";
    std::string url_key = "url";
    std::string title_key = "title";
    std::string name_key = "name";
    bool path_only = false;
    std::vector<std::string> allowed_hosts;
    std::optional<std::string> normalize_regex;
    size_t normalize_capture_group = 0;
    std::optional<std::string> list_path;
    std::optional<std::string> href_path;
    std::optional<std::string> title_path;
    std::optional<std::string> index_path;
    std::optional<std::string> chapter_path;
    std::optional<std::string> subupdate_path;
    std::optional<std::string> href_template;
};

enum class PageMode { NextLink, AllLinks, Range };

struct TocPageRule {
    PageMode mode = PageMode::NextLink;
    std::string selector = "a[rel='next']";
    std::string href = ":self::attr(href)";
    std::optional<std::string> href_pattern;
    std::optional<std::string> text_pattern;
    std::optional<std::string> max_page_selector;
    std::optional<std::string> max_page_pattern;
    size_t max_page_capture_group = 1;
    std::optional<std::string> url_template;
    size_t start_page = 2;
    std::optional<size_t> end_page;
};

struct TocPageRegexRule {
    std::string pattern;
    std::string href_template = "{href}";
    size_t href_group = 1;
    std::optional<std::string> href_name;
};

enum class SourceKind { Selector, Regex, Json, Page, PageRegex };

struct TocSource {
    SourceKind kind;
    TocSelectorRule sel;
    RegexChapterSource re;
    JsonChapterSource json;
    TocPageRule page;
    TocPageRegexRule page_re;

    bool collects_chapters() const {
        return kind == SourceKind::Selector || kind == SourceKind::Regex ||
               kind == SourceKind::Json;
    }
    bool collects_pages() const {
        return kind == SourceKind::Page || kind == SourceKind::PageRegex;
    }
    long long priority() const {
        switch (kind) {
        case SourceKind::Selector: return sel.priority;
        case SourceKind::Regex: return re.priority;
        case SourceKind::Json: return json.priority;
        default: return 0;
        }
    }
};

struct NovelInfoSelectors {
    std::optional<std::string> title, author, story, cover;
};

struct NovelInfoRules {
    std::string source_selector = "meta[property='og:title']::attr(content)";
    std::optional<std::string> title_split_delimiter;
    bool author_from_source_regex = false;
    std::optional<std::string> author_regex;
    size_t author_capture_group = 2;
};

struct ParserRules {
    std::vector<TocSource> toc_sources;
    std::vector<ContentRule> body_rules;
    std::vector<ContentRule> introduction_rules;
    std::vector<ContentRule> postscript_rules;
    NovelInfoSelectors info;
    std::optional<NovelInfoRules> info_rules;
};

// ── YAML -> rules ─────────────────────────────────────────────────────────
std::optional<std::string> opt_str(const Value& v, const std::string& key) {
    return v.get_str_opt(key);
}

std::optional<size_t> opt_size(const Value& v, const std::string& key) {
    const Value* p = v.get(key);
    if (!p || p->is_null()) return std::nullopt;
    long long n = p->as_int_or(-1);
    return n < 0 ? std::optional<size_t>() : std::optional<size_t>((size_t)n);
}

ContentRule parse_content_rule(const Value& v) {
    ContentRule r;
    r.selector = v.get_str("selector");
    r.priority = v.get_int("priority", 0);
    r.extract = parse_mode(v.get_str("extract", "inner_html"));
    r.pattern = opt_str(v, "pattern");
    r.capture_group = v.get_int("capture_group", 1) == 0 ? 0 : (size_t)v.get_int("capture_group", 1);
    r.capture_name = opt_str(v, "capture_name");
    r.json_path = opt_str(v, "json_path");
    return r;
}

TocItemSelectors parse_items(const Value& v) {
    TocItemSelectors it;
    if (v.contains("subtitle")) it.subtitle = v.get_str("subtitle", "a");
    if (v.contains("href")) it.href = v.get_str("href", "a::attr(href)");
    it.chapter = opt_str(v, "chapter");
    it.index = opt_str(v, "index");
    it.subupdate = opt_str(v, "subupdate");
    return it;
}

TocSelectorRule parse_selector_rule(const Value& v) {
    TocSelectorRule r;
    r.selector = v.get_str("selector");
    r.priority = v.get_int("priority", 0);
    if (const Value* items = v.get("item_selectors")) r.items = parse_items(*items);
    r.chapter_row_class = opt_str(v, "chapter_row_class");
    r.chapter_header_selector = opt_str(v, "chapter_header_selector");
    r.index_from_href_regex = opt_str(v, "index_from_href_regex");
    r.index_capture_group = v.get_int("index_capture_group", 1) == 0
                                ? 0
                                : (size_t)v.get_int("index_capture_group", 1);
    r.href_pattern = opt_str(v, "href_pattern");
    r.trim_html_tail = v.get_bool("trim_html_tail", false);
    r.hameln_dot_normalize = v.get_bool("hameln_dot_normalize", false);
    r.subupdate_if_html_contains = opt_str(v, "subupdate_if_html_contains");
    r.subupdate_value = v.get_str("subupdate_value", "revised");
    return r;
}

RegexChapterSource parse_regex_source(const Value& v) {
    RegexChapterSource r;
    r.priority = v.get_int("priority", 0);
    r.pattern = v.get_str("pattern");
    r.href_template = v.get_str("href_template", "{href}");
    r.id_group = (size_t)v.get_int("id_group", 1);
    r.id_name = opt_str(v, "id_name");
    r.title_group = (size_t)v.get_int("title_group", 2);
    r.title_name = opt_str(v, "title_name");
    r.index_group = opt_size(v, "index_group");
    r.index_name = opt_str(v, "index_name");
    r.chapter_group = opt_size(v, "chapter_group");
    r.chapter_name = opt_str(v, "chapter_name");
    r.subupdate_group = opt_size(v, "subupdate_group");
    r.subupdate_name = opt_str(v, "subupdate_name");
    return r;
}

JsonChapterSource parse_json_source(const Value& v) {
    JsonChapterSource r;
    r.priority = v.get_int("priority", 0);
    r.selector = v.get_str("selector", "script#__NEXT_DATA__");
    r.href_pattern = v.get_str("href_pattern", "^/story/\\d+/\\d+$");
    r.path_key = v.get_str("path_key", "path");
    r.url_key = v.get_str("url_key", "url");
    r.title_key = v.get_str("title_key", "title");
    r.name_key = v.get_str("name_key", "name");
    r.path_only = v.get_bool("path_only", false);
    if (const Value* hosts = v.get("allowed_hosts"))
        for (auto& h : hosts->arr) r.allowed_hosts.push_back(h.as_str());
    r.normalize_regex = opt_str(v, "normalize_regex");
    r.normalize_capture_group = (size_t)v.get_int("normalize_capture_group", 0);
    r.list_path = opt_str(v, "list_path");
    r.href_path = opt_str(v, "href_path");
    r.title_path = opt_str(v, "title_path");
    r.index_path = opt_str(v, "index_path");
    r.chapter_path = opt_str(v, "chapter_path");
    r.subupdate_path = opt_str(v, "subupdate_path");
    r.href_template = opt_str(v, "href_template");
    return r;
}

TocPageRule parse_page_rule(const Value& v) {
    TocPageRule r;
    std::string mode = v.get_str("mode", "next_link");
    if (mode == "all_links") r.mode = PageMode::AllLinks;
    else if (mode == "range") r.mode = PageMode::Range;
    else r.mode = PageMode::NextLink;
    r.selector = v.get_str("selector", "a[rel='next']");
    r.href = v.get_str("href", ":self::attr(href)");
    r.href_pattern = opt_str(v, "href_pattern");
    r.text_pattern = opt_str(v, "text_pattern");
    r.max_page_selector = opt_str(v, "max_page_selector");
    r.max_page_pattern = opt_str(v, "max_page_pattern");
    r.max_page_capture_group = v.get_int("max_page_capture_group", 1) == 0
                                   ? 0
                                   : (size_t)v.get_int("max_page_capture_group", 1);
    r.url_template = opt_str(v, "url_template");
    r.start_page = (size_t)v.get_int("start_page", 2);
    r.end_page = opt_size(v, "end_page");
    return r;
}

TocPageRegexRule parse_page_regex_rule(const Value& v) {
    TocPageRegexRule r;
    r.pattern = v.get_str("pattern");
    r.href_template = v.get_str("href_template", "{href}");
    r.href_group = (size_t)v.get_int("href_group", 1);
    r.href_name = opt_str(v, "href_name");
    return r;
}

ParserRules compile_rules(const Value& preset) {
    ParserRules rules;
    if (const Value* sources = preset.get("toc_sources")) {
        for (auto& v : sources->arr) {
            std::string kind = v.get_str("source", "selector");
            TocSource src{};
            if (kind == "selector") {
                src.kind = SourceKind::Selector;
                src.sel = parse_selector_rule(v);
            } else if (kind == "regex") {
                src.kind = SourceKind::Regex;
                src.re = parse_regex_source(v);
            } else if (kind == "json") {
                src.kind = SourceKind::Json;
                src.json = parse_json_source(v);
            } else if (kind == "page") {
                src.kind = SourceKind::Page;
                src.page = parse_page_rule(v);
            } else if (kind == "page_regex") {
                src.kind = SourceKind::PageRegex;
                src.page_re = parse_page_regex_rule(v);
            } else {
                continue;
            }
            rules.toc_sources.push_back(std::move(src));
        }
    }
    auto load_rules = [&](const char* key, std::vector<ContentRule>& out) {
        if (const Value* list = preset.get(key))
            for (auto& v : list->arr) out.push_back(parse_content_rule(v));
    };
    load_rules("body_selectors", rules.body_rules);
    load_rules("introduction_selectors", rules.introduction_rules);
    load_rules("postscript_selectors", rules.postscript_rules);
    if (const Value* info = preset.get("novel_info_selectors")) {
        rules.info.title = opt_str(*info, "title");
        rules.info.author = opt_str(*info, "author");
        rules.info.story = opt_str(*info, "story");
        rules.info.cover = opt_str(*info, "cover");
    }
    if (const Value* nr = preset.get("novel_info_rules")) {
        NovelInfoRules x;
        x.source_selector =
            nr->get_str("source_selector", "meta[property='og:title']::attr(content)");
        x.title_split_delimiter = opt_str(*nr, "title_split_delimiter");
        x.author_from_source_regex = nr->get_bool("author_from_source_regex", false);
        x.author_regex = opt_str(*nr, "author_regex");
        x.author_capture_group = (size_t)nr->get_int("author_capture_group", 2);
        rules.info_rules = x;
    }
    return rules;
}

// ── extraction helpers ────────────────────────────────────────────────────
std::optional<std::string> extract_content_rule(const std::string& raw, const HtmlNode& doc,
                                                const ContentRule& rule) {
    if (rule.json_path) {
        Value j;
        try {
            j = json_parse(raw);
        } catch (...) {
            return std::nullopt;
        }
        auto v = json_path_string(j, *rule.json_path);
        return v ? std::optional<std::string>(clean_string(*v)) : std::nullopt;
    }
    if (rule.pattern) {
        Regex re(*rule.pattern, true, false); // content patterns always dotall
        auto m = re.search(raw);
        if (!m) return std::nullopt;
        std::optional<std::string> v;
        if (rule.capture_name) v = m->name(*rule.capture_name);
        if (!v) v = m->get(rule.capture_group);
        if (!v) return std::nullopt;
        std::string cleaned = clean_string(*v);
        return cleaned.empty() ? std::optional<std::string>() : std::optional<std::string>(cleaned);
    }
    if (starts_with(trim(rule.selector), "$")) {
        Value j = Value::null();
        try {
            j = json_parse(raw);
        } catch (...) {
        }
        if (!j.is_null()) {
            auto v = json_path_string(j, trim(rule.selector));
            return v ? std::optional<std::string>(clean_string(*v)) : std::nullopt;
        }
        return std::nullopt;
    }
    return select_extract_doc(doc, rule.selector,
                              rule.extract == ExtractMode::Text
                                  ? "text"
                                  : (rule.extract == ExtractMode::OuterHtml ? "outer_html"
                                                                           : "inner_html"));
}

std::optional<std::string> extract_first(const std::string& raw, const HtmlNode& doc,
                                         const std::vector<ContentRule>& rules) {
    std::vector<ContentRule> ordered = rules;
    std::stable_sort(ordered.begin(), ordered.end(),
                     [](const ContentRule& a, const ContentRule& b) {
                         return a.priority > b.priority;
                     });
    for (auto& rule : ordered) {
        auto v = extract_content_rule(raw, doc, rule);
        if (v && !trim(*v).empty()) return v;
    }
    return std::nullopt;
}

std::optional<std::string> regex_capture(const std::string& value, const std::string& pattern,
                                         size_t group, bool dotall = false) {
    try {
        Regex re(pattern, dotall, false);
        auto m = re.search(value);
        if (!m) return std::nullopt;
        auto v = m->get(group);
        if (!v) return std::nullopt;
        std::string cleaned = clean_string(*v);
        return cleaned.empty() ? std::optional<std::string>() : std::optional<std::string>(cleaned);
    } catch (...) {
        return std::nullopt;
    }
}

std::string clean_href(std::string href, const TocSelectorRule& rule) {
    href = decode_entities(trim(href));
    if (rule.trim_html_tail) {
        size_t cut = href.find_first_of("\"'<");
        if (cut != std::string::npos) href = trim(href.substr(0, cut));
    }
    if (rule.hameln_dot_normalize && !href.empty() && href[0] == '.' &&
        !starts_with(href, "./")) {
        size_t k = 0;
        while (k < href.size() && href[k] == '.') ++k;
        href = "." + href.substr(k);
    }
    return href;
}

bool href_allowed(const TocSelectorRule& rule, const std::string& href) {
    if (!rule.href_pattern) return true;
    std::string comparable = url_path_query(href);
    try {
        Regex re(*rule.href_pattern, false, false);
        return re.is_match(comparable);
    } catch (...) {
        return false;
    }
}

// apply {key} + {named_capture} templates
std::string apply_capture_template(const std::string& tmpl, const Regex::Match& m,
                                   const std::vector<std::pair<std::string, std::string>>& pairs) {
    std::string out = apply_template(tmpl, pairs);
    static const Regex re("\\{([A-Za-z_][A-Za-z0-9_]*)\\}", false, false);
    return re.replace_all(out, [&](const Regex::Match& cap) {
        std::string key = cap.get_or(1, "");
        auto v = m.name(key);
        if (v) return *v;
        return cap.get_or(0, "");
    });
}

std::string decode_jsonish_wrapped(const std::string& raw) {
    std::string wrapped = "\"" + replace_all(raw, "\"", "\\\"") + "\"";
    try {
        Value v = json_parse(wrapped);
        return v.as_str();
    } catch (...) {
        return raw;
    }
}

// ── chapter collectors ────────────────────────────────────────────────────
void collect_selector_chapters(const HtmlNode& doc, const TocSelectorRule& rule,
                               std::vector<Chapter>& chapters) {
    std::vector<HtmlNode*> items = select_all(doc, rule.selector);
    if (items.empty()) return;
    std::set<std::string> seen;
    std::optional<std::string> current_chapter;
    for (HtmlNode* item : items) {
        // chapter header row?
        if (rule.chapter_row_class) {
            const std::string* cls = item->attr("class");
            if (cls) {
                bool hit = false;
                for (const std::string& part : split_ws(*cls))
                    if (part == *rule.chapter_row_class) { hit = true; break; }
                if (hit) {
                    replace_if_nonempty(current_chapter, html_text(*item));
                    continue;
                }
            }
        }
        if (rule.chapter_header_selector) {
            auto ch = select_extract_on(*item, *rule.chapter_header_selector);
            if (ch) {
                replace_if_nonempty(current_chapter, *ch);
                continue;
            }
        }
        std::string subtitle = select_extract_on(*item, rule.items.subtitle).value_or("");
        std::string href =
            clean_href(select_extract_on(*item, rule.items.href).value_or(""), rule);
        if (!href_allowed(rule, href)) continue;
        std::string index;
        if (rule.items.index) index = select_extract_on(*item, *rule.items.index).value_or("");
        if (index.empty() && rule.index_from_href_regex)
            index = regex_capture(href, *rule.index_from_href_regex, rule.index_capture_group)
                        .value_or("");
        if (index.empty()) index = std::to_string(chapters.size() + 1);
        std::optional<std::string> chapter;
        if (rule.items.chapter) {
            auto extracted = select_extract_on(*item, *rule.items.chapter);
            if (extracted) {
                chapter = extracted;
                replace_if_nonempty(current_chapter, *extracted);
            }
        }
        if (!chapter) chapter = current_chapter;
        std::optional<std::string> subupdate;
        if (rule.items.subupdate) subupdate = select_extract_on(*item, *rule.items.subupdate);
        if (!subupdate && rule.subupdate_if_html_contains) {
            std::string inner = html_inner(*item);
            if (inner.find(*rule.subupdate_if_html_contains) != std::string::npos)
                subupdate = rule.subupdate_value;
        }
        if (!href.empty() && !subtitle.empty() && seen.insert(index + ":" + href).second) {
            chapters.push_back({index, href, subtitle, chapter, subupdate});
        }
    }
}

std::optional<std::string> capture_value(const Regex::Match& cap,
                                         const std::optional<size_t>& group,
                                         const std::optional<std::string>& name) {
    std::optional<std::string> v;
    if (name) v = cap.name(*name);
    if (!v && group) v = cap.get(*group);
    if (!v) return std::nullopt;
    std::string cleaned = clean_string(decode_jsonish_wrapped(*v));
    return cleaned.empty() ? std::optional<std::string>() : std::optional<std::string>(cleaned);
}

void collect_regex_chapters(const std::string& html, const RegexChapterSource& source,
                            std::vector<Chapter>& chapters) {
    Regex re(source.pattern, false, false);
    std::set<std::string> seen;
    for (auto& cap : re.find_all(html)) {
        std::string id;
        if (source.id_name) id = cap.name_or(*source.id_name, "");
        if (id.empty()) id = cap.get_or(source.id_group, "");
        std::string title_raw;
        if (source.title_name) title_raw = cap.name_or(*source.title_name, "");
        if (title_raw.empty()) title_raw = cap.get_or(source.title_group, "");
        if (id.empty() || title_raw.empty()) continue;
        std::string href = decode_entities(apply_capture_template(
            source.href_template, cap, {{"id", id}, {"href", id}}));
        std::string subtitle = trim(decode_jsonish_wrapped(title_raw));
        if (href.empty() || subtitle.empty() || !seen.insert(href).second) continue;
        std::string index = capture_value(cap, source.index_group, source.index_name)
                                .value_or(std::to_string(chapters.size() + 1));
        chapters.push_back(
            {index, href, subtitle, capture_value(cap, source.chapter_group, source.chapter_name),
             capture_value(cap, source.subupdate_group, source.subupdate_name)});
    }
}

bool host_allowed(const std::string& href, const std::vector<std::string>& allowed) {
    if (allowed.empty() || !starts_with(href, "http")) return true;
    std::string host = url_host(href);
    for (const std::string& a : allowed)
        if (lower(a) == lower(host)) return true;
    return false;
}

std::optional<std::string> normalize_json_href(const std::string& href,
                                               const JsonChapterSource& source) {
    if (!host_allowed(href, source.allowed_hosts)) return std::nullopt;
    std::string normalized;
    if (source.path_only) {
        normalized = url_path(trim(href));
    } else {
        normalized = trim(href);
    }
    if (source.normalize_regex) {
        return regex_capture(normalized, *source.normalize_regex,
                             source.normalize_capture_group);
    }
    return normalized;
}

void maybe_push_json_path_chapter(const Value& item, const JsonChapterSource& source,
                                  const Regex& href_regex, std::vector<Chapter>& chapters,
                                  std::set<std::string>& seen) {
    std::string href =
        source.href_path ? json_path_string(item, *source.href_path).value_or("") : "";
    std::string normalized = normalize_json_href(href, source).value_or("");
    std::string index_str;
    if (source.index_path)
        index_str = json_path_string(item, *source.index_path).value_or("");
    if (source.href_template) {
        normalized = replace_all(*source.href_template, "{href}", normalized);
        normalized = replace_all(normalized, "{index}", index_str);
    }
    if (normalized.empty() || !href_regex.is_match(normalized) ||
        !seen.insert(normalized).second)
        return;
    std::string title = source.title_path
                            ? json_path_string(item, *source.title_path).value_or("(untitled)")
                            : "(untitled)";
    std::string index =
        index_str.empty() ? std::to_string(chapters.size() + 1) : index_str;
    std::optional<std::string> chapter, subupdate;
    if (source.chapter_path) chapter = json_path_string(item, *source.chapter_path);
    if (source.subupdate_path) subupdate = json_path_string(item, *source.subupdate_path);
    chapters.push_back({index, normalized, trim(title), chapter, subupdate});
}

void maybe_push_json_chapter(const std::string& href, const std::optional<std::string>& title,
                             const JsonChapterSource& source, const Regex& href_regex,
                             std::vector<Chapter>& chapters, std::set<std::string>& seen) {
    auto normalized = normalize_json_href(href, source);
    if (!normalized) return;
    if (!href_regex.is_match(*normalized) || !seen.insert(*normalized).second) return;
    std::string t = trim(title.value_or("(untitled)"));
    if (t.empty()) t = "(untitled)";
    chapters.push_back({std::to_string(chapters.size() + 1), *normalized, t, {}, {}});
}

void collect_links_from_json(const Value& node, const JsonChapterSource& source,
                             const Regex& href_regex, std::vector<Chapter>& chapters,
                             std::set<std::string>& seen) {
    if (source.list_path) {
        const Value* list = json_path(node, *source.list_path);
        if (list && list->is_array()) {
            for (auto& item : list->arr)
                maybe_push_json_path_chapter(item, source, href_regex, chapters, seen);
        }
        return;
    }
    if (node.is_map()) {
        if (const Value* p = node.get(source.path_key))
            if (p->is_str())
                maybe_push_json_chapter(p->s, node.get_str_opt(source.title_key), source,
                                        href_regex, chapters, seen);
        if (const Value* u = node.get(source.url_key))
            if (u->is_str())
                maybe_push_json_chapter(u->s, node.get_str_opt(source.name_key), source,
                                        href_regex, chapters, seen);
        for (auto& kv : node.map)
            collect_links_from_json(kv.second, source, href_regex, chapters, seen);
    } else if (node.is_array()) {
        for (auto& item : node.arr)
            collect_links_from_json(item, source, href_regex, chapters, seen);
    }
}

std::vector<std::string> source_json_texts(const std::string& raw, const HtmlNode& doc,
                                           const JsonChapterSource& source) {
    std::string selector = trim(source.selector);
    if (selector.empty() || selector == "$" ||
        (!raw.empty() && (trim(raw)[0] == '{' || trim(raw)[0] == '['))) {
        return {raw};
    }
    std::vector<std::string> out;
    for (HtmlNode* n : select_all(doc, selector)) out.push_back(html_text(*n));
    return out;
}

void collect_json_chapters(const std::string& raw, const HtmlNode& doc,
                           const JsonChapterSource& source, std::vector<Chapter>& chapters) {
    Regex href_regex(source.href_pattern, false, false);
    std::set<std::string> seen;
    for (auto& text : source_json_texts(raw, doc, source)) {
        if (trim(text).empty()) continue;
        Value json;
        try {
            json = json_parse(text);
        } catch (...) {
            continue;
        }
        collect_links_from_json(json, source, href_regex, chapters, seen);
    }
}

std::string comparable_href(const std::string& href) { return url_path_query(href); }

void collect_page_hrefs(const HtmlNode& doc, const TocPageRule& rule,
                        std::vector<std::string>& hrefs, std::set<std::string>& seen) {
    auto matches_filter = [&](HtmlNode* item, const std::string& href) {
        if (rule.href_pattern) {
            try {
                Regex re(*rule.href_pattern, false, false);
                if (!re.is_match(comparable_href(href))) return false;
            } catch (...) {
                return false;
            }
        }
        if (rule.text_pattern) {
            try {
                Regex re(*rule.text_pattern, false, true);
                std::string text = trim(html_text(*item));
                std::string aria = item->attr_or("aria-label");
                std::string title = item->attr_or("title");
                if (!re.is_match(text) && !re.is_match(aria) && !re.is_match(title))
                    return false;
            } catch (...) {
                return false;
            }
        }
        return true;
    };
    auto push = [&](const std::string& href) {
        std::string h = trim(href);
        if (!h.empty() && seen.insert(h).second) hrefs.push_back(h);
    };
    switch (rule.mode) {
    case PageMode::NextLink: {
        for (HtmlNode* item : select_all(doc, rule.selector)) {
            std::string href = select_extract_on(*item, rule.href).value_or("");
            if (href.empty()) continue;
            if (matches_filter(item, href)) {
                push(href);
                return;
            }
        }
        break;
    }
    case PageMode::AllLinks: {
        for (HtmlNode* item : select_all(doc, rule.selector)) {
            std::string href = select_extract_on(*item, rule.href).value_or("");
            if (href.empty()) continue;
            if (matches_filter(item, href)) push(href);
        }
        break;
    }
    case PageMode::Range: {
        if (!rule.url_template) return;
        std::optional<size_t> end_page = rule.end_page;
        if (!end_page) {
            std::string sel = rule.max_page_selector.value_or(rule.selector);
            auto raw = select_extract_doc(doc, sel, "text");
            if (!raw) return;
            if (rule.max_page_pattern) {
                auto v = regex_capture(*raw, *rule.max_page_pattern, rule.max_page_capture_group);
                if (!v) return;
                try {
                    *end_page = (size_t)std::stoul(*v);
                } catch (...) {
                    return;
                }
            } else {
                std::string digits;
                for (char c : *raw)
                    if (std::isdigit((unsigned char)c)) digits.push_back(c);
                if (digits.empty()) return;
                try {
                    *end_page = (size_t)std::stoul(digits);
                } catch (...) {
                    return;
                }
            }
        }
        if (*end_page < rule.start_page) return;
        for (size_t page = rule.start_page; page <= *end_page; ++page)
            push(replace_all(*rule.url_template, "{page}", std::to_string(page)));
        break;
    }
    }
}

void collect_page_regex_hrefs(const std::string& html, const TocPageRegexRule& rule,
                              std::vector<std::string>& hrefs, std::set<std::string>& seen) {
    Regex re(rule.pattern, true, false);
    for (auto& cap : re.find_all(html)) {
        std::string raw_href;
        if (rule.href_name) raw_href = cap.name_or(*rule.href_name, "");
        if (raw_href.empty()) raw_href = cap.get_or(rule.href_group, "");
        if (raw_href.empty()) continue;
        std::string href = decode_entities(apply_capture_template(
            rule.href_template, cap,
            {{"href", raw_href}, {"next_page", raw_href}}));
        if (!trim(href).empty() && seen.insert(href).second) hrefs.push_back(href);
    }
}

// ── engine ────────────────────────────────────────────────────────────────
struct Engine {
    ParserRules rules;

    void collect_source(const std::string& html, const HtmlNode& doc, const TocSource& source,
                        std::vector<Chapter>& chapters,
                        std::pair<std::vector<std::string>*, std::set<std::string>*> pages) const {
        switch (source.kind) {
        case SourceKind::Selector:
            if (pages.first) return;
            collect_selector_chapters(doc, source.sel, chapters);
            break;
        case SourceKind::Regex:
            if (pages.first) return;
            collect_regex_chapters(html, source.re, chapters);
            break;
        case SourceKind::Json:
            if (pages.first) return;
            collect_json_chapters(html, doc, source.json, chapters);
            break;
        case SourceKind::Page:
            if (pages.first) collect_page_hrefs(doc, source.page, *pages.first, *pages.second);
            break;
        case SourceKind::PageRegex:
            if (pages.first)
                collect_page_regex_hrefs(html, source.page_re, *pages.first, *pages.second);
            break;
        }
    }

    std::vector<TocSource> ordered_sources() const {
        std::vector<TocSource> out = rules.toc_sources;
        std::stable_sort(out.begin(), out.end(),
                         [](const TocSource& a, const TocSource& b) {
                             return a.priority() > b.priority();
                         });
        return out;
    }

    ParsedToc parse_toc(const std::string& html) const {
        HtmlDoc doc = parse_html(html);
        ParsedToc toc;
        toc.title = extract_info(html, *doc, "title");
        toc.author = extract_info(html, *doc, "author");
        apply_info_rules(html, *doc, toc.title, toc.author);
        toc.story = extract_info(html, *doc, "story");
        for (auto& source : ordered_sources()) {
            if (!source.collects_chapters()) continue;
            collect_source(html, *doc, source, toc.chapters, {nullptr, nullptr});
            if (!toc.chapters.empty()) break;
        }
        return toc;
    }

    std::vector<std::string> parse_toc_page_hrefs(const std::string& html) const {
        HtmlDoc doc = parse_html(html);
        std::vector<std::string> hrefs;
        std::set<std::string> seen;
        std::vector<Chapter> dummy;
        for (auto& source : rules.toc_sources) {
            if (!source.collects_pages()) continue;
            collect_source(html, *doc, source, dummy, {&hrefs, &seen});
        }
        return hrefs;
    }

    ParsedSection parse_section(const std::string& html) const {
        HtmlDoc doc = parse_html(html);
        ParsedSection sec;
        auto body = extract_first(html, *doc, rules.body_rules);
        if (!body) throw Error("body not found");
        sec.body = *body;
        sec.introduction = extract_first(html, *doc, rules.introduction_rules);
        sec.postscript = extract_first(html, *doc, rules.postscript_rules);
        return sec;
    }

    std::optional<std::string> extract_info(const std::string& raw, const HtmlNode& doc,
                                            const std::string& field) const {
        std::optional<std::string> sel;
        if (field == "title") sel = rules.info.title;
        else if (field == "author") sel = rules.info.author;
        else if (field == "story") sel = rules.info.story;
        else if (field == "cover") sel = rules.info.cover;
        if (sel) {
            std::string trimmed = trim(*sel);
            if (starts_with(trimmed, "$")) {
                Value j = Value::null();
                try {
                    j = json_parse(raw);
                } catch (...) {
                }
                if (!j.is_null()) {
                    auto v = json_path_string(j, trimmed);
                    if (v && !trim(*v).empty()) return v;
                }
            }
            auto v = select_extract_doc(doc, *sel, "text");
            if (v && !trim(*v).empty()) return v;
            // attribute selectors already handled; retry inner_html for rich text
            v = select_extract_doc(doc, *sel, "inner_html");
            if (v && !trim(*v).empty()) return v;
        }
        if (field == "title") return select_extract_doc(doc, "title", "text");
        return std::nullopt;
    }

    void apply_info_rules(const std::string& raw, const HtmlNode& doc,
                          std::optional<std::string>& title,
                          std::optional<std::string>& author) const {
        if (!rules.info_rules) return;
        const NovelInfoRules& nr = *rules.info_rules;
        auto raw_value = select_extract_doc(doc, nr.source_selector, "text");
        if (!raw_value) return;
        if (nr.title_split_delimiter) {
            size_t at = raw_value->find(*nr.title_split_delimiter);
            if (at != std::string::npos) replace_if_nonempty(title, raw_value->substr(0, at));
        }
        if (nr.author_from_source_regex &&
            (!author || trim(*author).empty()) && nr.author_regex) {
            auto v = regex_capture(*raw_value, *nr.author_regex, nr.author_capture_group);
            if (v) replace_if_nonempty(author, *v);
        }
    }
};

} // namespace

// ── RulesParser ───────────────────────────────────────────────────────────
RulesParser::RulesParser(Value preset) : preset_(std::move(preset)) {}

ParsedToc RulesParser::parse_toc(const std::string& html) const {
    Engine e{compile_rules(preset_)};
    return e.parse_toc(html);
}

namespace {
// 明示ルールが無い場合の保険:ページ送りリンク(次へ 等 / rel="next")を汎用検出する。
// 複数ページに分かれた目次を持つサイトを、個別ルール無しでも取りこぼさないため。
std::vector<std::string> generic_next_page_hrefs(const std::string& html) {
    Regex anchor(R"(<a\b[^>]*href\s*=\s*[\"']([^\"']+)[\"'][^>]*>([\s\S]*?)</a>)", false, true);
    Regex rel(R"(\brel\s*=\s*[\"']([^\"']+)[\"'])", false, true);
    Regex next_text(R"(^\s*(次へ|次のページ|次の頁|次へ移動|次|next|»|›|≫|>>)\s*$)", false, true);
    Regex tag(R"(<[^>]+>)");
    std::vector<std::string> out;
    std::set<std::string> seen;
    for (auto& m : anchor.find_all(html)) {
        std::string href = m.get_or(1, "");
        if (href.empty() || href[0] == '#' || href.rfind("javascript:", 0) == 0) continue;
        bool is_next = false;
        if (auto rm = rel.search(m.groups.empty() ? std::string() : m.groups[0])) {
            std::string v = rm->get_or(1, "");
            std::transform(v.begin(), v.end(), v.begin(), ::tolower);
            is_next = v.find("next") != std::string::npos;
        }
        std::string text = trim(tag.replace_all(m.get_or(2, ""), ""));
        if (!is_next && !next_text.is_match(text)) continue;
        if (seen.insert(href).second) out.push_back(href);
    }
    return out;
}
}  // namespace

std::vector<std::string> RulesParser::parse_image_srcs(const std::string& html) const {
    std::string custom = preset_.is_map() ? preset_.get_str("image_pattern", "") : "";
    std::string pattern = custom.empty()
                              ? std::string(R"(<img\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"'])")
                              : custom;
    Regex re(pattern, false, true);
    std::vector<std::string> out;
    std::set<std::string> seen;
    for (auto& m : re.find_all(html)) {
        std::string src = m.get_or(1, "");
        if (src.empty() || src.rfind("data:", 0) == 0) continue;
        if (seen.insert(src).second) out.push_back(src);
    }
    return out;
}

std::vector<std::string> RulesParser::parse_toc_page_hrefs(const std::string& html) const {
    Engine e{compile_rules(preset_)};
    auto hrefs = e.parse_toc_page_hrefs(html);
    if (hrefs.empty()) hrefs = generic_next_page_hrefs(html);
    return hrefs;
}

ParsedSection RulesParser::parse_section(const std::string& html) const {
    Engine e{compile_rules(preset_)};
    return e.parse_section(html);
}

// ── legacy YAML normalization (Ruby narorb compatibility) ─────────────────
namespace {
void insert_regex_content_rule(Value& map, const std::string& key, const std::string& pattern,
                               const std::string& capture_name) {
    if (trim(pattern).empty() || trim(pattern) == "null") return;
    Value rule = Value::map_();
    rule.set("pattern", Value::string(pattern));
    rule.set("capture_name", Value::string(capture_name));
    rule.set("extract", Value::string("inner_html"));
    Value seq = Value::array();
    seq.push(std::move(rule));
    map.set(key, std::move(seq));
}

std::optional<std::string> first_legacy_pattern(const Value& map, const std::string& key) {
    const Value* v = map.get(key);
    if (!v) return std::nullopt;
    if (v->is_str()) return v->s;
    if (v->is_array()) {
        for (auto& item : v->arr)
            if (item.is_str()) return item.s;
    }
    return std::nullopt;
}
} // namespace

Value RulesParser::normalize_legacy(Value map) {
    if (!map.is_map()) return map;
    if (auto p = first_legacy_pattern(map, "body_pattern"))
        insert_regex_content_rule(map, "body_selectors", *p, "body");
    if (auto p = first_legacy_pattern(map, "introduction_pattern"))
        insert_regex_content_rule(map, "introduction_selectors", *p, "introduction");
    if (auto p = first_legacy_pattern(map, "postscript_pattern"))
        insert_regex_content_rule(map, "postscript_selectors", *p, "postscript");

    Value sources = Value::array();
    if (auto p = first_legacy_pattern(map, "subtitles")) {
        Value src = Value::map_();
        src.set("source", Value::string("regex"));
        src.set("priority", Value::integer(10));
        src.set("pattern", Value::string(*p));
        std::string href = map.get_str("href", "{index}");
        src.set("href_template", Value::string(legacy_template(href)));
        src.set("id_name", Value::string("index"));
        src.set("index_name", Value::string("index"));
        src.set("title_name", Value::string("subtitle"));
        src.set("chapter_name", Value::string("chapter"));
        src.set("subupdate_name", Value::string("subupdate"));
        sources.push(std::move(src));
    }
    if (auto p = first_legacy_pattern(map, "next_toc")) {
        Value src = Value::map_();
        src.set("source", Value::string("page_regex"));
        std::string href_template = legacy_template(map.get_str("next_url", "{next_page}"));
        href_template = replace_all(href_template, "{domain}", map.get_str("domain"));
        src.set("pattern", Value::string(*p));
        src.set("href_template", Value::string(href_template));
        src.set("href_name", Value::string("next_page"));
        sources.push(std::move(src));
    }
    if (sources.size() > 0) {
        map.set("toc_sources", std::move(sources));
    } else if (!map.contains("toc_sources")) {
        if (const Value* selectors = map.get("toc_selectors")) {
            if (selectors->is_array() && selectors->size() > 0) {
                Value out = Value::array();
                for (auto item : selectors->arr) {
                    item.set("source", Value::string("selector"));
                    out.push(std::move(item));
                }
                map.set("toc_sources", std::move(out));
            }
        }
    }
    return map;
}

// ── AccessSettings ────────────────────────────────────────────────────────
AccessSettings AccessSettings::from_preset(const Value& preset) {
    AccessSettings out;
    const Value* access = preset.get("access");
    if (!access) return out;
    out.profile = access->get_str_opt("profile");
    out.referer = access->get_str_opt("referer");
    if (const Value* headers = access->get("headers"))
        for (auto& kv : headers->map) out.headers.emplace_back(kv.first, kv.second.as_str());
    if (const Value* cookies = access->get("cookies")) {
        std::vector<std::string> parts;
        for (auto& v : cookies->arr) {
            std::string s = trim(v.as_str());
            if (!s.empty()) parts.push_back(s);
        }
        if (!parts.empty()) out.cookies = join(parts, "; ");
    }
    out.confirm_over18 = preset.get_bool("confirm_over18", false);
    out.age_gate_link_regex =
        preset.get_str("age_gate_link_regex", "");
    out.browser_fallback = access->get_bool("browser_fallback", false);
    if (const Value* fallback = access->get("fallback"))
        if (fallback->get_str("on_challenge") == "browser_fetch_command")
            out.browser_fallback = true;
    return out;
}

} // namespace nc
