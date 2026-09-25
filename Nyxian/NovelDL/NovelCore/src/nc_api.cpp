// nc_api.cpp — public C ABI (include/novel_core.h).
// Consolidates the former ffi.rs + uniffi_api.rs + novel_core.udl surfaces.
#include "../include/novel_core.h"

#include "nc_config.h"
#include "nc_download.h"
#include "nc_http.h"
#include "nc_rules.h"
#include "nc_search.h"
#include "nc_storage.h"
#include "nc_value.h"

#include <cstdlib>
#include <cstring>
#include <string>

using namespace nc;

namespace {

char* cstring(const std::string& s) {
    char* p = (char*)std::malloc(s.size() + 1);
    if (!p) return nullptr;
    std::memcpy(p, s.data(), s.size());
    p[s.size()] = 0;
    return p;
}

char* ok(Value result) {
    Value v = Value::map_();
    v.set("ok", Value::boolean(true));
    v.set("result", std::move(result));
    return cstring(json_dump(v));
}

char* err(const std::string& message) {
    Value v = Value::map_();
    v.set("ok", Value::boolean(false));
    v.set("error", Value::string(message));
    return cstring(json_dump(v));
}

char* guarded(const std::function<Value()>& fn) {
    try {
        return ok(fn());
    } catch (const std::exception& e) {
        return err(e.what());
    } catch (...) {
        return err("unknown error");
    }
}

} // namespace

extern "C" {

void* novel_core_alloc(size_t size) { return std::malloc(size); }
void novel_core_free(void* ptr) { std::free(ptr); }
void novel_core_string_free(char* ptr) { std::free(ptr); }

void novel_core_set_http_transport(nc_http_transport_fn fn, void* userdata) {
    if (!fn) {
        set_transport(nullptr);
        return;
    }
    set_transport([fn, userdata](const std::string& url,
                                 const std::vector<std::pair<std::string, std::string>>& headers,
                                 int timeout) -> HttpResponse {
        std::vector<const char*> keys, values;
        for (auto& kv : headers) {
            keys.push_back(kv.first.c_str());
            values.push_back(kv.second.c_str());
        }
        nc_http_response raw{};
        int rc = fn(url.c_str(), keys.data(), values.data(), keys.size(), timeout, userdata, &raw);
        if (rc != 0) throw Error("network error (transport rc=" + std::to_string(rc) + ")");
        HttpResponse resp;
        resp.status = raw.status;
        if (raw.body) {
            resp.body.assign(raw.body, raw.body_len);
            std::free(raw.body);
        }
        if (raw.final_url) {
            resp.final_url = raw.final_url;
            std::free(raw.final_url);
        }
        if (raw.set_cookies) {
            resp.set_cookies = raw.set_cookies;
            // replay captured Set-Cookie lines into the per-domain cookie jar
            std::string host = url.substr(0, url.find('/'));
            size_t scheme = host.find("://");
            if (scheme != std::string::npos) host = host.substr(scheme + 3);
            host = host.substr(0, host.find(':'));
            std::string lines = raw.set_cookies;
            size_t at = 0;
            while (at <= lines.size()) {
                size_t nl = lines.find('\n', at);
                std::string line = lines.substr(at, nl == std::string::npos ? std::string::npos : nl - at);
                if (!line.empty()) {
                    std::string domain = host;
                    std::string lower_line;
                    for (char c : line) lower_line.push_back((char)tolower((unsigned char)c));
                    size_t d = lower_line.find("domain=");
                    if (d != std::string::npos) {
                        size_t start = d + 7;
                        if (start < line.size() && line[start] == '.') ++start;
                        size_t end = line.find(';', start);
                        domain = line.substr(start, end == std::string::npos ? std::string::npos : end - start);
                    }
                    size_t semi = line.find(';');
                    HttpClient::set_extra_cookie(domain,
                                                 line.substr(0, semi == std::string::npos ? std::string::npos : semi));
                }
                if (nl == std::string::npos) break;
                at = nl + 1;
            }
            std::free(raw.set_cookies);
        }
        return resp;
    });
}

void novel_core_set_progress_callback(novel_core_progress_fn fn, void* userdata) {
    progress_set_callback(fn, userdata);
}

char* novel_core_progress(void) {
    return guarded([]() { return progress_snapshot().to_json(); });
}

void novel_core_cancel(void) { cancel_request(); }

char* novel_core_download(const char* options_json) {
    return guarded([&]() {
        if (!options_json) throw Error("options_json is null");
        return op_download(DownloadOptions::from_json(json_parse(options_json)));
    });
}

char* novel_core_fetch_toc(const char* options_json) {
    return guarded([&]() {
        if (!options_json) throw Error("options_json is null");
        return op_fetch_toc(DownloadOptions::from_json(json_parse(options_json)));
    });
}

char* novel_core_novel_info(const char* url) {
    return guarded([&]() {
        if (!url) throw Error("url is null");
        return op_novel_info(url);
    });
}

char* novel_core_test_site(const char* url, const char* yaml) {
    return guarded([&]() {
        if (!url || !yaml) throw Error("url/yaml is null");
        return op_test_site(url, yaml);
    });
}

char* novel_core_library_list(const char* root_dir) {
    return guarded([&]() {
        std::string root = root_dir && *root_dir ? root_dir : config::root_dir();
        return op_library_list(root);
    });
}

char* novel_core_library_novel(const char* root_dir, const char* novel_id) {
    return guarded([&]() {
        if (!novel_id) throw Error("novel_id is null");
        std::string root = root_dir && *root_dir ? root_dir : config::root_dir();
        return op_library_novel(root, novel_id);
    });
}

char* novel_core_library_refresh(const char* root_dir) {
    return guarded([&]() {
        std::string root = root_dir && *root_dir ? root_dir : config::root_dir();
        return op_library_refresh(root);
    });
}

char* novel_core_section_get(const char* root_dir, const char* novel_id,
                             const char* chapter_index) {
    return guarded([&]() {
        if (!novel_id || !chapter_index) throw Error("novel_id/chapter_index is null");
        std::string root = root_dir && *root_dir ? root_dir : config::root_dir();
        return op_section_get(root, novel_id, chapter_index);
    });
}

char* novel_core_export_txt_zip(const char* options_json) {
    return guarded([&]() {
        Value options = options_json ? json_parse(options_json) : Value::map_();
        return op_export_txt_zip(options);
    });
}

char* novel_core_search(const char* query, uint32_t limit) {
    return guarded([&]() {
        // クエリ中の site:xxx で検索範囲を絞れる(novel_core_search_ex も参照)。
        return search_novels(query ? query : "", (int)limit);
    });
}

char* novel_core_search_sites(void) {
    return guarded([]() { return search_supported_sites(); });
}

char* novel_core_set_root_dir(const char* path) {
    return guarded([&]() {
        if (!path) throw Error("path is null");
        config::set_root_dir(path);
        Value v = Value::map_();
        v.set("root_dir", Value::string(config::root_dir()));
        return v;
    });
}

char* novel_core_set_script_dir(const char* path) {
    return guarded([&]() {
        if (!path) throw Error("path is null");
        config::set_script_dir(path);
        Value v = Value::map_();
        v.set("script_dir", Value::string(config::script_dir()));
        return v;
    });
}

void novel_core_set_download_interval_ms(uint32_t ms) {
    setenv("NOVELDL_DOWNLOAD_INTERVAL_MS", std::to_string(ms).c_str(), 1);
}

char* novel_core_save_parser_yaml(const char* domain, const char* yaml) {
    return guarded([&]() {
        if (!domain || !yaml) throw Error("domain/yaml is null");
        Value parsed = yaml_parse(yaml); // validate
        Value saved = config::save_user_preset("parsers", domain, parsed);
        Value v = Value::map_();
        v.set("domain", Value::string(domain));
        v.set("yaml", Value::string(yaml_dump(saved)));
        return v;
    });
}

char* novel_core_section_version_get(const char* root_dir, const char* novel_id,
                                     const char* chapter_index, int32_t offset) {
    return guarded([&]() {
        if (!root_dir || !novel_id || !chapter_index) throw Error("null argument");
        std::string root = root_dir && *root_dir ? root_dir : config::root_dir();
        return op_section_version_get(root, novel_id, chapter_index, offset);
    });
}

char* novel_core_load_parser_yaml(const char* domain) {
    return guarded([&]() {
        if (!domain) throw Error("domain is null");
        Value preset = config::load_effective_preset(domain);
        Value v = Value::map_();
        v.set("domain", Value::string(domain));
        v.set("yaml", Value::string(yaml_dump(preset)));
        return v;
    });
}

char* novel_core_list_parser_yamls(void) {
    return guarded([]() { return config::list_presets(); });
}

char* novel_core_delete_parser_yaml(const char* domain) {
    return guarded([&]() {
        if (!domain) throw Error("domain is null");
        bool removed = config::delete_user_preset("parsers", domain);
        config::delete_user_preset("webnovel", domain);
        HttpClient::clear_caches();
        Value v = Value::map_();
        v.set("removed", Value::boolean(removed));
        return v;
    });
}

void novel_core_set_domain_cookie(const char* domain, const char* cookie) {
    if (domain && cookie) HttpClient::set_extra_cookie(domain, cookie);
}

void novel_core_set_browser_fetch_command(const char* command) {
    HttpClient::set_browser_fetch_command(command ? command : "");
}

char* novel_core_decompress_zstd(const uint8_t* data, size_t len) {
    return guarded([&]() {
        if (!data || len == 0) throw Error("empty input");
        return Value::string(decompress_zstd_str(std::string((const char*)data, len)));
    });
}

char* novel_core_decompress_zstd_dict(const uint8_t* data, size_t len, const uint8_t* dict,
                                      size_t dict_len) {
    return guarded([&]() {
        if (!data || len == 0) throw Error("empty input");
        std::string dictionary(dict && dict_len ? (const char*)dict : nullptr,
                               dict && dict_len ? dict_len : 0);
        return Value::string(decompress_zstd_dict(std::string((const char*)data, len), dictionary));
    });
}

} // extern "C"
