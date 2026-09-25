/*
 * nc_http_apple.m — novel_core HTTP transport on NSURLSession.
 *
 * Blocking bridge: the core calls synchronously from its worker threads; we
 * run an ephemeral NSURLSession data task and wait on a semaphore.  Cookies
 * are reported back as set_cookies lines ("name=value; domain=..; path=/"),
 * the core stores them per domain and replays them via the Cookie header.
 */
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include "nc_http_apple.h"

static char* nc_dup_cstr(const char* s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char* out = (char*)malloc(n);
    if (out) memcpy(out, s, n);
    return out;
}

int nc_http_apple_transport(const char* url,
                            const char* const* header_keys,
                            const char* const* header_values,
                            size_t header_count,
                            int timeout_secs,
                            void* userdata,
                            nc_http_response* out) {
    (void)userdata;
    if (!url || !out) return -1;
    memset(out, 0, sizeof(*out));

    NSString* nsurl = [NSString stringWithUTF8String:url];
    NSURL* ns = [NSURL URLWithString:nsurl];
    if (!ns) return -2;

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:ns];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = timeout_secs > 0 ? (NSTimeInterval)timeout_secs : 30.0;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    for (size_t i = 0; i < header_count; ++i) {
        if (!header_keys[i] || !header_values[i]) continue;
        NSString* key = [NSString stringWithUTF8String:header_keys[i]];
        NSString* val = [NSString stringWithUTF8String:header_values[i]];
        [req setValue:val forHTTPHeaderField:key];
    }

    static NSURLSession* session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSURLSessionConfiguration* cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
      cfg.HTTPCookieStorage = nil; /* core owns the cookie store */
      cfg.URLCache = nil;
      cfg.HTTPAdditionalHeaders = @{};
      session = [NSURLSession sessionWithConfiguration:cfg];
    });

    __block NSData* bodyData = nil;
    __block NSURL* finalURL = nil;
    __block NSInteger status = 0;
    __block NSString* cookieLines = nil;
    __block NSError* taskError = nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask* task =
        [session dataTaskWithRequest:req
                   completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                     taskError = error;
                     if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                         NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
                         status = http.statusCode;
                         finalURL = http.URL;
                         NSDictionary* headers = http.allHeaderFields;
                         NSMutableArray* lines = [NSMutableArray array];
                         for (NSString* key in headers) {
                             if ([key caseInsensitiveCompare:@"Set-Cookie"] != NSOrderedSame) continue;
                             id value = headers[key];
                             NSArray* parts =
                                 [value isKindOfClass:[NSArray class]] ? value : @[ value ];
                             for (id one in parts) {
                                 if (![one isKindOfClass:[NSString class]]) continue;
                                 [lines addObject:(NSString*)one];
                             }
                         }
                         if (lines.count > 0) cookieLines = [lines componentsJoinedByString:@"\n"];
                     }
                     bodyData = data ?: [NSData data];
                     dispatch_semaphore_signal(sem);
                   }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (taskError && bodyData.length == 0) {
        /* transport-level failure: report status 0 so core surfaces the error */
        out->status = 0;
        out->body = nc_dup_cstr("");
        out->body_len = 0;
        return 0;
    }

    out->status = (int)status;
    size_t len = bodyData.length;
    char* body = (char*)malloc(len + 1);
    if (!body) return -3;
    if (len > 0) memcpy(body, bodyData.bytes, len);
    body[len] = '\0';
    out->body = body;
    out->body_len = len;
    if (finalURL) {
        NSString* fu = finalURL.absoluteString;
        if (fu) out->final_url = nc_dup_cstr(fu.UTF8String);
    }
    if (cookieLines) out->set_cookies = nc_dup_cstr(cookieLines.UTF8String);
    return 0;
}

void nc_http_apple_install(void) {
    novel_core_set_http_transport(nc_http_apple_transport, NULL);
}
