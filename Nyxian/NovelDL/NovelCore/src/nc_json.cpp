// nc_json.cpp — JSON parser / serializer + JSONPath subset + deep merge.
#include "nc_value.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace nc {

// ── parser ────────────────────────────────────────────────────────────────
namespace {

struct JsonParser {
    const std::string& text;
    size_t pos = 0;
    int depth = 0;

    explicit JsonParser(const std::string& t) : text(t) {}

    [[noreturn]] void fail(const std::string& msg) {
        throw Error("json: " + msg + " at offset " + std::to_string(pos));
    }
    void skip_ws() {
        while (pos < text.size() &&
               (text[pos] == ' ' || text[pos] == '\t' || text[pos] == '\n' || text[pos] == '\r'))
            ++pos;
    }
    char peek() {
        if (pos >= text.size()) fail("unexpected end");
        return text[pos];
    }
    void expect(char c) {
        if (pos >= text.size() || text[pos] != c) fail(std::string("expected '") + c + "'");
        ++pos;
    }
    bool consume(char c) {
        skip_ws();
        if (pos < text.size() && text[pos] == c) { ++pos; return true; }
        return false;
    }
    void append_utf8(std::string& out, unsigned cp) {
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
    unsigned hex4() {
        unsigned v = 0;
        for (int k = 0; k < 4; ++k) {
            if (pos >= text.size()) fail("bad \\u escape");
            char c = text[pos++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
            else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
            else fail("bad \\u escape");
        }
        return v;
    }
    std::string parse_string_raw() {
        expect('"');
        std::string out;
        while (true) {
            if (pos >= text.size()) fail("unterminated string");
            char c = text[pos++];
            if (c == '"') break;
            if (c == '\\') {
                if (pos >= text.size()) fail("bad escape");
                char e = text[pos++];
                switch (e) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    unsigned cp = hex4();
                    if (cp >= 0xD800 && cp <= 0xDBFF && pos + 1 < text.size() &&
                        text[pos] == '\\' && text[pos + 1] == 'u') {
                        pos += 2;
                        unsigned lo = hex4();
                        if (lo >= 0xDC00 && lo <= 0xDFFF)
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    append_utf8(out, cp);
                    break;
                }
                default: fail("bad escape");
                }
            } else {
                out.push_back(c);
            }
        }
        return out;
    }
    Value parse_value() {
        if (++depth > 128) fail("nesting too deep");
        skip_ws();
        Value v;
        char c = peek();
        if (c == '{') {
            ++pos;
            v = Value::map_();
            skip_ws();
            if (consume('}')) { --depth; return v; }
            while (true) {
                skip_ws();
                std::string key = parse_string_raw();
                skip_ws();
                expect(':');
                v.set(key, parse_value());
                skip_ws();
                if (consume(',')) continue;
                expect('}');
                break;
            }
        } else if (c == '[') {
            ++pos;
            v = Value::array();
            skip_ws();
            if (consume(']')) { --depth; return v; }
            while (true) {
                v.push(parse_value());
                skip_ws();
                if (consume(',')) continue;
                expect(']');
                break;
            }
        } else if (c == '"') {
            v = Value::string(parse_string_raw());
        } else if (text.compare(pos, 4, "true") == 0) {
            pos += 4;
            v = Value::boolean(true);
        } else if (text.compare(pos, 5, "false") == 0) {
            pos += 5;
            v = Value::boolean(false);
        } else if (text.compare(pos, 4, "null") == 0) {
            pos += 4;
        } else {
            size_t end = pos;
            while (end < text.size() &&
                   (std::strchr("-+.eE0123456789", text[end]) != nullptr))
                ++end;
            if (end == pos) fail("unexpected token");
            std::string num = text.substr(pos, end - pos);
            pos = end;
            if (num.find_first_of(".eE") != std::string::npos)
                v = Value::real(std::strtod(num.c_str(), nullptr));
            else
                v = Value::integer(std::strtoll(num.c_str(), nullptr, 10));
        }
        --depth;
        return v;
    }
};

void dump_string(std::string& out, const std::string& s) {
    out.push_back('"');
    for (unsigned char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof buf, "\\u%04x", c);
                out += buf;
            } else {
                out.push_back((char)c);
            }
        }
    }
    out.push_back('"');
}

void dump_value(std::string& out, const Value& v, bool pretty, int indent) {
    auto pad = [&](int n) {
        if (pretty) out.append((size_t)n * 2, ' ');
    };
    switch (v.t) {
    case Value::T::Null: out += "null"; break;
    case Value::T::Bool: out += v.b ? "true" : "false"; break;
    case Value::T::Int: out += std::to_string(v.i); break;
    case Value::T::Real: {
        char buf[40];
        std::snprintf(buf, sizeof buf, "%.17g", v.d);
        out += buf;
        break;
    }
    case Value::T::Str: dump_string(out, v.s); break;
    case Value::T::Array: {
        if (v.arr.empty()) { out += "[]"; break; }
        out += pretty ? "[\n" : "[";
        for (size_t k = 0; k < v.arr.size(); ++k) {
            if (pretty) pad(indent + 1);
            dump_value(out, v.arr[k], pretty, indent + 1);
            if (k + 1 < v.arr.size()) out += pretty ? ",\n" : ",";
        }
        if (pretty) { out += "\n"; pad(indent); }
        out += "]";
        break;
    }
    case Value::T::Map: {
        if (v.map.empty()) { out += "{}"; break; }
        out += pretty ? "{\n" : "{";
        for (size_t k = 0; k < v.map.size(); ++k) {
            if (pretty) pad(indent + 1);
            dump_string(out, v.map[k].first);
            out += pretty ? ": " : ":";
            dump_value(out, v.map[k].second, pretty, indent + 1);
            if (k + 1 < v.map.size()) out += pretty ? ",\n" : ",";
        }
        if (pretty) { out += "\n"; pad(indent); }
        out += "}";
        break;
    }
    }
}

} // namespace

Value json_parse(const std::string& text) {
    JsonParser p(text);
    Value v = p.parse_value();
    p.skip_ws();
    return v;
}

std::string json_dump(const Value& v, bool pretty) {
    std::string out;
    dump_value(out, v, pretty, 0);
    return out;
}

// ── JSONPath subset ───────────────────────────────────────────────────────
const Value* json_path(const Value& root, const std::string& path) {
    std::string p = trim(path);
    while (!p.empty() && p[0] == '$') p.erase(p.begin());
    while (!p.empty() && (p[0] == '.' || p[0] == '[')) {
        if (p[0] == '[' && p.find(']') != std::string::npos && p[1] >= '0' && p[1] <= '9') break;
        p.erase(p.begin());
    }
    if (trim(p).empty()) return &root;
    const Value* current = &root;
    for (const std::string& part : split(p, '.')) {
        if (part.empty()) continue;
        std::string key = part;
        std::optional<size_t> index;
        size_t br = part.find('[');
        if (br != std::string::npos) {
            key = part.substr(0, br);
            size_t close = part.find(']', br);
            if (close != std::string::npos) {
                try { index = (size_t)std::stoul(part.substr(br + 1, close - br - 1)); }
                catch (...) { return nullptr; }
            }
        }
        if (!key.empty()) {
            if (!current->is_map()) return nullptr;
            current = current->get(key);
            if (!current) return nullptr;
        }
        if (index) {
            if (!current->is_array() || *index >= current->arr.size()) return nullptr;
            current = &current->arr[*index];
        }
    }
    return current;
}

std::optional<std::string> json_value_to_string(const Value& v) {
    switch (v.t) {
    case Value::T::Str: return v.s;
    case Value::T::Int: return std::to_string(v.i);
    case Value::T::Real: return to_str(v.d);
    case Value::T::Bool: return std::string(v.b ? "true" : "false");
    case Value::T::Null: return std::nullopt;
    default: return json_dump(v, false);
    }
}

std::optional<std::string> json_path_string(const Value& root, const std::string& path) {
    const Value* v = json_path(root, path);
    return v ? json_value_to_string(*v) : std::nullopt;
}

void value_merge(Value& base, const Value& overlay) {
    if (base.is_map() && overlay.is_map()) {
        for (auto& kv : overlay.map) {
            if (Value* slot = base.get_mut(kv.first)) value_merge(*slot, kv.second);
            else base.set(kv.first, kv.second);
        }
        return;
    }
    base = overlay;
}

} // namespace nc
