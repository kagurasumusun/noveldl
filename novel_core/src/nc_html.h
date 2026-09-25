// nc_html.h — forgiving HTML DOM + CSS selector engine (scraper replacement).
#pragma once

#include "nc_common.h"

namespace nc {

struct HtmlNode {
    enum class T { Document, Element, Text, Comment };
    T type = T::Element;
    std::string tag;                          // lowercase (element)
    std::string text;                         // decoded text (text/comment)
    std::vector<std::pair<std::string, std::string>> attrs; // lowercase names
    std::vector<std::unique_ptr<HtmlNode>> children;
    HtmlNode* parent = nullptr;

    bool is_element() const { return type == T::Element; }
    const std::string* attr(const std::string& name) const {
        for (auto& kv : attrs)
            if (kv.first == name) return &kv.second;
        return nullptr;
    }
    std::string attr_or(const std::string& name, const std::string& fallback = "") const {
        const std::string* v = attr(name);
        return v ? *v : fallback;
    }
    bool has_class(const std::string& cls) const;
    HtmlNode* append(std::unique_ptr<HtmlNode> child);
};

using HtmlDoc = std::unique_ptr<HtmlNode>;

HtmlDoc parse_html(const std::string& html);

// Extraction expression extras used by site presets:
//   "sel::attr(name)"  -> attribute value of first match
//   ":self"            -> text of the context element
//   ":self::attr(name)"-> attribute of the context element
//   "$.json.path"      -> JSON path (handled by caller)
std::string html_inner(const HtmlNode& n);
std::string html_outer(const HtmlNode& n);
std::string html_text(const HtmlNode& n); // concatenated text nodes (scraper semantics)

struct SelectorSet;
// Selectors matching in document order.  `root` element or document.
std::vector<HtmlNode*> select_all(const HtmlNode& root, const std::string& css);
HtmlNode* select_first(const HtmlNode& root, const std::string& css);

// Evaluate an item selector expression within an element context.
std::optional<std::string> select_extract_on(const HtmlNode& item, const std::string& expr);
// Evaluate a selector expression against a document (mode: text/inner/outer).
std::optional<std::string> select_extract_doc(const HtmlNode& doc, const std::string& expr,
                                              const std::string& mode);

} // namespace nc
