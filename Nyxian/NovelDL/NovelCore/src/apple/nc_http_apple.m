/*
 * nc_http_apple.m — novel_core HTTP transport on NSURLSession.
 *
 * Blocking bridge: the core calls synchronously from its worker threads; we
 * run an ephemeral NSURLSession data task and wait on a semaphore.  Cookies
 * are reported back as set_cookies lines ("name=value; domain=..; path=/"),
 * the core stores them per domain and replays them via the Cookie header.
 */
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#include <stdlib.h>
#include <string.h>
#include "nc_http_apple.h"

/* ── scene-aware key window / navigation completion ──────────────────── */
#import <UIKit/UIKit.h>

/* 常に scene API だけを使う(iOS15+ で UIApplication.windows/keyWindow は
 * 非推奨、iOS17 SDK では deprecated 警告がエラー扱いになるため)。 */
static UIView* nc_apple_key_scene_view(void) {
  NSSet<UIScene*>* scenes = [UIApplication sharedApplication].connectedScenes;
  UIScene* pick = nil;
  for (UIScene* s in scenes)
    if (s.activationState == UISceneActivationStateForegroundActive) { pick = s; break; }
  if (!pick) pick = scenes.anyObject;
  if (![pick isKindOfClass:[UIWindowScene class]]) return nil;
  UIWindowScene* ws = (UIWindowScene*)pick;
  UIWindow* key = nil, *first = nil;
  for (UIWindow* w in ws.windows) {
    if (!first) first = w;
    if (w.isKeyWindow) { key = w; break; }
  }
  UIWindow* w = key ?: first;
  if (!w) return nil;
  return w.rootViewController.view ?: w;
}

/* WKWebView には completionHandler 付きロード API が無いため、delegate コールバック
 * をブロックで受ける最小プロキシ。 */
@interface NCHttpNavDelegate : NSObject <WKNavigationDelegate>
@property(copy) void (^onFinish)(WKNavigation*);
@property(copy) void (^onFail)(WKNavigation*, NSError*);
@end
@implementation NCHttpNavDelegate
- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation {
  (void)webView; if (self.onFinish) self.onFinish(navigation);
}
- (void)webView:(WKWebView*)webView didFailNavigation:(WKNavigation*)navigation
       withError:(NSError*)error {
  (void)webView; if (self.onFail) self.onFail(navigation, error);
}
@end

/* Challenge fallback (Akamai / Cloudflare 等): WKWebView で JS 実行つきで
 * 読み込み直し、発行されたクッキーを core の cookie ストアに返す。
 * 既定で有効。nc_http_apple_set_webview_fallback(NO) で止められる。 */
static BOOL g_webview_fallback = YES;
void nc_http_apple_set_webview_fallback(BOOL enabled) { g_webview_fallback = enabled; }

static char* nc_dup_cstr(const char* s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char* out = (char*)malloc(n);
    if (out) memcpy(out, s, n);
    return out;
}

static BOOL nc_looks_like_challenge(int status, NSData* data) {
    if (status == 403) return YES;
    if (!data || data.length == 0) return NO;
    NSUInteger len = MIN(data.length, (NSUInteger)20000);
    NSString* head = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, len)]
                                           encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString*>* marks = @[
        @"challenge-platform", @"cf-browser-verification", @"cf_chl_", @"just a moment",
        @"_Incapsula_Resource", @"incapsula", @"akamai", @"captcha", @"access denied",
        @"distil", @"bot detection", @"bot-detected", @"perimeterx", @"px-captcha",
        @"datadome", @"shape security",
    ];
    for (NSString* m in marks) {
        if ([head rangeOfString:m options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
    }
    return NO;
}

/* WKWebView で JS 実行つき取得。 challeng ページが自滅的に再読込するため、
 * didFinish 後に余裕を持って待ってから outerHTML とクッキーを回収する。 */
static NSString* nc_webview_fetch(NSURL* url, NSTimeInterval timeout,
                                  NSArray<NSHTTPCookie*>** outCookies) {
    /* main thread で semaphore 待ちするとデッドロックするため排除 */
    if ([[NSThread currentThread] isMainThread]) return nil;
    __block NSString* html = nil;
    __block NSArray<NSHTTPCookie*>* cookies = nil;
    __block dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      WKWebViewConfiguration* cfg = [[WKWebViewConfiguration alloc] init];
      cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
      WKWebView* wv = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 390, 1400)
                                         configuration:cfg];
      wv.hidden = YES;

      NSTimeInterval cap = timeout > 0 ? timeout + 18.0 : 40.0;
      /* host チェックより前に定義が必要なため block 変数で保持。
       * ブロック内から自分自身を触らないので retain cycle は無い。
       * 二重呼び出し時も signal は冪等扱い(待ち側は1回のため安全)。 */
      void (^finish)(NSString*) = ^(NSString* result) {
        html = result;
        [wv removeFromSuperview];
        dispatch_semaphore_signal(sem);
      };

      UIView* host = nc_apple_key_scene_view();
      if (!host) { finish(nil); return; }
      [host addSubview:wv];

      /* WKWebView に loadRequest:completionHandler: は存在しない。
       * navigation delegate(didFinish/didFail) を受けてから続行する。 */
      NCHttpNavDelegate* nav = [NCHttpNavDelegate new];
      nav.onFinish = ^(WKNavigation* n2) { (void)n2; };
      nav.onFail = ^(WKNavigation* n2, NSError* e2) { (void)n2; (void)e2; };
      wv.navigationDelegate = nav;
      [wv loadRequest:[NSURLRequest requestWithURL:url
                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                   timeoutInterval:timeout > 0 ? timeout : 30.0]];
      /* JS チャレンジの再読込が落ち着くまで待つ(didFinish 後に最低 2.8s) */
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(2.8 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
           [wv evaluateJavaScript:@"document.documentElement.outerHTML"
                completionHandler:^(id result, NSError* err) {
                  (void)err;
                  NSString* one = [result isKindOfClass:[NSString class]] ? result : nil;
                  [[WKWebsiteDataStore defaultDataStore].httpCookieStore
                      getAllCookies:^(NSArray<NSHTTPCookie*>* list) {
                        cookies = list;
                        if (one && nc_looks_like_challenge(0, [one dataUsingEncoding:NSUTF8StringEncoding])) {
                          /* まだチャレンジ中: 再挑戦して 1 回だけ待ち直す */
                          dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                       (int64_t)(4.5 * NSEC_PER_SEC)),
                                         dispatch_get_main_queue(), ^{
                            [wv evaluateJavaScript:@"document.documentElement.outerHTML"
                                 completionHandler:^(id r2, NSError* e2) {
                                   (void)e2;
                                   finish([r2 isKindOfClass:[NSString class]] ? r2 : one);
                                 }];
                          });
                        } else {
                          finish(one);
                        }
                      }];
                }]);
      });

      /* 安全弁: cap を過ぎたら諦める */
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(cap * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        if (!html) finish(nil);
      });
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_FOREVER,
                                               (int64_t)(50.0 * NSEC_PER_SEC)));
    if (outCookies) *outCookies = cookies;
    return html;
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

    /* bot 検証(challenge)っぽい応答は WKWebView で解決を試みる。
     * 成功したら HTML と、JS が発行したクッキーを core に渡す
     * (core がドメイン単位で保持し、以降の URLSession リクエストに
     *  Cookie ヘッダとして載せるため、2 発目からは素通りできる)。 */
    if (g_webview_fallback && !taskError &&
        nc_looks_like_challenge((int)status, bodyData) &&
        ![[NSThread currentThread] isMainThread]) {
        NSArray<NSHTTPCookie*>* wkCookies = nil;
        NSString* html = nc_webview_fetch(ns, timeout_secs > 0 ? timeout_secs : 30.0,
                                          &wkCookies);
        if (html.length > 0 &&
            !nc_looks_like_challenge(0, [html dataUsingEncoding:NSUTF8StringEncoding])) {
            bodyData = [html dataUsingEncoding:NSUTF8StringEncoding];
            status = 200;
            finalURL = ns;
            NSMutableArray* lines = [NSMutableArray array];
            for (NSHTTPCookie* c in wkCookies) {
                [lines addObject:[NSString stringWithFormat:@"%@=%@; domain=%@; path=%@",
                                              c.name, c.value, c.domain, c.path]];
                [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:c];
            }
            if (lines.count > 0) cookieLines = [lines componentsJoinedByString:@"\n"];
        }
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
