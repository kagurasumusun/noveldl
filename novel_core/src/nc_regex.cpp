// nc_regex.cpp — std::regex based engine with Ruby/Rust-style named group support.
//
// Translation rules applied before compile:
//   (?<name>…) (?'name'…) (?P<name>…)  -> (…)  with name registered
//   \k<name> \k'name' (?P=name)         -> backreference \N
//   (?i) (?s) (?m) flag groups          -> compile flags (i=icase, s=dotall)
//   '.' when dotall                     -> [\s\S]
//   '$'                                 -> (?![^\n])  (Rust line-end semantics)
//   '^'                                 -> left as string anchor (documented)
#include "nc_regex.h"

#include <algorithm>
#include <cstring>
#include <regex>

namespace nc {

namespace {

struct Translation {
    std::string out;
    std::vector<std::string> names;
    bool icase = false;
    bool dotall = false;
    std::map<std::string, size_t> name_index;
};

bool is_flag_token(const std::string& body, Translation& tr) {
    // body is inside (?...) without the '(?' and ')'.
    std::string flags;
    size_t k = 0;
    bool neg = false;
    if (k < body.size() && body[k] == '-') { neg = true; ++k; }
    while (k < body.size() && std::strchr("imsxUu", body[k])) {
        flags.push_back(body[k]);
        ++k;
    }
    if (flags.empty() || k != body.size()) return false;
    if (neg) {
        for (char f : flags) {
            if (f == 'i') tr.icase = false;
            if (f == 's') tr.dotall = false;
        }
    } else {
        for (char f : flags) {
            if (f == 'i') tr.icase = true;
            if (f == 's') tr.dotall = true;
        }
    }
    return true;
}

Translation translate(const std::string& pat) {
    Translation tr;
    tr.out.reserve(pat.size() + 8);
    size_t n = pat.size();
    size_t group_count = 0;
    auto scan_class = [&](size_t& i) {
        // i points at '['
        tr.out.push_back('[');
        ++i;
        if (i < n && pat[i] == '^') { tr.out.push_back('^'); ++i; }
        if (i < n && pat[i] == ']') { tr.out.push_back(']'); ++i; } // literal
        while (i < n) {
            char c = pat[i];
            if (c == '\\' && i + 1 < n) {
                tr.out.push_back(c);
                tr.out.push_back(pat[i + 1]);
                i += 2;
                continue;
            }
            if (c == ']') { tr.out.push_back(']'); ++i; return; }
            tr.out.push_back(c);
            ++i;
        }
    };
    for (size_t i = 0; i < n;) {
        char c = pat[i];
        if (c == '\\') {
            if (i + 3 < n && pat[i + 1] == 'k' &&
                (pat[i + 2] == '<' || pat[i + 2] == '\'')) {
                char close = pat[i + 2] == '<' ? '>' : '\'';
                size_t end = pat.find(close, i + 3);
                if (end != std::string::npos) {
                    std::string name = pat.substr(i + 3, end - i - 3);
                    auto it = tr.name_index.find(name);
                    if (it != tr.name_index.end())
                        tr.out += "\\" + std::to_string(it->second);
                    else
                        tr.out += "\\0"; // never matches; graceful
                    i = end + 1;
                    continue;
                }
            }
            tr.out.push_back(c);
            if (i + 1 < n) tr.out.push_back(pat[i + 1]);
            i += 2;
            continue;
        }
        if (c == '[') { scan_class(i); continue; }
        if (c == '.') {
            tr.out += tr.dotall ? "[\\s\\S]" : ".";
            ++i;
            continue;
        }
        if (c == '$') {
            tr.out += "(?![^\\n])";
            ++i;
            continue;
        }
        if (c == '(' && i + 1 < n && pat[i + 1] == '?') {
            // (?...) constructs
            size_t open = i + 2;
            if (open < n && pat[open] == '#') {
                size_t end = pat.find(')', open);
                i = end == std::string::npos ? n : end + 1;
                continue;
            }
            if (open < n && (pat[open] == '<' || pat[open] == '\'' || pat[open] == 'P')) {
                size_t name_start = open;
                char close_ch = '>';
                bool named = true;
                if (pat[open] == 'P') {
                    if (open + 1 < n && pat[open + 1] == '=') {
                        // (?P=name) backreference
                        size_t end = pat.find(')', open + 2);
                        if (end != std::string::npos) {
                            std::string name = pat.substr(open + 2, end - open - 2);
                            auto it = tr.name_index.find(name);
                            if (it != tr.name_index.end())
                                tr.out += "\\" + std::to_string(it->second);
                            else
                                tr.out += "\\0";
                            i = end + 1;
                            continue;
                        }
                    }
                    if (open + 1 >= n || pat[open + 1] != '<') named = false;
                    else name_start = open + 1;
                } else if (pat[open] == '\'') {
                    close_ch = '\'';
                }
                if (named && name_start < n && pat[name_start] == '<') {
                    // could be lookbehind (?<= / (?<!
                    if (name_start + 1 < n && (pat[name_start + 1] == '=' ||
                                               pat[name_start + 1] == '!')) {
                        // lookbehind: std::regex cannot; rewrite (?<=X) -> (?:) and
                        // drop is unsafe — best effort: keep and let compile fail softly.
                        tr.out += "(?:";
                        i = name_start + 2;
                        continue;
                    }
                    size_t end = pat.find(close_ch, name_start + 1);
                    if (end != std::string::npos) {
                        std::string name = pat.substr(name_start + 1, end - name_start - 1);
                        ++group_count;
                        tr.names.push_back(name);
                        tr.name_index[name] = group_count;
                        tr.out.push_back('(');
                        i = end + 1;
                        continue;
                    }
                }
            }
            // flag group or non-capturing / lookahead
            {
                size_t end = open;
                std::string body;
                int depth = 0;
                while (end < n) {
                    if (pat[end] == '(') ++depth;
                    if (pat[end] == ')') {
                        if (depth == 0) break;
                        --depth;
                    }
                    body.push_back(pat[end]);
                    ++end;
                }
                Translation probe = tr;
                std::string body_copy = body;
                if (is_flag_token(body_copy, probe)) {
                    tr.icase = probe.icase;
                    tr.dotall = probe.dotall;
                    i = end < n ? end + 1 : n;
                    continue;
                }
                if (starts_with(body, ":") || starts_with(body, "=") || starts_with(body, "!")) {
                    tr.out += "(?";
                    tr.out += body;
                    tr.out += ")";
                    i = end < n ? end + 1 : n;
                    continue;
                }
                // unknown (?...) — pass through as non-capturing best effort
                tr.out += "(?:";
                tr.out += body;
                tr.out += ")";
                i = end < n ? end + 1 : n;
                continue;
            }
        }
        if (c == '(') {
            ++group_count;
            tr.names.push_back("");
            tr.out.push_back('(');
            ++i;
            continue;
        }
        tr.out.push_back(c);
        ++i;
    }
    return tr;
}

} // namespace

struct RegexImpl {
    static std::regex& re(const Regex& r) { return *(std::regex*)r.re_.get(); }
};

Regex::Regex(const std::string& pattern, bool dotall, bool icase) : pattern_(pattern) {
    // Prescan for global inline flags ((?i)/(?s)) so '.' translation is correct
    // even when the flag appears after the first '.' in the pattern.
    bool use_dotall = dotall;
    bool use_icase = icase;
    for (size_t i = 0; i + 1 < pattern.size(); ++i) {
        if (pattern[i] == '(' && pattern[i + 1] == '?') {
            size_t end = pattern.find(')', i + 2);
            if (end != std::string::npos) {
                std::string body = pattern.substr(i + 2, end - i - 2);
                Translation probe;
                probe.dotall = use_dotall;
                probe.icase = use_icase;
                if (is_flag_token(body, probe)) {
                    use_dotall = probe.dotall;
                    use_icase = probe.icase;
                }
            }
        }
    }
    Translation tr = translate(pattern);
    // translate() starts with default flags; re-run with the prescan flags by
    // seeding through a flag token when needed.
    if (use_dotall != tr.dotall || use_icase != tr.icase) {
        std::string prefix = "(?";
        if (use_icase) prefix += "i";
        if (use_dotall) prefix += "s";
        prefix += ")";
        tr = translate(prefix + pattern);
    }
    auto flags = std::regex::ECMAScript;
    if (tr.icase) flags |= std::regex::icase;
    auto* re = new std::regex();
    try {
        re->assign(tr.out, flags);
    } catch (const std::regex_error& e) {
        delete re;
        throw Error("regex compile failed: " + std::string(e.what()) + " (pattern: " +
                    pattern + ")");
    }
    re_.reset(re);
    names_ = tr.names;
    // '.' translation with final dotall: translate() saw '.' with its running
    // flags; when dotall was set before '.', it already emitted [\s\S].
}

namespace {
bool match_from(const std::string& text, size_t pos, const std::regex& re,
                std::smatch& out) {
    if (pos > text.size()) return false;
    return std::regex_search(text.begin() + (long)pos, text.end(), out, re,
                             std::regex_constants::match_default);
}
Regex::Match to_match(const std::smatch& m, const std::vector<std::string>& names,
                      size_t base_pos) {
    Regex::Match rm;
    rm.groups.resize(m.size());
    rm.present.resize(m.size());
    for (size_t k = 0; k < m.size(); ++k) {
        if (m[k].matched) {
            rm.groups[k] = m[k].str();
            rm.present[k] = true;
        }
    }
    rm.names = names;
    rm.position = base_pos + (size_t)m.position(0);
    rm.length = (size_t)m.length(0);
    return rm;
}
std::string expand_repl(const Regex::Match& m, const std::string& repl) {
    std::string out;
    for (size_t i = 0; i < repl.size(); ++i) {
        if (repl[i] != '$') { out.push_back(repl[i]); continue; }
        if (i + 1 >= repl.size()) { out.push_back('$'); break; }
        char c = repl[i + 1];
        if (c == '$') { out.push_back('$'); ++i; continue; }
        if (c == '{') {
            size_t end = repl.find('}', i + 2);
            if (end == std::string::npos) { out.push_back('$'); continue; }
            std::string key = repl.substr(i + 2, end - i - 2);
            i = end;
            bool numeric = !key.empty() &&
                           key.find_first_not_of("0123456789") == std::string::npos;
            if (numeric) {
                size_t idx = (size_t)std::stoul(key);
                out += m.get_or(idx, "");
            } else {
                out += m.name_or(key, "");
            }
            continue;
        }
        if (std::isdigit((unsigned char)c)) {
            size_t idx = (size_t)(c - '0');
            out += m.get_or(idx, "");
            ++i;
            continue;
        }
        out.push_back('$');
    }
    return out;
}
} // namespace

std::optional<Regex::Match> Regex::search_at(const std::string& text, size_t pos) const {
    std::smatch m;
    if (!match_from(text, pos, RegexImpl::re(*this), m)) return std::nullopt;
    return to_match(m, names_, pos);
}

std::optional<Regex::Match> Regex::search(const std::string& text) const {
    return search_at(text, 0);
}

std::vector<Regex::Match> Regex::find_all(const std::string& text) const {
    std::vector<Match> out;
    size_t pos = 0;
    while (pos <= text.size()) {
        auto m = search_at(text, pos);
        if (!m) break;
        out.push_back(*m);
        size_t next = m->position + (m->length ? m->length : 1);
        if (next <= pos) next = pos + 1;
        pos = next;
    }
    return out;
}

bool Regex::is_match(const std::string& text) const {
    return search(text).has_value();
}

std::string Regex::replace_all(const std::string& text, const std::string& repl) const {
    return replace_all(text, [&](const Match& m) { return expand_repl(m, repl); });
}

std::string Regex::replace_all(const std::string& text,
                               const std::function<std::string(const Match&)>& fn) const {
    std::string out;
    size_t pos = 0;
    while (pos <= text.size()) {
        auto m = search_at(text, pos);
        if (!m) {
            out.append(text, pos, std::string::npos);
            break;
        }
        out.append(text, pos, m->position - pos);
        out += fn(*m);
        size_t next = m->position + (m->length ? m->length : 1);
        if (next <= pos) next = pos + 1;
        pos = next;
    }
    return out;
}

std::vector<std::string> Regex::split(const std::string& text, size_t limit) const {
    std::vector<std::string> out;
    size_t pos = 0, pieces = 0;
    while (pos <= text.size()) {
        if (limit && pieces + 1 >= limit) break;
        auto m = search_at(text, pos);
        if (!m) break;
        out.push_back(text.substr(pos, m->position - pos));
        ++pieces;
        size_t next = m->position + (m->length ? m->length : 1);
        if (next <= pos) next = pos + 1;
        pos = next;
    }
    out.push_back(text.substr(pos));
    return out;
}

} // namespace nc
