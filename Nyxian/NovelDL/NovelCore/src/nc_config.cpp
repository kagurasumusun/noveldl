// nc_config.cpp — paths, preset store (extends resolution), global config.
// Replaces config_manager.rs + runtime.rs + extensions/platform.rs.
#include "nc_config.h"
#include "nc_rules.h"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace fs = std::filesystem;

namespace nc {
namespace config {

namespace {
std::string g_root_override;
std::string g_script_override;
} // namespace

std::string root_dir() {
    if (!g_root_override.empty()) return g_root_override;
    const char* env = std::getenv("NOVEL_CORE_ROOT_DIR");
    if (env && *env) return env;
    std::error_code ec;
    fs::path cwd = fs::current_path(ec);
    return ec ? "." : cwd.string();
}

void set_root_dir(const std::string& path) { g_root_override = path; }

std::string script_dir() {
    if (!g_script_override.empty()) return g_script_override;
    const char* env = std::getenv("NOVEL_CORE_SCRIPT_DIR");
    if (env && *env) return env;
#ifdef NOVEL_CORE_SCRIPT_DIR_DEFAULT
    return NOVEL_CORE_SCRIPT_DIR_DEFAULT;
#else
    return root_dir();
#endif
}

void set_script_dir(const std::string& path) { g_script_override = path; }

std::string tmp_dir() {
    const char* env = std::getenv("NOVEL_CORE_TMP_DIR");
    if (env && *env) return env;
    const char* tmp = std::getenv("TMPDIR");
    std::string base = (tmp && *tmp) ? tmp : "/tmp";
    std::string dir = base + "/novel_core/tmp";
    std::error_code ec;
    fs::create_directories(dir, ec);
    return ec ? root_dir() + "/.novel_core/tmp" : dir;
}

std::string user_presets_dir() { return root_dir() + "/presets"; }

namespace {
std::string read_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw Error("read failed: " + path);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

void write_file(const std::string& path, const std::string& data) {
    fs::path p(path);
    std::error_code ec;
    if (p.has_parent_path()) fs::create_directories(p.parent_path(), ec);
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) throw Error("write failed: " + path);
    out.write(data.data(), (std::streamsize)data.size());
}
} // namespace

Value resolve_extends(Value preset) {
    if (!preset.is_map()) return preset;
    const Value* ext = preset.get("extends");
    if (!ext || !ext->is_str() || ext->s.empty()) return preset;
    std::string ref = ext->s;
    // strip leading "common/" already included in key; kind = "parsers/common" or "parsers"
    std::string kind, name;
    size_t slash = ref.find('/');
    if (slash != std::string::npos) {
        kind = "parsers/" + ref.substr(0, slash);
        name = ref.substr(slash + 1);
    } else {
        kind = "parsers";
        name = ref;
    }
    std::optional<Value> base = load_builtin_preset(kind, name);
    if (!base) {
        // user overlay chain
        std::string path = user_presets_dir() + "/" + kind + "/" + name + ".yaml";
        std::error_code ec;
        if (fs::exists(path, ec)) base = yaml_parse(read_file(path));
    }
    if (!base) return preset;
    Value merged = resolve_extends(std::move(*base));
    Value overlay = preset;
    for (auto& kv : overlay.map) {
        if (kv.first == "extends") continue;
        merged.set(kv.first, kv.second);
    }
    return merged;
}

std::optional<Value> load_builtin_preset(const std::string& kind, const std::string& domain) {
    for (auto& bp : builtin_presets()) {
        if (kind == bp.kind && domain == bp.domain) {
            try {
                return yaml_parse(bp.yaml);
            } catch (...) {
                return std::nullopt;
            }
        }
    }
    return std::nullopt;
}

namespace {
void seed_one(const std::string& rel_path, const std::string& content) {
    std::string path = user_presets_dir() + "/" + rel_path;
    std::error_code ec;
    if (fs::exists(path, ec)) return;
    write_file(path, content);
}

bool copy_if_missing(const std::string& src, const std::string& dst) {
    std::error_code ec;
    if (fs::exists(dst, ec)) return false;
    if (!fs::exists(src, ec)) return false;
    fs::create_directories(fs::path(dst).parent_path(), ec);
    fs::copy_file(src, dst, ec);
    return !ec;
}
} // namespace

void seed_default_presets() {
    std::error_code ec;
    for (auto& bp : builtin_presets()) {
        std::string rel = std::string(bp.kind) + "/" + bp.domain + ".yaml";
        seed_one(rel, bp.yaml);
    }
    // also copy from <script_dir>/presets (keeps folder resource in sync)
    std::string src_root = script_dir() + "/presets";
    for (auto& bp : builtin_presets()) {
        std::string rel = std::string(bp.kind) + "/" + bp.domain + ".yaml";
        copy_if_missing(src_root + "/" + rel, user_presets_dir() + "/" + rel);
    }
}

Value load_effective_preset(const std::string& domain) {
    seed_default_presets();
    std::string parser_path = user_presets_dir() + "/parsers/" + domain + ".yaml";
    std::string site_path = user_presets_dir() + "/webnovel/" + domain + ".yaml";
    std::error_code ec;
    std::optional<Value> parser, site;
    if (fs::exists(parser_path, ec)) parser = yaml_parse(read_file(parser_path));
    if (fs::exists(site_path, ec)) site = yaml_parse(read_file(site_path));

    Value combined;
    if (parser && site) {
        combined = *parser;
        value_merge(combined, *site);
    } else if (parser) {
        combined = *parser;
    } else if (site) {
        combined = *site;
    } else if (auto builtin = load_builtin_preset("parsers", domain)) {
        combined = *builtin;
    } else {
        throw Error("parser preset not found for domain: " + domain);
    }
    combined = resolve_extends(std::move(combined));

    // 年齢制限サイト: confirm_over18 が真なら年齢クッキーを必ず送る。
    // クッキー名と値は over18_cookie: "name=value" でサイトごとに差し替え可
    // (省略時 "over18=yes" — なろうR-18/ハーメルン等の syosetu 系)。
    if (combined.get_bool("confirm_over18", false)) {
        std::string over18 = combined.get_str("over18_cookie", "over18=yes");
        std::string key = over18.substr(0, over18.find('=') + 1);
        Value cookies = Value::array();
        bool has = false;
        if (const Value* access = combined.get("access")) {
            if (const Value* c = access->get("cookies")) {
                for (const Value& item : c->arr) {
                    if (item.is_str() && item.as_str().compare(0, key.size(), key) == 0) {
                        cookies.push(Value::string(over18));
                        has = true;
                    } else {
                        cookies.push(item);
                    }
                }
            }
        }
        if (!has) cookies.push(Value::string(over18));
        Value new_access = Value::map_();
        if (const Value* access = combined.get("access")) new_access = *access;
        new_access.set("cookies", std::move(cookies));
        combined.set("access", std::move(new_access));
    }
    return RulesParser::normalize_legacy(std::move(combined));
}

Value save_user_preset(const std::string& kind, const std::string& domain, const Value& yaml) {
    if (domain.empty() || domain.find('/') != std::string::npos ||
        domain.find('\\') != std::string::npos)
        throw Error("invalid domain: " + domain);
    std::string dir = user_presets_dir() + "/" + kind;
    std::string path = dir + "/" + domain + ".yaml";
    write_file(path, yaml_dump(yaml));
    return yaml_parse(read_file(path)); // round-trip validates
}

bool delete_user_preset(const std::string& kind, const std::string& domain) {
    std::string path = user_presets_dir() + "/" + kind + "/" + domain + ".yaml";
    std::error_code ec;
    return fs::remove(path, ec);
}

Value list_presets() {
    seed_default_presets();
    Value out = Value::array();
    std::map<std::string, std::pair<bool, bool>> seen; // domain -> (builtin, user)
    for (auto& bp : builtin_presets()) {
        if (std::string(bp.kind) != "parsers") continue;
        seen[bp.domain].first = true;
    }
    std::error_code ec;
    for (const std::string kind : {"parsers", "webnovel"}) {
        std::string dir = user_presets_dir() + "/" + kind;
        if (!fs::exists(dir, ec)) continue;
        for (auto& entry : fs::directory_iterator(dir, ec)) {
            if (entry.path().extension() != ".yaml") continue;
            std::string domain = entry.path().stem().string();
            std::string content = read_file(entry.path().string());
            bool is_user = true;
            bool is_builtin = seen[domain].first;
            if (kind == std::string("parsers") && is_builtin) {
                // compare with builtin to tell user override
                auto builtin = load_builtin_preset("parsers", domain);
                if (builtin && yaml_dump(*builtin) == content) is_user = false;
            }
            seen[domain].first = seen[domain].first || (kind == std::string("parsers"));
            seen[domain].second = seen[domain].second || is_user;
        }
    }
    for (auto& kv : seen) {
        Value item = Value::map_();
        item.set("domain", Value::string(kv.first));
        item.set("source", Value::string(kv.second.second ? "user" : "builtin"));
        out.push(std::move(item));
    }
    // webnovel-only overlays
    if (fs::exists(user_presets_dir() + "/webnovel", ec)) {
        for (auto& entry : fs::directory_iterator(user_presets_dir() + "/webnovel", ec)) {
            if (entry.path().extension() != ".yaml") continue;
            std::string domain = entry.path().stem().string();
            bool dup = false;
            for (auto& item : out.arr)
                if (item.get_str("domain") == domain) dup = true;
            if (!dup) {
                Value item = Value::map_();
                item.set("domain", Value::string(domain));
                item.set("source", Value::string("user"));
                out.push(std::move(item));
            }
        }
    }
    Value root = Value::map_();
    root.set("presets", std::move(out));
    return root;
}

Value load_global_config() {
    std::string path = root_dir() + "/.novel_core/parser_config.yaml";
    std::error_code ec;
    if (!fs::exists(path, ec)) {
        Value def = Value::map_();
        def.set("default_engine", Value::string("yaml"));
        def.set("novels", Value::map_());
        def.set("domain_engines", Value::map_());
        save_global_config(def);
        return def;
    }
    try {
        return yaml_parse(read_file(path));
    } catch (...) {
        Value def = Value::map_();
        def.set("domain_engines", Value::map_());
        return def;
    }
}

void save_global_config(const Value& v) {
    write_file(root_dir() + "/.novel_core/parser_config.yaml", yaml_dump(v));
}

} // namespace config

} // namespace nc
