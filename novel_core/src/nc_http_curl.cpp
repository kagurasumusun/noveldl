// nc_http_curl.cpp — libcurl transport (desktop / tests).  Compiled only when
// NC_HAVE_CURL is defined; iOS uses src/apple/nc_http_apple.m instead.
#ifdef NC_HAVE_CURL

#include "nc_http.h"

#include <curl/curl.h>
#include <mutex>

namespace nc {

namespace {
size_t write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    auto* out = (std::string*)userdata;
    out->append(ptr, size * nmemb);
    return size * nmemb;
}

struct CurlInit {
    CurlInit() { curl_global_init(CURL_GLOBAL_DEFAULT); }
};

void ensure_curl() {
    static CurlInit init;
    (void)init;
}
} // namespace

TransportFn builtin_curl_transport() {
    return [](const std::string& url,
              const std::vector<std::pair<std::string, std::string>>& headers,
              int timeout_secs) -> HttpResponse {
        ensure_curl();
        CURL* curl = curl_easy_init();
        if (!curl) throw Error("curl_easy_init failed");
        HttpResponse resp;
        resp.final_url = url;
        struct curl_slist* list = nullptr;
        for (auto& kv : headers) {
            std::string line = kv.first + ": " + kv.second;
            list = curl_slist_append(list, line.c_str());
        }
        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, list);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp.body);
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 10L);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, (long)timeout_secs);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 8L);
        curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
        char errbuf[CURL_ERROR_SIZE] = {0};
        curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, errbuf);
        CURLcode rc = curl_easy_perform(curl);
        if (rc != CURLE_OK) {
            std::string msg = errbuf[0] ? errbuf : curl_easy_strerror(rc);
            curl_slist_free_all(list);
            curl_easy_cleanup(curl);
            throw Error("network error: " + msg);
        }
        long status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        resp.status = (int)status;
        char* effective = nullptr;
        curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &effective);
        if (effective) resp.final_url = effective;
        curl_slist_free_all(list);
        curl_easy_cleanup(curl);
        return resp;
    };
}

// auto-register on first use
namespace {
struct AutoRegister {
    AutoRegister() {
        if (!has_transport()) set_transport(builtin_curl_transport());
    }
};
AutoRegister g_auto_register;
} // namespace

} // namespace nc

#endif // NC_HAVE_CURL
