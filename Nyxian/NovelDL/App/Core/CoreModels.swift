import Foundation

// MARK: - Envelope

struct CoreEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let result: T?
    let error: String?
}

// MARK: - Library

struct LibraryNovelItem: Decodable, Identifiable, Hashable, Sendable {
    var id: String { novelId }
    let novelId: String
    let title: String
    let author: String
    let tocUrl: String
    let domain: String
    let episodeCount: Int
    let updatedAt: String?
    let outputDir: String
    let storagePath: String?
    let downloadedCount: Int?
}

struct LibraryListResult: Decodable, Sendable {
    let novels: [LibraryNovelItem]
    let downloadedCount: Int?
}

struct ChapterMeta: Decodable, Hashable, Sendable {
    let index: String
    let href: String
    let subtitle: String
    let chapter: String?
    let subupdate: String?
    let sortKey: Double?
    let bodyDownloaded: Bool?
    let updatedAt: String?
}

struct LibraryNovelInfo: Decodable, Hashable, Sendable {
    let novelId: String
    let title: String
    let author: String
    let domain: String?
    let outputDir: String?
    let episodeCount: Int
    /// あらすじ(追加時に取得保存されたもの)
    let description: String?
    /// 完結/連載中など(サイトのメタ情報・追加時に取得)
    let status: String?
    /// 次回更新予定
    let nextUpdate: String?
    /// コメント数など
    let commentCount: String?
    /// サイト側の更新日時表記
    let siteUpdated: String?
}

struct LibraryNovelDetail: Decodable, Sendable {
    let novel: LibraryNovelInfo
    let chapters: [ChapterMeta]
    let downloadedCount: Int
}

// MARK: - Download / TOC

struct DownloadResult: Decodable, Sendable {
    let saved: Int
    let updated: Int
    let skipped: Int
    let failed: Int
    let episodes: Int
    let novelId: String?
    let outputDir: String?
}

struct FetchTocResult: Decodable, Sendable {
    let novelId: String
    let title: String
    let author: String
    let episodes: Int
    let chapters: [ChapterMeta]
}

struct NovelInfoResult: Decodable, Sendable {
    let title: String
    let author: String
    let story: String?
    let episodes: Int
    let tocUrl: String?
}

struct ProgressSnapshot: Decodable, Sendable {
    let total: Int
    let done: Int
    let skipped: Int
    let failed: Int
    let running: Bool
    let current: String
}

// MARK: - Reader

struct SectionResult: Decodable, Sendable {
    let index: String
    let subtitle: String
    let introXhtml: String?
    let bodyXhtml: String?
    let postXhtml: String?
    let sourceUrl: String?
    let bodyDownloaded: Bool?
    let updatedAt: String?
}

// MARK: - Search

/// 検索状態を UserDefaults に保存して復元できるよう Encodable も矛盾させる。
struct SearchResultItem: Codable, Identifiable, Hashable, Sendable {
    var id: String { url }
    let title: String
    let url: String
    let detailUrl: String?
    let site: String?
    let siteKey: String?
    let author: String?
    let summary: String?
    let tags: [String]?
    let updated: String?
    let episodeCount: Int?
}

struct SearchSite: Decodable, Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let label: String
    let domains: [String]?
}

struct ExportResult: Decodable, Sendable {
    let zipPath: String
    let files: Int
    let missingBodies: Int?
}

struct RefreshResult: Decodable, Sendable {
    let refreshed: Int
    let failed: Int
}

struct TestSiteChapter: Decodable, Hashable, Sendable {
    let index: String
    let href: String
    let subtitle: String
}

struct TestSiteResult: Decodable, Sendable {
    let title: String
    let author: String?
    let episodes: Int
    let firstChapters: [TestSiteChapter]?
    let bodySample: String?
    let bodyError: String?
}
