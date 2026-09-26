// nc_select.cpp — CSS selector engine over nc::HtmlNode.
// Supports: type, *, #id, .class, [attr], [attr=v] (quoted or bare),
// [attr^= v $= *= ~= |=], combinators (space, >, +, ~), selector lists,
// :first-child :last-child :nth-child(an+b|odd|even) :nth-of-type(...)
// :first-of-type :last-of-type :not(...), and extraction suffixes
// ::attr(name) / :self / :self::attr(name) handled in select_extract_*.
#include "nc_html.h"

#include <cctype>
#include <regex>

namespace nc {

namespace {

struct Simple {
    enum class K { Type, Id, Class, Attr, Pseudo, Not } kind;
    std::string tag;
    std::string name;
    std::string op;   // attr op: "", "=", "^=", "$=", "*=", "~=", "|="
    std::string value;
    std::string pseudo;
    int nth_a = 0, nth_b = 0;
    std::unique_ptr<Simple> not_inner;
};

struct Compound {
    std::vector<Simple> simples;
    char combinator = ' '; // next combinator: ' ' '>' '+' '~'; 0 = end
};

struct Complex {
    std::vector<Compound> compounds;
};

struct ParsedSelector {
    std::vector<Complex> groups;
};

void skip_ws_p(const std::string& s, size_t& i) {
    while (i < s.size() && std::isspace((unsigned char)s[i])) ++i;
}

std::string parse_ident(const std::string& s, size_t& i) {
    std::string out;
    while (i < s.size() && (std::isalnum((unsigned char)s[i]) || s[i] == '-' || s[i] == '_' ||
                            (unsigned char)s[i] >= 0x80))
        out.push_back(s[i++]);
    return out;
}

Simple parse_simple(const std::string& s, size_t& i);

void parse_nth(const std::string& text, Simple& out) {
    std::string t = lower(trim(text));
    if (t == "odd") { out.nth_a = 2; out.nth_b = 1; return; }
    if (t == "even") { out.nth_a = 2; out.nth_b = 0; return; }
    static const std::regex nth_re(R"(([+-]?\d*)n\s*([+-]\s*\d+)?|[+-]?\d+)");
    std::smatch m;
    if (std::regex_match(t, m, nth_re)) {
        if (m[1].matched || (m[0].str().find('n') != std::string::npos && m[1].str() != "")) {
            std::string a = m[1].str();
            if (a.empty() || a == "+") out.nth_a = 1;
            else if (a == "-") out.nth_a = -1;
            else out.nth_a = std::stoi(a);
            std::string b = m[2].str();
            b.erase(std::remove_if(b.begin(), b.end(), ::isspace), b.end());
            out.nth_b = b.empty() ? 0 : std::stoi(b);
        } else {
            out.nth_a = 0;
            out.nth_b = std::stoi(t);
        }
        return;
    }
    // "n+2"-ish leftovers
    size_t npos = t.find('n');
    if (npos != std::string::npos) {
        std::string a = trim(t.substr(0, npos));
        std::string b = trim(t.substr(npos + 1));
        b.erase(std::remove_if(b.begin(), b.end(), ::isspace), b.end());
        if (!b.empty() && b[0] != '+' && b[0] != '-') b = "+" + b;
        out.nth_a = a.empty() || a == "+" ? 1 : (a == "-" ? -1 : std::stoi(a));
        out.nth_b = b.empty() ? 0 : std::stoi(b);
    } else {
        out.nth_a = 0;
        out.nth_b = std::stoi(t);
    }
}

Simple parse_simple(const std::string& s, size_t& i) {
    Simple out;
    if (s[i] == '*') {
        ++i;
        out.kind = Simple::K::Type;
        out.tag = "*";
        return out;
    }
    if (s[i] == '#') {
        ++i;
        out.kind = Simple::K::Id;
        out.name = parse_ident(s, i);
        return out;
    }
    if (s[i] == '.') {
        ++i;
        out.kind = Simple::K::Class;
        out.name = parse_ident(s, i);
        return out;
    }
    if (s[i] == '[') {
        ++i;
        skip_ws_p(s, i);
        out.kind = Simple::K::Attr;
        out.name = lower(parse_ident(s, i));
        skip_ws_p(s, i);
        if (i < s.size() && s[i] != ']') {
            if (s[i] == '^' || s[i] == '$' || s[i] == '*' || s[i] == '~' || s[i] == '|') {
                out.op.push_back(s[i++]);
                if (i < s.size() && s[i] == '=') { out.op.push_back('='); ++i; }
            } else if (s[i] == '=') {
                out.op = "=";
                ++i;
            }
            skip_ws_p(s, i);
            if (i < s.size() && (s[i] == '"' || s[i] == '\'')) {
                char q = s[i++];
                while (i < s.size() && s[i] != q) out.value.push_back(s[i++]);
                if (i < s.size()) ++i;
                out.value = decode_entities(out.value);
            } else {
                while (i < s.size() && s[i] != ']') out.value.push_back(s[i++]);
                out.value = decode_entities(trim(out.value));
            }
        }
        while (i < s.size() && s[i] != ']') ++i;
        if (i < s.size()) ++i;
        return out;
    }
    if (s[i] == ':') {
        ++i;
        if (i < s.size() && s[i] == ':') ++i;
        out.kind = Simple::K::Pseudo;
        out.pseudo = lower(parse_ident(s, i));
        if (i < s.size() && s[i] == '(') {
            ++i;
            std::string body;
            int depth = 1;
            while (i < s.size() && depth > 0) {
                if (s[i] == '(') ++depth;
                else if (s[i] == ')') {
                    if (--depth == 0) { ++i; break; }
                }
                body.push_back(s[i++]);
            }
            if (out.pseudo == "not") {
                out.kind = Simple::K::Not;
                size_t j = 0;
                out.not_inner = std::make_unique<Simple>(parse_simple(body, j));
            } else if (out.pseudo == "nth-child" || out.pseudo == "nth-last-child" ||
                       out.pseudo == "nth-of-type" || out.pseudo == "nth-last-of-type") {
                parse_nth(body, out);
            } else if (out.pseudo == "contains") {
                // :contains(テキスト) — 子孫テキストの部分一致。引用符があれば剥がす。
                std::string t = trim(body);
                if (t.size() >= 2 && ((t.front() == '"' && t.back() == '"') ||
                                      (t.front() == '\'' && t.back() == '\''))) {
                    t = t.substr(1, t.size() - 2);
                }
                out.kind = Simple::K::Pseudo;
                out.value = t;
            }
        }
        return out;
    }
    // type selector
    out.kind = Simple::K::Type;
    out.tag = lower(parse_ident(s, i));
    return out;
}

Compound parse_compound(const std::string& s, size_t& i) {
    Compound c;
    if (i < s.size() && (std::isalnum((unsigned char)s[i]) || s[i] == '*' || s[i] == '#' ||
                         s[i] == '.' || s[i] == '[' || s[i] == ':' || s[i] == '|')) {
        c.simples.push_back(parse_simple(s, i));
    }
    while (i < s.size() && (s[i] == '#' || s[i] == '.' || s[i] == '[' || s[i] == ':'))
        c.simples.push_back(parse_simple(s, i));
    return c;
}

ParsedSelector parse_selector(const std::string& css) {
    ParsedSelector out;
    Complex complex;
    size_t i = 0;
    skip_ws_p(css, i);
    while (i < css.size()) {
        if (css[i] == ',') {
            complex.compounds.back().combinator = 0;
            out.groups.push_back(std::move(complex));
            complex = Complex{};
            ++i;
            skip_ws_p(css, i);
            continue;
        }
        if (css[i] == '>' || css[i] == '+' || css[i] == '~') {
            if (!complex.compounds.empty()) complex.compounds.back().combinator = css[i];
            ++i;
            skip_ws_p(css, i);
            continue;
        }
        if (std::isspace((unsigned char)css[i])) {
            skip_ws_p(css, i);
            if (i < css.size() && css[i] != ',' && css[i] != '>' && css[i] != '+' &&
                css[i] != '~' && !complex.compounds.empty())
                complex.compounds.back().combinator = ' ';
            continue;
        }
        complex.compounds.push_back(parse_compound(css, i));
    }
    if (!complex.compounds.empty()) {
        complex.compounds.back().combinator = 0;
        out.groups.push_back(std::move(complex));
    }
    return out;
}

int element_index_among(const HtmlNode& node, bool type_only) {
    if (!node.parent) return 1;
    int idx = 0;
    for (auto& sibling : node.parent->children) {
        if (sibling->type != HtmlNode::T::Element) continue;
        if (type_only && sibling->tag != node.tag) continue;
        ++idx;
        if (sibling.get() == &node) return idx;
    }
    return idx;
}

bool match_nth(int idx, int a, int b) {
    if (a == 0) return idx == b;
    int n = idx - b;
    return n % a == 0 && n / a >= 0;
}

bool attr_match(const HtmlNode& n, const Simple& s) {
    const std::string* v = n.attr(s.name);
    if (!v) return false;
    if (s.op.empty()) return true;
    const std::string& val = s.value;
    const std::string& av = *v;
    if (s.op == "=") return av == val;
    if (s.op == "^=") return !val.empty() && starts_with(av, val);
    if (s.op == "$=") return !val.empty() && ends_with(av, val);
    if (s.op == "*=") return !val.empty() && av.find(val) != std::string::npos;
    if (s.op == "~=") {
        for (const std::string& part : split_ws(av))
            if (part == val) return true;
        return false;
    }
    if (s.op == "|=") return av == val || starts_with(av, val + "-");
    return false;
}

bool match_simple(const HtmlNode& n, const Simple& s) {
    if (n.type != HtmlNode::T::Element) return false;
    switch (s.kind) {
    case Simple::K::Type:
        return s.tag == "*" || s.tag == n.tag;
    case Simple::K::Id: {
        const std::string* id = n.attr("id");
        return id && *id == s.name;
    }
    case Simple::K::Class:
        return n.has_class(s.name);
    case Simple::K::Attr:
        return attr_match(n, s);
    case Simple::K::Not:
        return s.not_inner && !match_simple(n, *s.not_inner);
    case Simple::K::Pseudo: {
        if (s.pseudo == "contains") {
            if (s.value.empty()) return true;
            return html_text(n).find(s.value) != std::string::npos;
        }
        if (s.pseudo == "first-child") return element_index_among(n, false) == 1;
        if (s.pseudo == "last-child") {
            if (!n.parent) return true;
            int idx = element_index_among(n, false), total = 0;
            for (auto& c : n.parent->children)
                if (c->type == HtmlNode::T::Element) ++total;
            return idx == total;
        }
        if (s.pseudo == "only-child") {
            if (!n.parent) return true;
            int total = 0;
            for (auto& c : n.parent->children)
                if (c->type == HtmlNode::T::Element) ++total;
            return total == 1;
        }
        if (s.pseudo == "first-of-type") return element_index_among(n, true) == 1;
        if (s.pseudo == "last-of-type") {
            if (!n.parent) return true;
            int idx = element_index_among(n, true), total = 0;
            for (auto& c : n.parent->children)
                if (c->type == HtmlNode::T::Element && c->tag == n.tag) ++total;
            return idx == total;
        }
        if (s.pseudo == "nth-child") return match_nth(element_index_among(n, false), s.nth_a, s.nth_b);
        if (s.pseudo == "nth-last-child") {
            if (!n.parent) return false;
            int total = 0;
            for (auto& c : n.parent->children)
                if (c->type == HtmlNode::T::Element) ++total;
            return match_nth(total + 1 - element_index_among(n, false), s.nth_a, s.nth_b);
        }
        if (s.pseudo == "nth-of-type") return match_nth(element_index_among(n, true), s.nth_a, s.nth_b);
        if (s.pseudo == "nth-last-of-type") {
            if (!n.parent) return false;
            int total = 0;
            for (auto& c : n.parent->children)
                if (c->type == HtmlNode::T::Element && c->tag == n.tag) ++total;
            return match_nth(total + 1 - element_index_among(n, true), s.nth_a, s.nth_b);
        }
        return false;
    }
    }
    return false;
}

bool match_compound(const HtmlNode& n, const Compound& c) {
    for (auto& s : c.simples)
        if (!match_simple(n, s)) return false;
    return true;
}

// match complex ending at node: backtracking over compounds
bool try_ancestor(const HtmlNode& node, const Complex& c, size_t ci, char combinator) {
    // ci = index of the compound that `node` should match
    if (!match_compound(node, c.compounds[ci])) return false;
    if (ci == 0) return true;
    char prev_comb = c.compounds[ci - 1].combinator;
    (void)prev_comb;
    char need = c.compounds[ci].combinator ? c.compounds[ci].combinator : 0;
    // The combinator BEFORE this compound is stored on the previous compound.
    char link = c.compounds[ci - 1].combinator;
    (void)need;
    (void)combinator;
    switch (link) {
    case '>': {
        if (!node.parent) return false;
        return try_ancestor(*node.parent, c, ci - 1, 0);
    }
    case '+': {
        if (!node.parent) return false;
        HtmlNode* prev = nullptr;
        for (auto& sib : node.parent->children) {
            if (sib.get() == &node) break;
            if (sib->type == HtmlNode::T::Element) prev = sib.get();
        }
        return prev && try_ancestor(*prev, c, ci - 1, 0);
    }
    case '~': {
        if (!node.parent) return false;
        for (auto& sib : node.parent->children) {
            if (sib.get() == &node) break;
            if (sib->type == HtmlNode::T::Element &&
                try_ancestor(*sib, c, ci - 1, 0))
                return true;
        }
        return false;
    }
    default: { // descendant
        const HtmlNode* walk = node.parent;
        while (walk) {
            if (try_ancestor(*walk, c, ci - 1, 0)) return true;
            walk = walk->parent;
        }
        return false;
    }
    }
}

bool match_complex(const HtmlNode& node, const Complex& c) {
    if (c.compounds.empty()) return false;
    return try_ancestor(node, c, c.compounds.size() - 1, 0);
}

void collect_matches(HtmlNode& root, const ParsedSelector& sel,
                     std::vector<HtmlNode*>& out, bool first_only) {
    // iterate elements in document order
    std::vector<HtmlNode*> stack{&root};
    while (!stack.empty()) {
        HtmlNode* n = stack.back();
        stack.pop_back();
        if (n->type == HtmlNode::T::Element) {
            for (auto& g : sel.groups) {
                if (match_complex(*n, g)) {
                    out.push_back(n);
                    if (first_only) return;
                    break;
                }
            }
        }
        // push children in reverse for document order with stack
        for (size_t k = n->children.size(); k-- > 0;)
            stack.push_back(n->children[k].get());
    }
}

std::pair<std::string, std::string> split_attr_expr(const std::string& expr) {
    size_t at = expr.find("::attr(");
    if (at == std::string::npos) return {"", ""};
    std::string sel = trim(expr.substr(0, at));
    std::string attr = expr.substr(at + 7);
    if (!attr.empty() && attr.back() == ')') attr.pop_back();
    return {sel, trim(attr)};
}

} // namespace

std::vector<HtmlNode*> select_all(const HtmlNode& root, const std::string& css) {
    std::vector<HtmlNode*> out;
    try {
        ParsedSelector sel = parse_selector(css);
        collect_matches(const_cast<HtmlNode&>(root), sel, out, false);
    } catch (...) {
        // invalid selector — no matches (matches scraper's graceful path)
    }
    return out;
}

HtmlNode* select_first(const HtmlNode& root, const std::string& css) {
    std::vector<HtmlNode*> all = select_all(root, css);
    return all.empty() ? nullptr : all[0];
}

std::optional<std::string> select_extract_on(const HtmlNode& item, const std::string& expr) {
    std::string e = trim(expr);
    if (e == ":self") {
        std::string t = trim(html_text(item));
        return t.empty() ? std::optional<std::string>() : t;
    }
    if (starts_with(e, ":self::attr(")) {
        std::string name = e.substr(12);
        if (!name.empty() && name.back() == ')') name.pop_back();
        std::string v = item.attr_or(trim(name));
        return v.empty() ? std::optional<std::string>() : v;
    }
    auto [sel, attr] = split_attr_expr(e);
    if (!attr.empty()) {
        HtmlNode* n = sel.empty() || sel == ":self" ? const_cast<HtmlNode*>(&item)
                                                    : select_first(item, sel);
        if (!n) return std::nullopt;
        std::string v = n->attr_or(attr);
        return v.empty() ? std::optional<std::string>() : v;
    }
    HtmlNode* n = select_first(item, e);
    if (!n) return std::nullopt;
    std::string t = trim(html_text(*n));
    return t.empty() ? std::optional<std::string>() : t;
}

std::optional<std::string> select_extract_doc(const HtmlNode& doc, const std::string& expr,
                                              const std::string& mode) {
    std::string e = trim(expr);
    if (e.empty()) return std::nullopt;
    auto [sel, attr] = split_attr_expr(e);
    HtmlNode* n = nullptr;
    if (!attr.empty()) {
        n = select_first(doc, sel);
        if (!n) return std::nullopt;
        std::string v = n->attr_or(attr);
        return v.empty() ? std::optional<std::string>() : v;
    }
    n = select_first(doc, e);
    if (!n) return std::nullopt;
    std::string v;
    if (mode == "text") v = html_text(*n);
    else if (mode == "outer_html") v = html_outer(*n);
    else v = html_inner(*n);
    v = trim(v);
    return v.empty() ? std::optional<std::string>() : v;
}

} // namespace nc
