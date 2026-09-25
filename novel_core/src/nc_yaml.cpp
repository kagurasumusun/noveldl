// nc_yaml.cpp — YAML subset parser/emitter (serde_yaml Value compatibility).
//
// Supported: block maps / sequences with indentation, quoted & plain scalars,
// literal (|, |-) and folded (>, >-) block scalars, simple flow collections
// ({}, {a: 1}, [1, 2]), comments, booleans/null/numbers, multi-line plain
// scalars.  Anchors/aliases/tags are intentionally unsupported (unused by
// site presets).
#include "nc_value.h"

#include <cctype>
#include <cstdlib>
#include <cstring>

namespace nc {

namespace {

struct Line {
    size_t indent = 0;
    std::string content; // trimmed of indentation, comments stripped outside quotes
};

struct YamlParser {
    std::vector<Line> lines;
    size_t pos = 0;

    explicit YamlParser(const std::string& text) {
        std::string src = restore_newlines(text);
        std::vector<std::string> raw = split(src, '\n');
        for (size_t i = 0; i < raw.size(); ++i) {
            std::string line = raw[i];
            if (!line.empty() && line.back() == '\r') line.pop_back();
            size_t indent = 0;
            while (indent < line.size() && line[indent] == ' ') ++indent;
            // tabs in indentation are invalid in YAML; tolerate as spaces
            std::string content = line.substr(indent);
            if (content.empty()) continue;
            if (content[0] == '#') continue;
            if (content == "---" || content == "...") continue;
            size_t comment = find_comment(content);
            if (comment != std::string::npos) content = trim(content.substr(0, comment));
            if (content.empty()) continue;
            lines.push_back({indent, content});
        }
    }

    static size_t find_comment(const std::string& s) {
        char quote = 0;
        for (size_t i = 0; i < s.size(); ++i) {
            char c = s[i];
            if (quote) {
                if (quote == '"' && c == '\\') { ++i; continue; }
                if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' || c == '\'') { quote = c; continue; }
            if (c == '#' && (i == 0 || s[i - 1] == ' ' || s[i - 1] == '\t')) return i;
        }
        return std::string::npos;
    }

    [[noreturn]] void fail(const std::string& msg, size_t line) {
        throw Error("yaml: " + msg + " (line " + std::to_string(line + 1) + ")");
    }

    Value parse_document() {
        if (lines.empty()) return {};
        Value v = parse_node(lines[0].indent, 0);
        return v;
    }

    // parse node starting at `pos` with base indent
    Value parse_node(size_t indent, size_t depth) {
        if (depth > 64) throw Error("yaml: nesting too deep");
        if (pos >= lines.size()) return {};
        if (lines[pos].content.size() > 0 && lines[pos].content[0] == '-') {
            return parse_seq(indent, depth);
        }
        return parse_map(indent, depth);
    }

    Value parse_seq(size_t indent, size_t depth) {
        Value seq = Value::array();
        while (pos < lines.size() && lines[pos].indent == indent &&
               lines[pos].content[0] == '-') {
            std::string rest = lines[pos].content.substr(1);
            size_t sub_indent = indent + 1 + (lines[pos].content.size() - 1 - trim(rest).size());
            rest = trim(rest);
            if (rest.empty()) {
                ++pos;
                if (pos < lines.size() && lines[pos].indent > indent)
                    seq.push(parse_node(lines[pos].indent, depth + 1));
                else
                    seq.push(Value{});
                continue;
            }
            // inline: "- key: value" continues as map with indent of first key
            if (looks_like_map_entry(rest)) {
                // fold this line into a virtual map block
                Line virtual_line{sub_indent, rest};
                std::vector<Line> saved = std::move(lines);
                size_t saved_pos = pos;
                // rebuild lines: current entry + following deeper lines
                std::vector<Line> block;
                block.push_back(virtual_line);
                size_t consumed = 0;
                for (size_t i = saved_pos + 1; i < saved.size() && saved[i].indent >= sub_indent;
                     ++i) {
                    block.push_back(saved[i]);
                    ++consumed;
                }
                lines = std::move(block);
                pos = 0;
                Value map = parse_map(sub_indent, depth + 1);
                size_t used = pos;
                lines = std::move(saved);
                pos = saved_pos + (used > 0 ? used : 1);
                seq.push(std::move(map));
                continue;
            }
            ++pos;
            seq.push(parse_scalar_or_block(rest, indent, depth));
        }
        return seq;
    }

    Value parse_map(size_t indent, size_t depth) {
        Value map = Value::map_();
        while (pos < lines.size() && lines[pos].indent == indent &&
               lines[pos].content[0] != '-') {
            std::string content = lines[pos].content;
            std::string key;
            std::string rest;
            if (!split_key(content, key, rest)) {
                // plain multi-line continuation of previous scalar — shouldn't happen at map level
                fail("expected key", pos);
            }
            ++pos;
            Value value;
            if (rest == "|" || rest == "|-" || rest == ">" || rest == ">-" ||
                rest == "|+" || rest == ">+") {
                value = parse_block_scalar(rest, indent);
            } else if (!rest.empty()) {
                if (rest[0] == '[' || rest[0] == '{') {
                    value = parse_flow(rest);
                } else {
                    value = parse_inline_value(rest);
                }
            } else {
                if (pos < lines.size() && lines[pos].indent > indent) {
                    value = parse_node(lines[pos].indent, depth + 1);
                } else {
                    value = Value{};
                }
            }
            map.set(key, std::move(value));
        }
        return map;
    }

    static bool is_quoted(const std::string& s) {
        return s.size() >= 2 && ((s.front() == '"' && s.back() == '"') ||
                                (s.front() == '\'' && s.back() == '\''));
    }

    static bool looks_like_map_entry(const std::string& s) {
        if (s.empty() || s[0] == ' ') return false;
        if (s[0] == '"' || s[0] == '\'') {
            // quoted key
            size_t end = s.find(s[0] == '"' ? '"' : '\'', 1);
            if (end == std::string::npos) return false;
            return s.compare(end + 1, 1, ":") == 0;
        }
        if (s[0] == '{' || s[0] == '[') return false;
        // "key:" or "key: value" (colon followed by space or end)
        for (size_t i = 0; i < s.size(); ++i) {
            if (s[i] == '#' && i > 0 && s[i - 1] == ' ') break;
            if (s[i] == ':') {
                if (i + 1 == s.size()) return true;
                if (s[i + 1] == ' ') return true;
                return false;
            }
        }
        return false;
    }

    static bool split_key(const std::string& content, std::string& key, std::string& rest) {
        if (content.empty()) return false;
        if (content[0] == '"' || content[0] == '\'') {
            char q = content[0];
            for (size_t i = 1; i < content.size(); ++i) {
                if (q == '"' && content[i] == '\\') { ++i; continue; }
                if (content[i] == q) {
                    key = unquote(content.substr(0, i + 1));
                    size_t j = i + 1;
                    while (j < content.size() && content[j] == ' ') ++j;
                    if (j < content.size() && content[j] == ':') {
                        rest = trim(content.substr(j + 1));
                        return true;
                    }
                    return false;
                }
            }
            return false;
        }
        size_t colon = std::string::npos;
        for (size_t i = 0; i < content.size(); ++i) {
            if (content[i] == ':' && (i + 1 == content.size() || content[i + 1] == ' ')) {
                colon = i;
                break;
            }
        }
        if (colon == std::string::npos) return false;
        key = trim(content.substr(0, colon));
        rest = trim(content.substr(colon + 1));
        return !key.empty();
    }

    Value parse_block_scalar(const std::string& header, size_t indent) {
        bool literal = header[0] == '|' || header[0] == '+';
        bool keep = header.find('+') != std::string::npos;
        bool chomp_strip = header.find('-') != std::string::npos;
        std::vector<std::string> collected;
        size_t block_indent = 0;
        bool first = true;
        while (pos < lines.size() && lines[pos].indent > indent) {
            std::string raw = std::string(lines[pos].indent, ' ') + lines[pos].content;
            if (first) {
                block_indent = lines[pos].indent;
                first = false;
            }
            if (lines[pos].indent >= block_indent)
                collected.push_back(std::string(lines[pos].indent - block_indent, ' ') +
                                    lines[pos].content);
            else
                collected.push_back(lines[pos].content);
            ++pos;
        }
        std::string out;
        if (literal) {
            for (size_t k = 0; k < collected.size(); ++k) {
                out += collected[k];
                out += "\n";
            }
        } else {
            // folded: join lines with spaces, blank lines -> newline
            for (size_t k = 0; k < collected.size(); ++k) {
                if (k) {
                    if (collected[k].empty() || collected[k - 1].empty()) out += "\n";
                    else out += " ";
                }
                out += collected[k];
            }
            if (!collected.empty()) out += "\n";
        }
        if (chomp_strip) {
            while (!out.empty() && out.back() == '\n') out.pop_back();
        } else if (!keep) {
            // single trailing newline (clip)
            while (out.size() >= 2 && out[out.size() - 1] == '\n' && out[out.size() - 2] == '\n')
                out.pop_back();
        }
        return Value::string(out);
    }

    Value parse_scalar_or_block(const std::string& s, size_t indent, size_t depth) {
        if (s == "|" || s == "|-" || s == ">" || s == ">-" || s == "|+" || s == ">+")
            return parse_block_scalar(s, indent);
        if (!s.empty() && (s[0] == '{' || s[0] == '[')) return parse_flow(s);
        return parse_inline_value(s);
    }

    static std::string unquote(const std::string& s) {
        if (s.size() < 2) return s;
        char q = s[0];
        if (s.back() != q) return s;
        std::string body = s.substr(1, s.size() - 2);
        if (q == '\'') return replace_all(body, "''", "'");
        std::string out;
        for (size_t i = 0; i < body.size(); ++i) {
            if (body[i] == '\\' && i + 1 < body.size()) {
                char e = body[++i];
                switch (e) {
                case 'n': out.push_back('\n'); break;
                case 't': out.push_back('\t'); break;
                case 'r': out.push_back('\r'); break;
                case '0': out.push_back('\0'); break;
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'u': {
                    std::string hex = body.substr(i + 1, 4);
                    i += 4;
                    long cp = std::stol(hex, nullptr, 16);
                    if (cp < 0x80) out.push_back((char)cp);
                    else if (cp < 0x800) {
                        out.push_back((char)(0xC0 | (cp >> 6)));
                        out.push_back((char)(0x80 | (cp & 0x3F)));
                    } else {
                        out.push_back((char)(0xE0 | (cp >> 12)));
                        out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
                        out.push_back((char)(0x80 | (cp & 0x3F)));
                    }
                    break;
                }
                default: out.push_back(e);
                }
            } else {
                out.push_back(body[i]);
            }
        }
        return out;
    }

    Value parse_inline_value(const std::string& s) {
        if (s.empty()) return {};
        if (is_quoted(s)) return Value::string(unquote(s));
        std::string v = trim(s);
        if (v == "~" || v == "null" || v == "Null" || v == "NULL") return {};
        std::string lv = lower(v);
        if (lv == "true" || lv == "yes" || lv == "on") return Value::boolean(true);
        if (lv == "false" || lv == "no" || lv == "off") return Value::boolean(false);
        // number?
        {
            const char* c = v.c_str();
            char* end = nullptr;
            long long iv = std::strtoll(c, &end, 10);
            if (end && *end == '\0' && !v.empty() && v.find_first_not_of("0123456789-+") == std::string::npos)
                return Value::integer(iv);
            double dv = std::strtod(c, &end);
            if (end && *end == '\0' && v.find_first_not_of("0123456789+-.eE") == std::string::npos &&
                v.find('.') != std::string::npos)
                return Value::real(dv);
        }
        return Value::string(v);
    }

    Value parse_flow(const std::string& s) {
        size_t i = 0;
        Value v = parse_flow_value(s, i);
        return v;
    }

    Value parse_flow_value(const std::string& s, size_t& i) {
        skip_flow_ws(s, i);
        if (i >= s.size()) return {};
        if (s[i] == '{') {
            ++i;
            Value map = Value::map_();
            skip_flow_ws(s, i);
            if (i < s.size() && s[i] == '}') { ++i; return map; }
            while (i < s.size()) {
                skip_flow_ws(s, i);
                std::string key = parse_flow_scalar_raw(s, i, ":,}");
                skip_flow_ws(s, i);
                if (i < s.size() && s[i] == ':') ++i;
                map.set(trim(key), parse_flow_value(s, i));
                skip_flow_ws(s, i);
                if (i < s.size() && s[i] == ',') { ++i; continue; }
                if (i < s.size() && s[i] == '}') { ++i; break; }
                break;
            }
            return map;
        }
        if (s[i] == '[') {
            ++i;
            Value arr = Value::array();
            skip_flow_ws(s, i);
            if (i < s.size() && s[i] == ']') { ++i; return arr; }
            while (i < s.size()) {
                arr.push(parse_flow_value(s, i));
                skip_flow_ws(s, i);
                if (i < s.size() && s[i] == ',') { ++i; continue; }
                if (i < s.size() && s[i] == ']') { ++i; break; }
                break;
            }
            return arr;
        }
        std::string raw = parse_flow_scalar_raw(s, i, ",]}");
        return parse_inline_value(trim(raw));
    }

    static void skip_flow_ws(const std::string& s, size_t& i) {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) ++i;
    }

    static std::string parse_flow_scalar_raw(const std::string& s, size_t& i,
                                             const char* stops) {
        skip_flow_ws(s, i);
        if (i < s.size() && (s[i] == '"' || s[i] == '\'')) {
            char q = s[i];
            size_t start = i;
            ++i;
            while (i < s.size()) {
                if (q == '"' && s[i] == '\\') { i += 2; continue; }
                if (s[i] == q) {
                    if (q == '\'' && i + 1 < s.size() && s[i + 1] == '\'') { i += 2; continue; }
                    ++i;
                    break;
                }
                ++i;
            }
            return s.substr(start, i - start);
        }
        size_t start = i;
        while (i < s.size() && std::strchr(stops, s[i]) == nullptr) ++i;
        return s.substr(start, i - start);
    }
};

// ── emitter (for saving config / test output) ─────────────────────────────
void emit_value(std::string& out, const Value& v, int indent) {
    std::string pad((size_t)indent * 2, ' ');
    switch (v.t) {
    case Value::T::Null: out += "null\n"; break;
    case Value::T::Bool: out += v.b ? "true\n" : "false\n"; break;
    case Value::T::Int: out += std::to_string(v.i) + "\n"; break;
    case Value::T::Real: out += to_str(v.d) + "\n"; break;
    case Value::T::Str: {
        std::string s = v.s;
        bool multiline = s.find('\n') != std::string::npos;
        if (multiline) {
            out += "|-\n";
            for (const std::string& line : split(s, '\n')) {
                out += pad + "  " + line + "\n";
            }
        } else {
            bool need_quote = s.empty() || s.front() == ' ' || s.back() == ' ' ||
                              s.find(':') != std::string::npos ||
                              s.find('#') != std::string::npos ||
                              s.find_first_of("'\"{}[]|>*&!%@`,") != std::string::npos ||
                              lower(s) == "true" || lower(s) == "false" ||
                              lower(s) == "null" || lower(s) == "yes" || lower(s) == "no";
            if (need_quote) {
                std::string q = replace_all(s, "\\", "\\\\");
                q = replace_all(q, "\"", "\\\"");
                q = replace_all(q, "\n", "\\n");
                out += "\"" + q + "\"\n";
            } else {
                out += s + "\n";
            }
        }
        break;
    }
    case Value::T::Array: {
        if (v.arr.empty()) { out += "[]\n"; break; }
        out += "\n";
        for (const Value& item : v.arr) {
            out += pad + "- ";
            std::string piece;
            if (item.is_map() || (item.is_array() && item.size() > 0)) {
                // inline first level
                std::string tmp;
                emit_value(tmp, item, indent + 1);
                // re-indent: replace "\n" + pad of indent+1 with same-line form
                tmp = trim(tmp);
                out += tmp + "\n";
            } else {
                emit_value(piece, item, 0);
                out += trim(piece) + "\n";
            }
        }
        break;
    }
    case Value::T::Map: {
        if (v.map.empty()) { out += "{}\n"; break; }
        out += "\n";
        for (const auto& kv : v.map) {
            std::string key = kv.first;
            if (key.find_first_of(": #") != std::string::npos)
                key = "\"" + replace_all(key, "\"", "\\\"") + "\"";
            out += pad + key + ":";
            if (kv.second.is_map() && kv.second.map.empty()) { out += " {}\n"; continue; }
            if (kv.second.is_array() && kv.second.arr.empty()) { out += " []\n"; continue; }
            if (kv.second.is_map() || kv.second.is_array()) {
                out += "\n";
                std::string piece;
                emit_value(piece, kv.second, indent + 1);
                out += piece;
            } else {
                out += " ";
                std::string piece;
                emit_value(piece, kv.second, 0);
                out += piece;
            }
        }
        break;
    }
    }
}

} // namespace

// public entry points (declared in nc_value? use nc_common-level API)
Value yaml_parse(const std::string& text);
std::string yaml_dump(const Value& v);

Value yaml_parse(const std::string& text) {
    YamlParser p(text);
    Value v = p.parse_document();
    return v;
}

std::string yaml_dump(const Value& v) {
    std::string out;
    emit_value(out, v, 0);
    // top-level scalars emit trailing newline already; trim map/array header blank
    if (starts_with(out, "\n")) out.erase(out.begin());
    return out;
}

} // namespace nc
