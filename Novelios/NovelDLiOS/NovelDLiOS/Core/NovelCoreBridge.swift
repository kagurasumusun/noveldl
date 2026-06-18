import Foundation

private typealias NovelCoreProgressCallback = @convention(c) @Sendable (UnsafePointer<CChar>?) -> Void

@_silgen_name("novel_core_set_download_progress_callback")
private func novelCoreSetDownloadProgressCallback(_ callback: NovelCoreProgressCallback?)

private let novelCoreProgressCallback: NovelCoreProgressCallback = { pointer in
    NovelCoreBridge.handleDownloadProgressNotification(pointer)
}

public enum NovelCoreError: Error, LocalizedError {
    case decompressError(String)
    case downloadError(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .decompressError(let msg):  return "解凍エラー: \(msg)"
        case .downloadError(let msg):    return "ダウンロードエラー: \(msg)"
        case .operationFailed(let msg):  return "操作失敗: \(msg)"
        }
    }
}


public struct SupportedSearchSite: Codable, Identifiable, Hashable, Sendable {
    public let key: String
    public let label: String
    public let domains: [String]

    public var id: String { key }
    public var domainSummary: String { domains.joined(separator: ", ") }
}

public struct NovelSearchResultItem: Codable, Identifiable, Hashable, Sendable {
    public let title: String
    public let url: String
    public let detailUrl: String?
    public let site: String
    public let siteKey: String
    public let author: String?
    public let summary: String?
    public let tags: [String]
    public let updated: String?
    public let episodeCount: UInt32?

    enum CodingKeys: String, CodingKey {
        case title, url, site, author, summary, tags, updated
        case detailUrl = "detail_url"
        case siteKey = "site_key"
        case episodeCount = "episode_count"
    }

    public var id: String { url }
}

public struct NovelSearchPayload: Codable, Sendable {
    public let query: String
    public let sites: [String]
    public let results: [NovelSearchResultItem]
}

/// Parsed progress snapshot from novel_core_get_download_progress().
public struct DownloadProgress: Sendable {
    public let total:    Int
    public let done:     Int
    public let skipped:  Int
    public let failed:   Int
    public let running:  Bool
    public let current:  String

    public var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(completedCount) / Double(total)
    }

    public var statusText: String {
        guard total > 0 else { return running ? "準備中…" : "待機中" }
        let failedText = failed > 0 ? " / 失敗 \(failed)" : ""
        return "\(completedCount) / \(total) 話  (新規 \(done) / スキップ \(skipped)\(failedText))"
    }

    public var completedCount: Int {
        min(total, done + skipped + failed)
    }

    public var hasFailures: Bool { failed > 0 }
}

public enum NovelCoreBridge {// MARK: - Internal helpers

    private static func parseResult(_ result: String) -> (isSuccess: Bool, message: String) {
        if result.hasPrefix("OK:") {
            return (true, String(result.dropFirst(3)))
        } else if result.hasPrefix("ERR:") {
            return (false, String(result.dropFirst(4)))
        }
        return (false, result)
    }

    // MARK: - Existing API

    public static func callDecompressZstdFile(inputPath: String, outputPath: String) throws {
        let result = decompressZstdFile(inputPath: inputPath, outputPath: outputPath)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.decompressError(msg) }
    }

    public static func callSetRootDir(rootDir: String) throws {
        let result = setRootDir(rootDir: rootDir)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
    }

    public static func callDownloadFirstN(url: String, episodes: UInt32, outputDir: String) throws -> String {
        let result = downloadFirstN(url: url, episodes: episodes, outputDir: outputDir)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.downloadError(msg) }
        return msg
    }

    public static func callDownloadFirstNFromHtml(
        url: String,
        tocHtml: String,
        chaptersJson: String = "[]",
        episodes: UInt32,
        outputDir: String
    ) throws -> String {
        let result = downloadFirstNFromHtml(
            url: url,
            tocHtml: tocHtml,
            chaptersJson: chaptersJson,
            episodes: episodes,
            outputDir: outputDir
        )
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.downloadError(msg) }
        return msg
    }


    public static func callCreateLibraryPlaceholder(url: String, outputDir: String) throws -> String {
        let result = createLibraryPlaceholder(url: url, outputDir: outputDir)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
        return msg
    }

    public static func callFetchTocOnly(url: String, outputDir: String) throws -> String {
        let result = fetchTocOnly(url: url, outputDir: outputDir)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.downloadError(msg) }
        return msg
    }

    public static func callDownloadFromChapter(url: String, chapterIndex: String, outputDir: String) throws -> String {
        let result = downloadFromChapter(url: url, chapterIndex: chapterIndex, outputDir: outputDir)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.downloadError(msg) }
        return msg
    }

    public static func callDownloadCachedFromChapter(url: String, chapterIndex: String, outputDir: String) throws -> String {
        let result = downloadCachedFromChapter(url: url, chapterIndex: chapterIndex, outputDir: outputDir)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.downloadError(msg) }
        return msg
    }

    public static func callDownloadReaderCachedFromChapter(url: String, chapterIndex: String, outputDir: String) throws -> String {
        let result = downloadReaderCachedFromChapter(url: url, chapterIndex: chapterIndex, outputDir: outputDir)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.downloadError(msg) }
        return msg
    }

    public static func callCancelDownload() throws {
        let result = cancelDownload()
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
    }

    public static func callSetExtraCookie(domain: String, cookie: String) throws {
        guard !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let result = setExtraCookieForDomain(domain: domain, cookie: cookie)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
    }

    public static func callSetBrowserFetchCommand(_ command: String) throws {
        let result = setBrowserFetchCommand(command: command)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
    }

    public static func callSetDomainEngine(domain: String, engine: String) throws {
        let result = setDomainEngine(domain: domain, engine: engine)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
    }


    public static func callSaveUserParserYaml(domain: String, yaml: String) throws -> String {
        let result = saveUserParserYaml(domain: domain, yaml: yaml)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
        return msg
    }

    public static func callSaveUserWebnovelYaml(domain: String, yaml: String) throws -> String {
        let result = saveUserWebnovelYaml(domain: domain, yaml: yaml)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
        return msg
    }

    public static func callSearchNovels(query: String, limit: UInt32 = 30) throws -> NovelSearchPayload {
        let result = searchNovels(query: query, limit: limit)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
        guard let data = msg.data(using: String.Encoding.utf8) else {
            throw NovelCoreError.operationFailed("検索結果を UTF-8 として読めません")
        }
        return try JSONDecoder().decode(NovelSearchPayload.self, from: data)
    }

    public static func callSupportedSearchSites() throws -> [SupportedSearchSite] {
        let result = supportedSearchSites()
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
        guard let data = msg.data(using: String.Encoding.utf8) else {
            throw NovelCoreError.operationFailed("対応サイト一覧を UTF-8 として読めません")
        }
        return try JSONDecoder().decode([SupportedSearchSite].self, from: data)
    }

    // MARK: - New: in-memory zstd decompression

    /// Decompress a zstd blob and return the UTF-8 string content.
    public static func callDecompressZstdData(_ data: Data, dictionary: Data? = nil) throws -> String {
        let result: String
        if let dictionary, !dictionary.isEmpty {
            result = decompressZstdDataWithDictionary(data: data, dictionary: dictionary)
        } else {
            result = decompressZstdData(data: data)
        }
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.decompressError(msg) }
        return msg
    }

    /// Non-throwing variant; returns nil on failure (convenient for optional rendering).
    public static func tryDecompressZstdData(_ data: Data?, dictionary: Data? = nil) -> String? {
        guard let data else { return nil }
        let result: String
        if let dictionary, !dictionary.isEmpty {
            result = decompressZstdDataWithDictionary(data: data, dictionary: dictionary)
        } else {
            result = decompressZstdData(data: data)
        }
        guard result.hasPrefix("OK:") else { return nil }
        return String(result.dropFirst(3))
    }

    // MARK: - Downloaded novel discovery

    public static func callListDownloadedNovels(rootDir: String) -> String {
        listDownloadedNovels(rootDir: rootDir)
    }

    public static func callRefreshDownloadedTocs(rootDir: String) throws -> String {
        let result = refreshDownloadedTocs(rootDir: rootDir)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.downloadError(msg) }
        return msg
    }

    // MARK: - New: live download progress

    /// Poll current download progress from Rust.
    /// Format returned by Rust: "OK:<total>:<done>:<skipped>:<failed>:<running>:<current>"
    public static func callGetDownloadProgress() -> DownloadProgress {
        parseDownloadProgressResult(getDownloadProgress())
    }

    @MainActor
    public static func setDownloadProgressHandler(_ handler: @escaping @MainActor @Sendable (DownloadProgress) -> Void) {
        downloadProgressHandler = handler
        novelCoreSetDownloadProgressCallback(novelCoreProgressCallback)
    }

    fileprivate static func handleDownloadProgressNotification(_ pointer: UnsafePointer<CChar>?) {
        guard let pointer else { return }
        let snapshot = String(cString: pointer)
        let parsed = parseDownloadProgressResult(snapshot)
        Task { @MainActor in
            downloadProgressHandler?(parsed)
        }
    }

    @MainActor
    private static var downloadProgressHandler: (@MainActor @Sendable (DownloadProgress) -> Void)?

    private static func parseDownloadProgressResult(_ result: String) -> DownloadProgress {
        guard result.hasPrefix("OK:") else {
            return DownloadProgress(total: 0, done: 0, skipped: 0, failed: 0, running: false, current: "")
        }
        let body = String(result.dropFirst(3))
        let parts = body.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        let total = Int(parts.indices.contains(0) ? parts[0] : "0") ?? 0
        let done = Int(parts.indices.contains(1) ? parts[1] : "0") ?? 0
        let skipped = Int(parts.indices.contains(2) ? parts[2] : "0") ?? 0
        let failed = Int(parts.indices.contains(3) ? parts[3] : "0") ?? 0
        let running = (parts.indices.contains(4) ? parts[4] : "0") == "1"
        let current = parts.indices.contains(5) ? String(parts[5]) : ""
        return DownloadProgress(
            total: total,
            done: done,
            skipped: skipped,
            failed: failed,
            running: running,
            current: current
        )
    }

    public struct SiteTestResult: Codable {
        public let title: String
        public let author: String
        public let episode_count: Int
        public let first_episode_title: String?
    }

    public static func callTestSiteDefinition(url: String, yaml: String) async throws -> SiteTestResult {
        // Since this involves networking, it's better to wrap in Task if not already on a background thread,
        // but here we just call the FFI.
        let result = testSiteDefinition(url: url, yaml: yaml)
        let (ok, msg) = parseResult(result)
        if !ok { throw NovelCoreError.operationFailed(msg) }
        guard let data = msg.data(using: String.Encoding.utf8) else {
            throw NovelCoreError.operationFailed("テスト結果を UTF-8 として読めません")
        }
        return try JSONDecoder().decode(SiteTestResult.self, from: data)
    }
}
