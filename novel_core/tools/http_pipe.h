/* http_pipe.h — curl(1) popen transport for environments without libcurl. */
#ifndef NC_HTTP_PIPE_H
#define NC_HTTP_PIPE_H

#include "../include/novel_core.h"

#ifdef __cplusplus
extern "C" {
#endif

int nc_http_pipe_transport(const char* url,
                           const char* const* header_keys,
                           const char* const* header_values,
                           size_t header_count,
                           int timeout_secs,
                           void* userdata,
                           nc_http_response* out);

void nc_http_pipe_install(void);

#ifdef __cplusplus
}
#endif

#endif
