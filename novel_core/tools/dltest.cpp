/*
 * dltest.cpp — live per-site download tests.
 *
 * For every supported site: fetch TOC, download up to N episodes, then read
 * the stored section back and validate it.  Prints a PASS/FAIL table.
 *
 *   ./build/novel_core_dltest [site-filter]
 */
#include "../include/novel_core.h"
#include "http_pipe.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

std::string g_json;
std::string g_filter;

std::string call(char* (*fn)()) {
    char* cstr = fn();
    std::string s = cstr ? cstr : "";
    if (cstr) novel_core_string_free(cstr);
    return s;
}

std::string call1(char* (*fn)(const char*), const std::string& a) {
    char* cstr = fn(a.c_str());
    std::string s = cstr ? cstr : "";
    if (cstr) novel_core_string_free(cstr);
    return s;
}

std::string call2(char* (*fn)(const char*, const char*), const std::string& a,
                  const std::string& b) {
    char* cstr = fn(a.c_str(), b.c_str());
    std::string s = cstr ? cstr : "";
    if (cstr) novel_core_string_free(cstr);
    return s;
}

std::string call3(char* (*fn)(const char*, const char*, const char*), const std::string& a,
                  const std::string& b, const std::string& c) {
    char* cstr = fn(a.c_str(), b.c_str(), c.c_str());
    std::string s = cstr ? cstr : "";
    if (cstr) novel_core_string_free(cstr);
    return s;
}

std::string json_str(const std::string& json, const std::string& key) {
    std::string pat = std::string(1, (char)34) + key + std::string(1, (char)34) + ":";
    size_t at = json.find(pat);
    if (at == std::string::npos) return "";
    at += pat.size();
    if (at < json.size() && json[at] == (char)34) ++at;  // skip opening quote
    size_t end = at;
    while (end < json.size() && json[end] != '"') {
        if (json[end] == '\\') ++end;
        ++end;
    }
    return json.substr(at, end - at);
}

bool json_ok(const std::string& json) {
    return json.find("\"ok\":true") != std::string::npos;
}

std::string json_int(const std::string& json, const std::string& key) {
    std::string pat = std::string(1, (char)34) + key + std::string(1, (char)34) + ":";
    size_t at = json.find(pat);
    if (at == std::string::npos) return "";
    at += pat.size();
    size_t end = at;
    while (end < json.size() && (isdigit((unsigned char)json[end]) || json[end] == '-')) ++end;
    return json.substr(at, end - at);
}

struct SiteTest {
    const char* site;
    const char* url;
    const char* note;
};

const SiteTest kSites[] = {
    {"narou", "https://ncode.syosetu.com/n0022gd/", "小説家になろう"},
    {"narou-r18", "https://novel18.syosetu.com/n2451kn/", "小説になろう(R-18/年齢制限)"},
    {"kakuyomu", "https://kakuyomu.jp/works/822139846234329769", "カクヨム"},
    {"hameln", "https://syosetu.org/novel/261939/", "ハーメルン"},
    {"novelup", "https://novelup.plus/story/805623797", "ノベルアップ＋"},
    {"akatsuki", "https://www.akatsuki-novels.com/stories/index/novel_id~10044", "暁"},
    {"no-ichigo", "https://www.no-ichigo.jp/book/n1179797", "野いちご"},
    {"novema", "https://novema.jp/book/n1640364", "ノベマ！"},
    {"berrys", "https://www.berrys-cafe.jp/book/n1777895", "berry's cafe"},
    {"solispia", "https://solispia.com/title/597", "ソリスピア"},
    {"sutekibungei", "https://sutekibungei.com/novels/3e1e7f05-cf51-4e00-84d1-6f2dc37fefe2",
     "ステキブンゲイ"},
    {"neopage", "https://www.neopage.com/book/344801882003007000", "ネオページ"},
    {"monogatary", "https://monogatary.com/story/88714", "monogatary.com"},
    {"aozora", "https://www.aozora.gr.jp/cards/000035/card1567.html", "青空文庫"},
    {"days", "https://novel.daysneo.com/works/6334ad91c5383b45831243333e2dbc30.html",
     "NOVEL DAYS"},
    {"alphapolis", "https://www.alphapolis.co.jp/novel/243223524/173169133",
     "アルファポリス(WAF)"},
    {"estar", "https://estar.jp/novels/26384598", "エブリスタ"},
};

struct SiteResult {
    std::string site, note, title, status, detail;
    bool pass = false;
};

SiteResult run_site(const SiteTest& t) {
    SiteResult r;
    r.site = t.site;
    r.note = t.note;

    std::string slug = t.site;
    std::string out_dir = std::string(g_json) + "/dl_" + slug;
    std::string out_dir_q = out_dir;
    for (auto& c : out_dir_q)
        if (c == '\\') c = '/';

    // 1) TOC
    std::string toc_opts =
        std::string("{\"url\":\"") + t.url + "\",\"output_dir\":\"" + out_dir_q + "\"}";
    char* toc_cstr = novel_core_fetch_toc(toc_opts.c_str());
    std::string toc_json = toc_cstr ? toc_cstr : "";
    if (toc_cstr) novel_core_string_free(toc_cstr);
    if (!json_ok(toc_json)) {
        r.status = "TOC-FAIL";
        r.detail = json_str(toc_json, "error");
        if (r.detail.empty()) r.detail = toc_json.substr(0, 120);
        return r;
    }
    r.title = json_str(toc_json, "title");
    std::string novel_id = json_str(toc_json, "novel_id");
    // episode count heuristic
    size_t chapters = 0, pos = 0;
    while ((pos = toc_json.find("\"href\"", pos)) != std::string::npos) {
        ++chapters;
        pos += 6;
    }
    r.detail = "episodes=" + std::to_string(chapters);
    if (chapters == 0) {
        r.status = "TOC-EMPTY";
        return r;
    }

    // 2) download first 2 episodes
    std::string dl_opts = std::string("{\"url\":\"") + t.url +
                          "\",\"output_dir\":\"" + out_dir_q +
                          "\",\"episodes\":2,\"from_index\":\"\",\"mode\":\"bulk\"}";
    char* dl_cstr = novel_core_download(dl_opts.c_str());
    std::string dl_json = dl_cstr ? dl_cstr : "";
    if (dl_cstr) novel_core_string_free(dl_cstr);
    if (!json_ok(dl_json)) {
        r.status = "DL-FAIL";
        r.detail += " | " + json_str(dl_json, "error");
        return r;
    }
    r.detail += " saved=" + json_int(dl_json, "saved") + " failed=" + json_int(dl_json, "failed");
    if (json_int(dl_json, "failed") != "0" && !json_int(dl_json, "failed").empty()) {
        size_t e = dl_json.find("failed_messages");
        if (e == std::string::npos) e = dl_json.find("error");
        if (e != std::string::npos) r.detail += " @" + dl_json.substr(e, 110);
    }

    // 3) read library + first section body
    char* lib_cstr = novel_core_library_list(g_json.c_str());
    std::string lib = lib_cstr ? lib_cstr : "";
    if (lib_cstr) novel_core_string_free(lib_cstr);
    if (lib.find(novel_id) == std::string::npos && !novel_id.empty()) {
        r.status = "LIB-MISS";
        return r;
    }
    // Inspect up to the first 3 TOC indexes — some episodes are paid/locked
    // previews whose bodies cannot be fetched; any real body counts.
    std::string body;
    std::string idx;
    {
        std::vector<std::string> idxs;
        size_t p0 = 0;
        while (idxs.size() < 3) {
            std::string pat = std::string(1, (char)34) + "index" + std::string(1, (char)34) + ":";
            size_t at = toc_json.find(pat, p0);
            if (at == std::string::npos) break;
            at += pat.size();
            if (at < toc_json.size() && toc_json[at] == (char)34) ++at;
            size_t end = at;
            while (end < toc_json.size() && toc_json[end] != (char)34) ++end;
            idxs.push_back(toc_json.substr(at, end - at));
            p0 = end;
        }
        for (auto& cand : idxs) {
            std::string sec = call3(novel_core_section_get, g_json, novel_id, cand);
            size_t body_at = sec.find("\"body_xhtml\":\"");
            if (body_at == std::string::npos) continue;
            std::string b = json_str(sec, "body_xhtml");
            if (!b.empty()) { body = b; idx = cand; break; }
        }
    }
    if (body.empty()) {
        r.status = "BODY-MISS";
        return r;
    }
    if (body.size() < 40) {
        r.status = "BODY-SHORT";
        r.detail += " body=" + std::to_string(body.size()) + "B";
        return r;
    }
    r.status = "PASS";
    r.pass = true;
    r.detail += " body=" + std::to_string(body.size()) + "B";
    return r;
}

} // namespace

int main(int argc, char** argv) {
    std::string root = "/tmp/noveldl_dltest";
    (void)system(("rm -rf " + root + " && mkdir -p " + root).c_str());
    g_json = root;
    if (argc > 1) g_filter = argv[1];

    nc_http_pipe_install();
    novel_core_set_download_interval_ms(1200);

    printf("== novel_core live download tests ==\n");
    int pass = 0, total = 0, skipped = 0;
    std::vector<SiteResult> rows;
    for (const SiteTest& t : kSites) {
        if (!g_filter.empty() && std::string(t.site).find(g_filter) == std::string::npos) {
            continue;
        }
        printf("-- %-13s %s\n", t.site, t.note);
        fflush(stdout);
        SiteResult r = run_site(t);
        ++total;
        if (r.pass) ++pass;
        printf("   [%s] %s | %s\n", r.status.c_str(), r.title.c_str(), r.detail.c_str());
        fflush(stdout);
        rows.push_back(r);
    }
    printf("\n== summary: %d/%d passed ==\n", pass, total);
    printf("%-14s %-10s %s\n", "site", "status", "detail");
    for (auto& r : rows)
        printf("%-14s %-10s %s\n", r.site.c_str(), r.status.c_str(), r.detail.c_str());
    (void)skipped;
    return pass == total ? 0 : 1;
}
