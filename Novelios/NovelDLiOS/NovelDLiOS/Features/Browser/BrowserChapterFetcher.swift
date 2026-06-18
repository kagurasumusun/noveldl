import Foundation
import WebKit

struct BrowserChapterHTML: Codable, Sendable {
    let index: String
    let href: String
    let subtitle: String
    let chapter: String?
    let subupdate: String?
    let html: String
}

@MainActor
final class BrowserChapterFetcher: NSObject, WKNavigationDelegate {
    private static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/18.0 Mobile/15E148 Safari/604.1"

    private let webView: WKWebView
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.limitsNavigationsToAppBoundDomains = false
        cfg.applicationNameForUserAgent = "NovelDLiOS"
        self.webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.customUserAgent = Self.mobileUA
        webView.navigationDelegate = self
    }

    func fetchHTML(urls: [URL]) async -> [URL: String] {
        var results: [URL: String] = [:]
        for url in urls {
            do {
                results[url] = try await fetchHTML(url: url)
            } catch {
                results[url] = nil
            }
        }
        return results
    }

    private func fetchHTML(url: URL) async throws -> String {
        continuation = nil
        timeoutTask?.cancel()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                await MainActor.run {
                    self?.finish(.failure(NSError(
                        domain: "NovelDL.BrowserChapterFetcher",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "ブラウザ本文取得がタイムアウトしました"]
                    )))
                }
            }
            self.webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 45))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captureHTMLWhenReady(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isNavigationCancellation(error) else { return }
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isNavigationCancellation(error) else { return }
        finish(.failure(error))
    }

    private func isNavigationCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func captureHTMLWhenReady(from webView: WKWebView) {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let html = result as? String, !html.isEmpty {
                    if Self.looksLikeChallenge(html) {
                        self.retryCaptureAfterChallengeDelay(webView)
                    } else {
                        self.finish(.success(html))
                    }
                } else {
                    self.finish(.failure(error ?? NSError(
                        domain: "NovelDL.BrowserChapterFetcher",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "ブラウザ本文HTMLが空でした"]
                    )))
                }
            }
        }
    }

    private func retryCaptureAfterChallengeDelay(_ webView: WKWebView) {
        Task { [weak self, weak webView] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                guard let self, let webView, self.continuation != nil else { return }
                self.captureHTMLWhenReady(from: webView)
            }
        }
    }

    private static func looksLikeChallenge(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("just a moment")
            || lower.contains("cf_chl")
            || lower.contains("cf-ray")
            || lower.contains("cloudflare") && lower.contains("challenge")
            || lower.contains("checking your browser")
            || lower.contains("enable javascript and cookies")
    }

    private func finish(_ result: Result<String, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let html): continuation.resume(returning: html)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

enum BrowserChapterPayloadBuilder {
    static func absoluteURL(base tocUrl: String, href: String) -> URL? {
        if let url = URL(string: href), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        guard var components = URLComponents(string: tocUrl) else { return nil }
        if !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        guard let baseURL = components.url else { return nil }
        return URL(string: href, relativeTo: baseURL)?.absoluteURL
    }

    static func encode(_ chapters: [BrowserChapterHTML]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(chapters)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
