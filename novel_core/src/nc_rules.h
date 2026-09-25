// nc_rules.h — YAML-driven extraction engine.
//
// ONE engine replaces the former narou/kakuyomu/hameln/novelupplus/legacy
// Rust parsers.  All site differences live in presets/parsers/<domain>.yaml;
// no per-site C/C++ code is ever required to add a site.
#pragma once

#include "nc_common.h"
#include "nc_value.h"

namespace nc {

struct Chapter {
    std::string index;
    std::string href;
    std::string subtitle;
    std::optional<std::string> chapter;
    std::optional<std::string> subupdate;

    std::string signature() const {
        return href + "|" + subtitle + "|" + (chapter ? *chapter : "") + "|" +
               (subupdate ? *subupdate : "");
    }
};

struct ParsedToc {
    std::optional<std::string> title;
    std::optional<std::string> author;
    std::optional<std::string> story;
    std::vector<Chapter> chapters;
};

struct ParsedSection {
    std::string body;
    std::optional<std::string> introduction;
    std::optional<std::string> postscript;
};

class RulesParser {
public:
    // preset: parsed YAML site definition (extends already resolved).
    explicit RulesParser(Value preset);

    ParsedToc parse_toc(const std::string& html) const;
    std::vector<std::string> parse_toc_page_hrefs(const std::string& html) const;
    ParsedSection parse_section(const std::string& html) const;

    const Value& preset() const { return preset_; }

    // Legacy YAML normalization (body_pattern / subtitles / toc_selectors ...).
    static Value normalize_legacy(Value preset);

private:
    Value preset_;
};

// access settings helper shared with the HTTP layer
struct AccessSettings {
    std::optional<std::string> profile;      // safari_mobile | safari_desktop | chrome_desktop
    std::optional<std::string> referer;      // "toc_parent" or static url
    std::vector<std::pair<std::string, std::string>> headers;
    std::optional<std::string> cookies;
    bool browser_fallback = false;
    static AccessSettings from_preset(const Value& preset);
};

} // namespace nc
