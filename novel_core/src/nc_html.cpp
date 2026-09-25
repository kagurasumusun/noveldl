// nc_html.cpp — forgiving HTML parser producing a DOM tree.
#include "nc_html.h"

#include <cctype>

namespace nc {

namespace {

bool is_void_tag(const std::string& t) {
    static const char* voids[] = {"area", "base",  "br",    "col",   "embed", "hr",
                                  "img",  "input", "link",  "meta",  "param", "source",
                                  "track", "wbr",   "!doctype"};
    for (const char* v : voids)
        if (t == v) return true;
    return false;
}

bool is_raw_text_tag(const std::string& t) {
    return t == "script" || t == "style" || t == "textarea" || t == "title" || t == "xmp";
}

// tags closed implicitly when a new block opens
bool closes_p_on_open(const std::string& t) {
    static const char* blocks[] = {
        "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "footer",
        "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav",
        "ol", "p", "pre", "section", "table", "ul"};
    for (const char* b : blocks)
        if (t == b) return true;
    return false;
}

struct Parser {
    std::string src;
    size_t pos = 0;
    HtmlNode* current = nullptr;

    explicit Parser(const std::string& html) : src(restore_newlines(html)) {}

    HtmlDoc run() {
        auto doc = std::make_unique<HtmlNode>();
        doc->type = HtmlNode::T::Document;
        current = doc.get();
        parse_body();
        return doc;
    }

    void append_text(const std::string& raw) {
        if (raw.empty()) return;
        std::string decoded = decode_entities(raw);
        auto node = std::make_unique<HtmlNode>();
        node->type = HtmlNode::T::Text;
        node->text = decoded;
        current->append(std::move(node));
    }

    void parse_body() {
        std::string text_buf;
        while (pos < src.size()) {
            char c = src[pos];
            if (c == '<') {
                if (pos + 1 < src.size() && src[pos + 1] == '!') {
                    append_text(text_buf);
                    text_buf.clear();
                    parse_markup_declaration();
                    continue;
                }
                if (pos + 1 < src.size() && src[pos + 1] == '/') {
                    append_text(text_buf);
                    text_buf.clear();
                    parse_end_tag();
                    continue;
                }
                if (pos + 1 < src.size() &&
                    (std::isalpha((unsigned char)src[pos + 1]) || src[pos + 1] == '?')) {
                    append_text(text_buf);
                    text_buf.clear();
                    if (!parse_start_tag()) {
                        text_buf.push_back('<');
                        pos = next_tag_end(pos + 1);
                        continue;
                    }
                    continue;
                }
                // stray '<'
                text_buf.push_back('<');
                ++pos;
                continue;
            }
            text_buf.push_back(c);
            ++pos;
        }
        append_text(text_buf);
    }

    void parse_markup_declaration() {
        // <! ... >  or <!-- ... -->
        if (src.compare(pos, 4, "<!--") == 0) {
            size_t end = src.find("-->", pos + 4);
            std::string body =
                src.substr(pos + 4, end == std::string::npos ? std::string::npos : end - pos - 4);
            auto node = std::make_unique<HtmlNode>();
            node->type = HtmlNode::T::Comment;
            node->text = body;
            current->append(std::move(node));
            pos = end == std::string::npos ? src.size() : end + 3;
            return;
        }
        size_t end = src.find('>', pos);
        pos = end == std::string::npos ? src.size() : end + 1;
    }

    size_t next_tag_end(size_t from) {
        size_t end = src.find('>', from);
        return end == std::string::npos ? src.size() : end + 1;
    }

    void parse_end_tag() {
        size_t p = pos + 2;
        std::string tag;
        while (p < src.size()) {
            char ch = (char)std::tolower((unsigned char)src[p]);
            if (std::isalnum((unsigned char)ch) || ch == '-' || ch == '_' || ch == ':' ||
                ch == '.')
                tag.push_back(ch), ++p;
            else
                break;
        }
        size_t end = src.find('>', p);
        pos = end == std::string::npos ? src.size() : end + 1;
        if (tag.empty()) return;
        // pop to matching open tag
        HtmlNode* walk = current;
        while (walk && walk->type != HtmlNode::T::Document) {
            if (walk->tag == tag) break;
            walk = walk->parent;
        }
        if (walk && walk->parent) current = walk->parent;
    }

    bool parse_start_tag() {
        size_t p = pos + 1;
        std::string tag;
        while (p < src.size() && (std::isalnum((unsigned char)src[p]) || src[p] == '-' ||
                                  src[p] == ':' || src[p] == '_'))
            tag.push_back((char)std::tolower((unsigned char)src[p++]));
        if (tag.empty()) return false;
        auto node = std::make_unique<HtmlNode>();
        node->type = HtmlNode::T::Element;
        node->tag = tag;
        // attributes
        while (p < src.size()) {
            while (p < src.size() && std::isspace((unsigned char)src[p])) ++p;
            if (p >= src.size()) break;
            if (src[p] == '>' || (src[p] == '/' && p + 1 < src.size() && src[p + 1] == '>')) {
                if (src[p] == '/') p += 2;
                else ++p;
                break;
            }
            if (src[p] == '<') break; // malformed; treat as tag end
            std::string name;
            while (p < src.size() && !std::isspace((unsigned char)src[p]) &&
                   src[p] != '=' && src[p] != '>' && src[p] != '/')
                name.push_back((char)std::tolower((unsigned char)src[p++]));
            if (name.empty()) { ++p; continue; }
            std::string value;
            while (p < src.size() && std::isspace((unsigned char)src[p])) ++p;
            if (p < src.size() && src[p] == '=') {
                ++p;
                while (p < src.size() && std::isspace((unsigned char)src[p])) ++p;
                if (p < src.size() && (src[p] == '"' || src[p] == '\'')) {
                    char q = src[p++];
                    std::string raw;
                    while (p < src.size() && src[p] != q) raw.push_back(src[p++]);
                    if (p < src.size()) ++p;
                    value = decode_entities(raw);
                } else {
                    std::string raw;
                    while (p < src.size() && !std::isspace((unsigned char)src[p]) &&
                           src[p] != '>')
                        raw.push_back(src[p++]);
                    value = decode_entities(raw);
                }
            }
            node->attrs.emplace_back(name, value);
        }
        pos = p;

        // implied closes
        if (tag == "li") pop_until("li", true);
        else if (tag == "dt" || tag == "dd") { pop_until("dt", true); pop_until("dd", true); }
        else if (tag == "tr") { pop_until("tr", true); pop_until("td", true); pop_until("th", true); }
        else if (tag == "td" || tag == "th") { pop_until("td", true); pop_until("th", true); }
        else if (tag == "option") pop_until("option", true);
        else if (tag == "p" || closes_p_on_open(tag)) pop_until("p", true);
        else if (tag == "thead" || tag == "tbody" || tag == "tfoot") {
            pop_until("tr", true); pop_until("td", true); pop_until("th", true);
        }

        HtmlNode* raw_parent = current;
        current->append(std::move(node));
        HtmlNode* inserted = raw_parent->children.back().get();

        if (is_void_tag(tag)) return true;
        if (is_raw_text_tag(tag)) {
            std::string close = "</" + tag;
            size_t end = lower(src).find(close, pos);
            // case-insensitive search
            size_t search = pos;
            end = std::string::npos;
            {
                std::string ls = lower(src);
                end = ls.find(close, search);
            }
            std::string body =
                src.substr(pos, end == std::string::npos ? std::string::npos : end - pos);
            auto text = std::make_unique<HtmlNode>();
            text->type = HtmlNode::T::Text;
            text->text = tag == "script" || tag == "style" ? body : decode_entities(body);
            inserted->append(std::move(text));
            if (end == std::string::npos) {
                pos = src.size();
                return true;
            }
            size_t gt = src.find('>', end);
            pos = gt == std::string::npos ? src.size() : gt + 1;
            return true;
        }
        current = inserted;
        return true;
    }

    void pop_until(const std::string& tag, bool inclusive) {
        HtmlNode* walk = current;
        while (walk && walk->type != HtmlNode::T::Document) {
            if (walk->tag == tag) {
                current = inclusive && walk->parent ? walk->parent : walk;
                return;
            }
            walk = walk->parent;
        }
    }
};

} // namespace

bool HtmlNode::has_class(const std::string& cls) const {
    const std::string* v = attr("class");
    if (!v) return false;
    for (const std::string& part : split_ws(*v))
        if (part == cls) return true;
    return false;
}

HtmlNode* HtmlNode::append(std::unique_ptr<HtmlNode> child) {
    child->parent = this;
    children.push_back(std::move(child));
    return children.back().get();
}

HtmlDoc parse_html(const std::string& html) {
    Parser p(html);
    return p.run();
}

std::string html_text(const HtmlNode& n) {
    if (n.type == HtmlNode::T::Text) return n.text;
    if (n.type == HtmlNode::T::Comment) return "";
    std::string out;
    for (auto& c : n.children) out += html_text(*c);
    return out;
}

std::string html_inner(const HtmlNode& n) {
    std::string out;
    for (auto& c : n.children) out += html_outer(*c);
    return out;
}

std::string html_outer(const HtmlNode& n) {
    if (n.type == HtmlNode::T::Text) return escape_markup_text(n.text);
    if (n.type == HtmlNode::T::Comment) return "";
    if (n.type == HtmlNode::T::Document) return html_inner(n);
    std::string out = "<" + n.tag;
    for (auto& kv : n.attrs) {
        out += " " + kv.first + "=\"" + escape_markup_text(kv.second) + "\"";
    }
    static const char* voids[] = {"area", "base",  "br",   "col",  "embed", "hr",
                                  "img",  "input", "link", "meta", "param", "source",
                                  "track", "wbr"};
    bool is_void = false;
    for (const char* v : voids)
        if (n.tag == v) is_void = true;
    if (is_void && n.children.empty()) {
        out += "/>";
        return out;
    }
    out += ">";
    out += html_inner(n);
    out += "</" + n.tag + ">";
    return out;
}

} // namespace nc
