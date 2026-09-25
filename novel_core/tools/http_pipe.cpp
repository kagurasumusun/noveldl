/*
 * http_pipe.cpp — novel_core transport backed by the curl(1) CLI.
 *
 * Used by the CLI and the live download tests on hosts where libcurl
 * headers are unavailable.  Status and final URL come from curl -w;
 * response headers (incl. Set-Cookie) from -D; the body is stdout.
 */
#include "http_pipe.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <utility>
#include <string>
#include <vector>

namespace {

std::string shell_quote(const std::string& s) {
    std::string out = "'";
    for (char c : s) {
        if (c == '\'')
            out += "'\\''";
        else
            out += c;
    }
    out += "'";
    return out;
}

char* dup_n(const char* s, size_t n) {
    char* out = (char*)malloc(n + 1);
    if (!out) return nullptr;
    memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

} // namespace

extern "C" int nc_http_pipe_transport(const char* url,
                                      const char* const* header_keys,
                                      const char* const* header_values,
                                      size_t header_count,
                                      int timeout_secs,
                                      void* userdata,
                                      nc_http_response* out) {
    (void)userdata;
    if (!url || !out) return -1;
    memset(out, 0, sizeof(*out));

    std::string hdr_file = "/tmp/nc_pipe_hdr_";
    hdr_file += std::to_string((unsigned long)(uintptr_t)out);

    std::string cmd = "curl -sS -L --compressed --max-time ";
    cmd += std::to_string(timeout_secs > 0 ? timeout_secs : 30);
    // Single identity: dedupe headers (case-insensitive, first wins) and
    // send User-Agent via -A only, never as a duplicate -H.
    std::vector<std::pair<std::string, std::string>> hdrs;
    std::string ua;
    for (size_t i = 0; i < header_count; ++i) {
        if (!header_keys[i] || !header_values[i]) continue;
        std::string k = header_keys[i], v = header_values[i];
        std::string lk = k;
        for (auto& c : lk) c = (char)tolower((unsigned char)c);
        bool dup = false;
        for (auto& kv : hdrs) {
            if (kv.first == lk) { dup = true; break; }
        }
        if (dup) continue;
        if (lk == "user-agent") { if (ua.empty()) ua = v; continue; }
        hdrs.push_back({lk, k + ": " + v});
    }
    if (!ua.empty()) cmd += " -A " + shell_quote(ua);
    for (auto& kv : hdrs) cmd += " -H " + shell_quote(kv.second);
    cmd += " -D " + shell_quote(hdr_file);
    cmd += " -w '\\n@@NC_STATUS:%{http_code}\\n@@NC_URL:%{url_effective}'";
    cmd += " " + shell_quote(url) + " 2>/dev/null";

    if (std::getenv("NC_DUMP_CURL")) std::fprintf(stderr, "[curl] %s\n", cmd.c_str());
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) return -2;
    std::string out_all;
    char buf[16384];
    while (true) {
        size_t n = fread(buf, 1, sizeof buf, pipe);
        if (n == 0) break;
        out_all.append(buf, n);
    }
    pclose(pipe);

    int status = 0;
    std::string final_url;
    std::string body = out_all;
    size_t mark = body.rfind("\n@@NC_STATUS:");
    if (mark != std::string::npos) {
        body = body.substr(0, mark);
        std::string trailer = out_all.substr(mark);
        size_t sp = trailer.find("@@NC_STATUS:");
        if (sp != std::string::npos) status = atoi(trailer.c_str() + sp + 12);
        size_t fu = trailer.find("@@NC_URL:");
        if (fu != std::string::npos) {
            final_url = trailer.substr(fu + 9);
            while (!final_url.empty() && (final_url.back() == '\n' || final_url.back() == '\r'))
                final_url.pop_back();
        }
    }

    std::string cookies;
    if (FILE* hf = fopen(hdr_file.c_str(), "rb")) {
        std::string hdrs;
        while (true) {
            size_t n = fread(buf, 1, sizeof buf, hf);
            if (n == 0) break;
            hdrs.append(buf, n);
        }
        fclose(hf);
        remove(hdr_file.c_str());
        // keep Set-Cookie lines from every redirect hop
        size_t at = 0;
        while (true) {
            size_t nl = hdrs.find('\n', at);
            std::string line = hdrs.substr(at, nl == std::string::npos ? std::string::npos : nl - at);
            while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
            if (line.size() > 11) {
                std::string lower;
                for (char c : line) lower.push_back((char)tolower((unsigned char)c));
                if (lower.rfind("set-cookie:", 0) == 0) {
                    std::string val = line.substr(11);
                    while (!val.empty() && val.front() == ' ') val.erase(val.begin());
                    if (!cookies.empty()) cookies += "\n";
                    cookies += val;
                }
            }
            if (nl == std::string::npos) break;
            at = nl + 1;
        }
    }

    out->status = status;
    out->body = dup_n(body.data(), body.size());
    out->body_len = body.size();
    if (!final_url.empty()) out->final_url = dup_n(final_url.data(), final_url.size());
    if (!cookies.empty()) out->set_cookies = dup_n(cookies.data(), cookies.size());
    return 0;
}

extern "C" void nc_http_pipe_install(void) {
    novel_core_set_http_transport(nc_http_pipe_transport, nullptr);
}
