/* NSURLSession-backed HTTP transport for novel_core (iOS/macOS). */
#ifndef NC_HTTP_APPLE_H
#define NC_HTTP_APPLE_H

#include "../../include/novel_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Raw transport entry (synchronous, semaphore-backed NSURLSession). */
int nc_http_apple_transport(const char* url,
                            const char* const* header_keys,
                            const char* const* header_values,
                            size_t header_count,
                            int timeout_secs,
                            void* userdata,
                            nc_http_response* out);

/* Convenience: novel_core_set_http_transport(nc_http_apple_transport, NULL). */
void nc_http_apple_install(void);

/* Enable/disable the WKWebView challenge fallback (default: enabled). */
void nc_http_apple_set_webview_fallback(BOOL enabled);

#ifdef __cplusplus
}
#endif

#endif /* NC_HTTP_APPLE_H */
