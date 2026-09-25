// nc_http.h — HTTP fetch layer: browser-like profiles, cookie jar, retries,
// challenge detection and browser-fetch fallback.  Transport is pluggable
// (libcurl on desktop, NSURLSession on iOS, or any host-registered callback).
#pragma once

#include "nc_common.h"
#include "nc_rules.h" // AccessSettings

#include <functional>

namespace nc {

struct HttpResponse {
    int status = 0;
    std::string body;
    std::string final_url;
    // newline-separated "name=value; domain=...; path=/" (optional)
    std::string set_cookies;
};

// transport: (url, headers, timeout) -> response.  Throw Error on network fail.
using TransportFn = std::function<HttpResponse(
    const std::string& url, const std::vector<std::pair<std::string, std::string>>& headers,
    int timeout_secs)>;

void set_transport(TransportFn fn);
bool has_transport();

class HttpClient {
public:
    // fetch with retry / profile fallback / browser fallback.
    std::string fetch(const std::string& url,
                      const std::optional<AccessSettings>& access = std::nullopt,
                      const std::optional<std::string>& referer_url = std::nullopt);

    static void set_extra_cookie(const std::string& domain, const std::string& cookie);
    static void set_browser_fetch_command(const std::string& command);
    static void clear_caches();
};

// profile names -> user agent
std::string profile_user_agent(const std::string& profile);

} // namespace nc
