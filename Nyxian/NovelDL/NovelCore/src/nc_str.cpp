// nc_str.cpp — string utilities, entities, XHTML/aozora conversion, URL helpers.
// Consolidates helper.rs + sanitize.rs + xhtml.rs + conversion_html.rs + regex text helpers.
#include "nc_common.h"
#include "nc_regex.h"

#include <cctype>
#include <ctime>
#include <sstream>

namespace nc {

// ── basics ────────────────────────────────────────────────────────────────
std::string trim(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && std::isspace((unsigned char)s[b])) ++b;
    while (e > b && std::isspace((unsigned char)s[e - 1])) --e;
    return s.substr(b, e - b);
}

std::string lower(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

std::string upper(std::string s) {
    for (char& c : s) c = (char)std::toupper((unsigned char)c);
    return s;
}

bool starts_with(const std::string& s, const std::string& prefix) {
    return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

bool ends_with(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() &&
           s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string replace_all(std::string s, const std::string& from, const std::string& to) {
    if (from.empty()) return s;
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
    return s;
}

std::vector<std::string> split(const std::string& s, char sep) {
    std::vector<std::string> out;
    size_t start = 0;
    for (size_t i = 0; i <= s.size(); ++i) {
        if (i == s.size() || s[i] == sep) {
            out.push_back(s.substr(start, i - start));
            start = i + 1;
        }
    }
    return out;
}

std::vector<std::string> split_ws(const std::string& s) {
    std::vector<std::string> out;
    std::istringstream is(s);
    std::string tok;
    while (is >> tok) out.push_back(tok);
    return out;
}

std::string join(const std::vector<std::string>& parts, const std::string& sep) {
    std::string out;
    for (size_t k = 0; k < parts.size(); ++k) {
        if (k) out += sep;
        out += parts[k];
    }
    return out;
}

bool contains_ci(const std::string& haystack, const std::string& needle) {
    return lower(haystack).find(lower(needle)) != std::string::npos;
}

std::string to_str(double v) {
    char buf[40];
    std::snprintf(buf, sizeof buf, "%.15g", v);
    return buf;
}

size_t utf8_length(const std::string& s) {
    size_t n = 0;
    for (unsigned char c : s)
        if ((c & 0xC0) != 0x80) ++n;
    return n;
}

std::string utf8_substr(const std::string& s, size_t start, size_t len) {
    size_t i = 0, count = 0, begin = std::string::npos, end = s.size();
    for (; i < s.size(); ++i) {
        if (((unsigned char)s[i] & 0xC0) == 0x80) continue;
        if (count == start) begin = i;
        if (count == start + len) { end = i; break; }
        ++count;
    }
    if (begin == std::string::npos) return "";
    return s.substr(begin, end - begin);
}

// ── entities ──────────────────────────────────────────────────────────────
namespace {
struct NamedEnt { const char* name; const char* value; };
const NamedEnt kNamed[] = {
    {"amp", "&"},  {"lt", "<"},   {"gt", ">"},   {"quot", "\""}, {"apos", "'"},
    {"nbsp", "\xC2\xA0"}, {"copy", "\xC2\xA9"}, {"hellip", "\xE2\x80\xA6"},
    {"mdash", "\xE2\x80\x94"}, {"ndash", "\xE2\x80\x93"},
    {"lsquo", "\xE2\x80\x98"}, {"rsquo", "\xE2\x80\x99"},
    {"ldquo", "\xE2\x80\x9C"}, {"rdquo", "\xE2\x80\x9D"},
    {"times", "\xC3\x97"}, {"divide", "\xC3\xB7"},
    {"yen", "\xC2\xA5"}, {"deg", "\xC2\xB0"}, {"plusmn", "\xC2\xB1"},
};
void append_codepoint(std::string& out, long cp) {
    if (cp < 0) return;
    if (cp < 0x80) out.push_back((char)cp);
    else if (cp < 0x800) {
        out.push_back((char)(0xC0 | (cp >> 6)));
        out.push_back((char)(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back((char)(0xE0 | (cp >> 12)));
        out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back((char)(0x80 | (cp & 0x3F)));
    } else {
        out.push_back((char)(0xF0 | (cp >> 18)));
        out.push_back((char)(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back((char)(0x80 | (cp & 0x3F)));
    }
}
} // namespace

std::string decode_entities(const std::string& s) {
    if (s.find('&') == std::string::npos) return s;
    std::string out;
    out.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        char c = s[i];
        if (c != '&') { out.push_back(c); ++i; continue; }
        size_t semi = s.find(';', i + 1);
        if (semi == std::string::npos || semi - i > 12 || semi == i + 1) {
            out.push_back(c);
            ++i;
            continue;
        }
        std::string body = s.substr(i + 1, semi - i - 1);
        bool replaced = false;
        if (body[0] == '#') {
            long cp = -1;
            try {
                if (body.size() > 1 && (body[1] == 'x' || body[1] == 'X'))
                    cp = std::stol(body.substr(2), nullptr, 16);
                else
                    cp = std::stol(body.substr(1), nullptr, 10);
            } catch (...) {}
            if (cp >= 0) {
                if (cp == 160) out += "\xC2\xA0";
                else append_codepoint(out, cp);
                replaced = true;
            }
        } else {
            for (auto& ent : kNamed) {
                if (body == ent.name) { out += ent.value; replaced = true; break; }
            }
        }
        if (replaced) i = semi + 1;
        else { out.push_back(c); ++i; }
    }
    return out;
}

std::string escape_markup_text(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        switch (c) {
        case '&': out += "&amp;"; break;
        case '<': out += "&lt;"; break;
        case '>': out += "&gt;"; break;
        default: out.push_back(c);
        }
    }
    return out;
}

std::string restore_entity(const std::string& s) {
    std::string out = replace_all(s, "&nbsp;", " ");
    out = replace_all(out, "&#160;", " ");
    out = replace_all(out, "&lt;", "<");
    out = replace_all(out, "&gt;", ">");
    out = replace_all(out, "&amp;", "&");
    out = replace_all(out, "&quot;", "\"");
    out = replace_all(out, "&#39;", "'");
    return out;
}

std::string normalize_ws(const std::string& s) {
    std::string out;
    bool ws = false;
    for (char c : s) {
        if (std::isspace((unsigned char)c)) {
            ws = true;
            continue;
        }
        if (ws && !out.empty()) out.push_back(' ');
        ws = false;
        out.push_back(c);
    }
    return out;
}

std::string sanitize_fragment_text(const std::string& html) {
    static const Regex re_script("<script[^>]*>[\\s\\S]*?</script>", true, false);
    static const Regex re_style("<style[^>]*>[\\s\\S]*?</style>", true, false);
    static const Regex re_comment("<!--[\\s\\S]*?-->", true, false);
    static const Regex re_tag("<[^>]+>", true, false);
    std::string s = re_script.replace_all(html, " ");
    s = re_style.replace_all(s, " ");
    s = re_comment.replace_all(s, " ");
    s = re_tag.replace_all(s, " ");
    s = restore_entity(s);
    return normalize_ws(s);
}

std::string decode_jsonish_text(const std::string& raw) {
    // JSON string unescape for \n \" \\ sequences captured from embedded JSON.
    std::string out;
    out.reserve(raw.size());
    for (size_t i = 0; i < raw.size(); ++i) {
        if (raw[i] == '\\' && i + 1 < raw.size()) {
            char e = raw[i + 1];
            switch (e) {
            case 'n': out.push_back('\n'); ++i; continue;
            case 'r': out.push_back('\r'); ++i; continue;
            case 't': out.push_back('\t'); ++i; continue;
            case '"': out.push_back('"'); ++i; continue;
            case '\\': out.push_back('\\'); ++i; continue;
            case '/': out.push_back('/'); ++i; continue;
            case 'u': {
                std::string hex;
                size_t j = i + 2;
                while (j < raw.size() && hex.size() < 4 &&
                       std::isxdigit((unsigned char)raw[j]))
                    hex.push_back(raw[j++]);
                if (hex.size() == 4) {
                    append_codepoint(out, std::stol(hex, nullptr, 16));
                    i = j - 1;
                    continue;
                }
                break;
            }
            default: break;
            }
        }
        out.push_back(raw[i]);
    }
    return out;
}

// ── templates ─────────────────────────────────────────────────────────────
std::string apply_template(const std::string& tmpl,
                           const std::vector<std::pair<std::string, std::string>>& pairs) {
    std::string out = tmpl;
    for (auto& kv : pairs) out = replace_all(out, "{" + kv.first + "}", kv.second);
    return out;
}

std::string legacy_template(const std::string& tmpl) {
    static const Regex re("\\\\k<([A-Za-z_][A-Za-z0-9_]*)>", false, false);
    return re.replace_all(tmpl, [](const Regex::Match& m) { return "{" + m.get_or(1, "") + "}"; });
}

// ── XHTML subset normalizer (xhtml.rs) ────────────────────────────────────
namespace {
namespace {
bool is_kanji_cp(uint32_t cp) {
    return (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0x3400 && cp <= 0x4DBF) || cp == 0x3005 ||
           cp == 0x3006 || cp == 0x30F5 || cp == 0x30F6;
}
uint32_t utf8_cp_at(const std::string& s, size_t i) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) return c;
    if ((c >> 5) == 6 && i + 1 < s.size())
        return ((c & 0x1Fu) << 6) | ((unsigned char)s[i + 1] & 0x3Fu);
    if ((c >> 4) == 14 && i + 2 < s.size())
        return ((c & 0x0Fu) << 12) | (((unsigned char)s[i + 1] & 0x3Fu) << 6) |
               ((unsigned char)s[i + 2] & 0x3Fu);
    return 0xFFFD;
}
} // namespace

std::string aozora_ruby_to_xhtml(const std::string& input) {
    static const Regex marked("｜([^《<>]+?)《([^》<>]+?)》", false, false);
    std::string s = marked.replace_all(
        input, "<ruby><rb>$1</rb><rp>（</rp><rt>$2</rt><rp>）</rp></ruby>");
    // implicit form: kanji-run《ruby》 — UTF-8 safe scanner (std::regex classes are bytes)
    std::string out;
    size_t i = 0;
    while (i < s.size()) {
        if (s[i] == (char)0xE3 && s.compare(i, 3, "《") == 0) {
            size_t close = s.find("》", i + 3);
            size_t base = out.size();
            while (base > 0) {
                size_t ps = base - 1;
                while (ps > 0 && ((unsigned char)out[ps] & 0xC0) == 0x80) --ps;
                if (is_kanji_cp(utf8_cp_at(out, ps)))
                    base = ps;
                else
                    break;
            }
            if (base < out.size() && close != std::string::npos) {
                std::string word = out.substr(base);
                std::string rt = s.substr(i + 3, close - i - 3);
                out.resize(base);
                out += "<ruby><rb>" + word + "</rb><rp>（</rp><rt>" + rt +
                       "</rt><rp>）</rp></ruby>";
                i = close + 3;
                continue;
            }
        }
        out.push_back(s[i]);
        ++i;
    }
    return out;
}
} // namespace

std::string xhtml_normalize_fragment(const std::string& fragment) {
    std::string s = restore_newlines(fragment);
    static const Regex br("<br\\s*/?>", true, true);
    s = br.replace_all(s, "<br/>");
    static const Regex p_open("<p(\\s[^>]*)?>", true, true);
    s = p_open.replace_all(s, [](const Regex::Match& m) {
        return "<p" + m.get_or(1, "") + ">";
    });
    static const Regex hr("<hr\\s*/?>", true, true);
    s = hr.replace_all(s, "<hr/>");
    s = aozora_ruby_to_xhtml(s);
    return trim(s);
}

// ── HTML -> Aozora (conversion_html.rs) ───────────────────────────────────
namespace {
std::string delete_tags(std::string s) {
    static const Regex re("<[^>]+>", true, false);
    std::string prev;
    while (prev != s) {
        prev = s;
        s = re.replace_all(s, "");
    }
    return s;
}
} // namespace

std::string html_to_aozora(const std::string& html, bool pre_html, bool strip_decoration) {
    std::string text = html;
    if (!pre_html) {
        static const Regex br("<br[^>]*>", true, true);
        text = br.replace_all(replace_all(replace_all(text, "\r", ""), "\n", ""), "\n");
    }
    static const Regex p_close("\\n?</p>", true, true);
    text = p_close.replace_all(text, "\n");
    static const Regex img("<img.+?src=\"(.+?)\".*?>", true, false);
    text = img.replace_all(text, "［＃挿絵（$1）入る］");
    if (!strip_decoration) {
        static const Regex b_open("<b>", true, true);
        text = b_open.replace_all(text, "［＃太字］");
        text = replace_all(text, "</b>", "［＃太字終わり］");
        text = replace_all(text, "<i>", "［＃斜体］");
        text = replace_all(text, "</i>", "［＃斜体終わり］");
        text = replace_all(text, "<s>", "［＃取消線］");
        text = replace_all(text, "</s>", "［＃取消線終わり］");
    }
    // ruby -> 青空 syntax
    {
        text = replace_all(text, "《", "≪");
        text = replace_all(text, "》", "≫");
        static const Regex ruby("<ruby>(.+?)</ruby>", true, false);
        text = ruby.replace_all(text, [](const Regex::Match& m) {
            std::string inner = m.get_or(1, "");
            static const Regex rt_split("<rt>", true, true);
            std::vector<std::string> parts = rt_split.split(inner, 2);
            if (parts.size() < 2) return delete_tags(parts[0]);
            static const Regex rp_split("<rp>", true, true);
            std::string rb = rp_split.split(parts[0], 2)[0];
            std::string rt = rp_split.split(parts[1], 2)[0];
            return "｜" + delete_tags(rb) + "《" + delete_tags(rt) + "》";
        });
        text = replace_all(text, "≪", "《");
        text = replace_all(text, "≫", "》");
    }
    static const Regex em("<em class=\"emphasisDots\">(.+?)</em>", true, false);
    text = em.replace_all(text, "［＃傍点］$1［＃傍点終わり］");
    return delete_tags(text);
}

// ── misc ──────────────────────────────────────────────────────────────────
std::string restore_newlines(const std::string& s) {
    std::string out = replace_all(s, "\r\n", "\n");
    return replace_all(out, "\r", "\n");
}

std::string replace_filename_special_chars(const std::string& s) {
    std::string out;
    for (char c : s) {
        switch (c) {
        case '/': out += "／"; break;
        case ':': out += "："; break;
        case '*': out += "＊"; break;
        case '?': out += "？"; break;
        case '"': out += "”"; break;
        case '<': out += "〈"; break;
        case '>': out += "〉"; break;
        case '[': out += "［"; break;
        case ']': out += "］"; break;
        case '{': out += "｛"; break;
        case '}': out += "｝"; break;
        case '|': out += "｜"; break;
        case '.': out += "．"; break;
        case '`': out += "｀"; break;
        case '\\': out += "￥"; break;
        case '\t': case '\n': case '\r': out += " "; break;
        default: out.push_back(c);
        }
    }
    return trim(out);
}

std::string truncate_path_component(const std::string& s, size_t limit) {
    if (utf8_length(s) <= limit) return s;
    return trim(utf8_substr(s, 0, limit));
}

std::string now_rfc3339() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
    gmtime_r(&t, &tm);
    char buf[32];
    std::strftime(buf, sizeof buf, "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf;
}

// ── URL ───────────────────────────────────────────────────────────────────
bool url_parse(const std::string& url, UrlParts& out) {
    size_t scheme_end = url.find("://");
    if (scheme_end == std::string::npos) return false;
    out.scheme = lower(url.substr(0, scheme_end));
    size_t host_start = scheme_end + 3;
    size_t path_start = url.find_first_of("/?#", host_start);
    std::string authority =
        url.substr(host_start, path_start == std::string::npos ? std::string::npos
                                                              : path_start - host_start);
    size_t at = authority.rfind('@');
    if (at != std::string::npos) authority = authority.substr(at + 1);
    size_t colon = authority.rfind(':');
    std::string hostpart = authority;
    if (colon != std::string::npos && authority.find(']') == std::string::npos) {
        hostpart = authority.substr(0, colon);
        out.port = authority.substr(colon + 1);
    } else {
        out.port.clear();
    }
    out.host = lower(hostpart);
    out.path.clear();
    out.query.clear();
    out.fragment.clear();
    if (path_start == std::string::npos) {
        out.path = "/";
        return !out.host.empty();
    }
    if (url[path_start] == '/') {
        size_t q = url.find_first_of("?#", path_start);
        out.path = url.substr(path_start, q == std::string::npos ? std::string::npos : q - path_start);
        path_start = q;
    } else {
        out.path = "/";
    }
    if (path_start != std::string::npos && url[path_start] == '?') {
        size_t f = url.find('#', path_start);
        out.query = url.substr(path_start + 1, f == std::string::npos ? std::string::npos
                                                                    : f - path_start - 1);
        path_start = f;
    }
    if (path_start != std::string::npos && url[path_start] == '#')
        out.fragment = url.substr(path_start + 1);
    return !out.host.empty();
}

std::string url_host(const std::string& url) {
    UrlParts p;
    return url_parse(url, p) ? p.host : "";
}

std::string url_path(const std::string& url) {
    UrlParts p;
    return url_parse(url, p) ? p.path : url;
}

std::string url_path_query(const std::string& url) {
    UrlParts p;
    if (!url_parse(url, p)) return url;
    return p.query.empty() ? p.path : p.path + "?" + p.query;
}

std::string url_absolute(const std::string& base, const std::string& ref) {
    std::string r = trim(ref);
    if (r.empty()) return base;
    if (starts_with(r, "http://") || starts_with(r, "https://")) return r;
    if (starts_with(r, "//")) {
        UrlParts b;
        if (!url_parse(base, b)) return r;
        return b.scheme + ":" + r;
    }
    UrlParts b;
    if (!url_parse(base, b)) return r;
    std::string origin = b.scheme + "://" + b.host +
                         (b.port.empty() ? "" : ":" + b.port);
    if (r[0] == '#') {
        size_t f = base.find('#');
        return (f == std::string::npos ? base : base.substr(0, f)) + r;
    }
    if (r[0] == '?') {
        size_t f = base.find('#');
        std::string head = f == std::string::npos ? base : base.substr(0, f);
        size_t q = head.find('?');
        return (q == std::string::npos ? head : head.substr(0, q)) + r;
    }
    if (r[0] == '/') {
        size_t cut = r.find_first_of("?#");
        std::string path = r.substr(0, cut == std::string::npos ? std::string::npos : cut);
        std::string tail = cut == std::string::npos ? "" : r.substr(cut);
        return origin + path + tail;
    }
    // relative to base directory
    std::string dir = b.path;
    size_t slash = dir.rfind('/');
    dir = slash == std::string::npos ? "/" : dir.substr(0, slash + 1);
    return origin + dir + r;
}

std::string percent_encode(const std::string& s, bool keep_slash) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : s) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~' ||
            (keep_slash && c == '/')) {
            out.push_back((char)c);
        } else {
            out.push_back('%');
            out.push_back(hex[c >> 4]);
            out.push_back(hex[c & 0xF]);
        }
    }
    return out;
}

std::string percent_decode(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size() && std::isxdigit((unsigned char)s[i + 1]) &&
            std::isxdigit((unsigned char)s[i + 2])) {
            out.push_back((char)std::stoul(s.substr(i + 1, 2), nullptr, 16));
            i += 2;
        } else if (s[i] == '+') {
            out.push_back(' ');
        } else {
            out.push_back(s[i]);
        }
    }
    return out;
}

} // namespace nc
