// cli.cpp — small command line front-end for manual verification.
// usage: novel_core_cli <command> [args...]
//   download <url> <out_dir> [episodes]
//   toc <url> <out_dir>
//   info <url>
//   library <root_dir>
//   novel <root_dir> <novel_id>
//   section <root_dir> <novel_id> <chapter_index>
//   export <root_dir> <novel_id>
//   search <query> [limit]
//   sites
//   test-site <url> <yaml-file>
#include "../include/novel_core.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>

namespace {

std::string slurp(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

void print(char* result) {
    std::puts(result ? result : "{\"ok\":false,\"error\":\"null\"}");
    novel_core_string_free(result);
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <command> ...\n", argv[0]);
        return 2;
    }
    std::string cmd = argv[1];
    if (cmd == "download" && argc >= 4) {
        std::string episodes = argc >= 5 ? argv[4] : "0";
        std::string json = std::string("{\"url\":\"") + argv[2] + "\",\"output_dir\":\"" +
                           argv[3] + "\",\"episodes\":" + episodes + "}";
        print(novel_core_download(json.c_str()));
    } else if (cmd == "toc" && argc >= 4) {
        std::string json = std::string("{\"url\":\"") + argv[2] + "\",\"output_dir\":\"" +
                           argv[3] + "\"}";
        print(novel_core_fetch_toc(json.c_str()));
    } else if (cmd == "info" && argc >= 3) {
        print(novel_core_novel_info(argv[2]));
    } else if (cmd == "library" && argc >= 3) {
        print(novel_core_library_list(argv[2]));
    } else if (cmd == "novel" && argc >= 4) {
        print(novel_core_library_novel(argv[2], argv[3]));
    } else if (cmd == "section" && argc >= 5) {
        print(novel_core_section_get(argv[2], argv[3], argv[4]));
    } else if (cmd == "export" && argc >= 4) {
        std::string json = std::string("{\"root_dir\":\"") + argv[2] +
                           "\",\"novel_id\":\"" + argv[3] + "\"}";
        print(novel_core_export_txt_zip(json.c_str()));
    } else if (cmd == "search" && argc >= 3) {
        print(novel_core_search(argv[2], argc >= 4 ? (uint32_t)atoi(argv[3]) : 40));
    } else if (cmd == "sites") {
        print(novel_core_search_sites());
    } else if (cmd == "test-site" && argc >= 4) {
        print(novel_core_test_site(argv[2], slurp(argv[3]).c_str()));
    } else if (cmd == "root" && argc >= 3) {
        print(novel_core_set_root_dir(argv[2]));
    } else {
        std::fprintf(stderr, "unknown command: %s\n", cmd.c_str());
        return 2;
    }
    return 0;
}
