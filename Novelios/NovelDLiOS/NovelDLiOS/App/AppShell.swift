import SwiftUI
import UIKit
import GRDB

// MARK: - App shell

private final class DownloadBackgroundLease: @unchecked Sendable {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    @MainActor
    func begin(named name: String) {
        end()
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor [weak self] in
                self?.end()
            }
        }
    }

    @MainActor
    func end() {
        guard identifier != .invalid else { return }
        let task = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    deinit {
        let task = identifier
        guard task != .invalid else { return }
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}

private struct ReaderSettingsSnapshot: Codable {
    var fontSize: Double
    var lineSpacing: Double
    var readerMargin: Double
    var readerBrightness: Double
    var readerDarkTheme: Bool
    var showImages: Bool
    var rtl: Bool
    var readerFontName: String
    var readerFullscreen: Bool
    var readerChromeVisible: Bool
    var bgRGBA: [Double]
    var fgRGBA: [Double]
}

private extension Color {
    var codableRGBA: [Double] {
        let ui = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return [Double(red), Double(green), Double(blue), Double(alpha)]
        }
        return [0, 0, 0, 1]
    }

    static func codableRGBA(_ values: [Double], fallback: Color) -> Color {
        guard values.count >= 3 else { return fallback }
        return Color(
            red: min(max(values[0], 0), 1),
            green: min(max(values[1], 0), 1),
            blue: min(max(values[2], 0), 1),
            opacity: min(max(values.indices.contains(3) ? values[3] : 1, 0), 1)
        )
    }
}

public struct ReadingPosition: Codable, Equatable, Sendable {
    let chapterID: String
    let page: Int
    let updatedAt: Date
}

public struct ExportedTextArchive: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let url: URL
    public let title: String
}

/// A single episode row from the DB.
public struct ChapterCard: Identifiable, FetchableRecord, Decodable, Hashable, Sendable {
    public let id: String              // chapter_index
    public let novel_id: String
    public let subtitle: String
    public let intro_xhtml_zstd: Data?
    public let body_xhtml_zstd: Data?
    public let post_xhtml_zstd: Data?
    public let intro_zstd_dict: Data?
    public let body_zstd_dict: Data?
    public let post_zstd_dict: Data?
    public let source_signature: String
    public let sourceUrl: String
    public let body_downloaded: Bool
    public let storagePath: String

    public var hasDownloadedBody: Bool {
        body_downloaded
    }
}

/// A novel entry (one row from the novels table joined with section count).
public struct NovelMeta: Identifiable, Equatable, Sendable {
    public let id: String              // novel_id
    public var title: String
    public var author: String
    public var tocUrl: String
    public var domain: String
    public var episodeCount: Int
    public var updatedAt: String
    public var outputDir: String
    public var storagePath: String

    public var displayTitle: String {
        title.isEmpty ? id : title
    }
}

// MARK: - AppState

@MainActor
public final class AppState: ObservableObject {
    // Library
    @Published public var selectedTab: AppMainTab = .library
    @Published public var novels: [NovelMeta] = []
    @Published public var selectedNovel: NovelMeta?
    @Published public var chapters: [ChapterCard] = []
    @Published public var selected: ChapterCard?

    // Reader
    @Published public var attributed = NSAttributedString(string: "章を選択してください")
    @Published public var isRenderingChapter = false
    @Published public var renderedCharacterCount = 0
    @Published public var fontSize: CGFloat    = 16
    @Published public var lineSpacing: CGFloat = 6
    @Published public var readerMargin: CGFloat = 34
    @Published public var readerBrightness: Double = 0.86
    @Published public var readerDarkTheme = true
    @Published public var showImages           = true
    @Published public var rtl                  = true
    @Published public var readerFontName       = "system"
    @Published public var readerFullscreen     = true
    @Published public var readerChromeVisible  = false
    @Published public var readerQuickButtonsVisible = false
    @Published public var showReaderMenu       = false
    @Published public var showChapterMenu      = false
    @Published public var showAppearanceMenu   = false
    @Published public var bg  = Color.black
    @Published public var fg  = Color(red: 0.72, green: 0.72, blue: 0.72)
    @Published public var showReaderSettings   = false
    @Published public var readingPositions: [String: ReadingPosition] = [:]
    @Published public var bookmarkedChapterKeys = Set<String>()

    // Search
    @Published public var query = ""
    @Published public var librarySort: LibrarySortMode = .updated

    // Browser & download
    @Published public var browserUrl      = ""
    @Published public var tocUrl          = ""
    @Published public var browserCookieHeaders: [String: String] = [:]
    @Published public var parserEngine: ParserEngineChoice = .domain
    @Published public var browserAdBlockEnabled = true
    @Published public var isDownloading   = false
    @Published public var isAddingTocToShelf = false
    @Published public var downloadStatus  = "未ダウンロード"
    @Published public var isRefreshingToc = false
    @Published public var tocRefreshStatus = ""
    @Published public var readerBoundDownloadUrl: String?
    @Published public var readerPendingTocUrl: String?
    @Published public var activeReaderDownloadUrl: String?
    @Published public var activeReaderDownloadStartChapter: String?
    private var activeDownloadUrl: String?
    private var hiddenDeletedNovelKeys = Set<String>()
    private var hiddenDeletedNovelURLs = Set<String>()
    @Published public var isExportingTextZip = false
    @Published public var textExportStatus = ""
    @Published public var exportedTextArchive: ExportedTextArchive?
    private var pendingReaderDownloadStartChapter: String?
    private var activeTocAddUrl: String?
    private var activeTocAddOpensReader = false
    private var tocRefreshQueue: [String] = []
    private var queuedTocRefreshUrls = Set<String>()
    private var activeTocRefreshUrl: String?
    private var isTocRefreshWorkerRunning = false

    // Progress (polled from Rust)
    @Published public var progress = NovelCoreBridge.callGetDownloadProgress()

    // Convenience counts
    public var novelCount:   Int { novels.count }
    public var downloadCount: Int { novels.reduce(0) { $0 + $1.episodeCount } }
    public var currentChapterOrdinalText: String {
        guard let selected else { return "0/0 話" }
        let index = chapters.firstIndex(of: selected).map { $0 + 1 } ?? 0
        return "\(index)/\(chapters.count) 話"
    }

    public var selectedChapterNeedsDownload: Bool {
        selected?.hasDownloadedBody != true
    }

    public var readerModalVisible: Bool {
        showReaderMenu || showChapterMenu || showAppearanceMenu
    }

    public var readerCanRenderSelectedChapter: Bool {
        selected?.hasDownloadedBody == true && attributed.length > 0
    }

    private let library = LibraryEngine.shared
    private let downloader = ActiveDownloadWorker()
    private var lastAutomaticTocRefreshAt: Date?
    private var lastObservedDownloadCompleted = -1
    private var lastObservedProgressSignature = ""
    private var downloadGeneration = 0
    private var tocAddGeneration = 0
    private var quickButtonRevealToken = UUID()
    private let downloadBackgroundLease = DownloadBackgroundLease()
    private let tocBackgroundLease = DownloadBackgroundLease()
    private var didRegisterLifecycleObserver = false
    private var renderTask: Task<Void, Never>?
    private var renderSignature = ""
    private var renderedChapterKey = ""
    private var readerSettingsCommitTask: Task<Void, Never>?

    private static let readingPositionsKey = "NovelDL.readingPositions.v1"
    private static let bookmarksKey = "NovelDL.bookmarks.v1"
    private static let readerSettingsKey = "NovelDL.readerSettings.v1"
    private static let browserAdBlockKey = "NovelDL.browserAdBlockEnabled.v1"
    private static let deletedNovelKeysKey = "NovelDL.deletedNovelKeys.v1"
    private static let deletedNovelURLsKey = "NovelDL.deletedNovelURLs.v1"
    private static let automaticTocRefreshInterval: TimeInterval = 30 * 60

    public init() {}

    // MARK: - Boot

    public func boot() {
        loadReaderMemory()
        let docs = Self.docsDir
        try? FileManager.default.createDirectory(atPath: Self.libraryRootDir, withIntermediateDirectories: true)
        try? NovelCoreBridge.callSetRootDir(rootDir: docs)
        NovelCoreBridge.setDownloadProgressHandler { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.handleCoreDownloadProgress(progress)
            }
        }
        library.configure(rootDir: Self.libraryRootDir)
        refreshLibrary()
        queueAutomaticTocRefreshIfDue(force: true)
        BackgroundNovelMaintenance.scheduleNextRefresh()
        registerLifecycleObserverIfNeeded()
    }

    private func registerLifecycleObserverIfNeeded() {
        guard !didRegisterLifecycleObserver else { return }
        didRegisterLifecycleObserver = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppBecameActive()
            }
        }
    }

    private func handleAppBecameActive() {
        handleCoreDownloadProgress(NovelCoreBridge.callGetDownloadProgress())
        refreshLibrary(clearDatabaseCache: true)
        queueAutomaticTocRefreshIfDue(force: true)
        runTocRefreshWorkerIfNeeded()
    }

    // MARK: - Library

    public func refreshLibrary(clearDatabaseCache: Bool = false) {
        if clearDatabaseCache { library.clearCache() }
        novels = visibleNovels(sortedNovels(library.listNovels()))
        // Re-select same novel if still present
        if let prev = selectedNovel, let updated = novels.first(where: { isSameNovel($0, prev) }) {
            selectedNovel = updated
            loadChapters(for: updated)
        } else {
            selectedNovel = nil
            chapters = []
            selected = nil
        }
        refresh()
    }

    public func refreshLibraryAndUpdateTocs() {
        refreshLibrary(clearDatabaseCache: true)
        queueTocRefresh(for: novels, priority: true)
        lastAutomaticTocRefreshAt = Date()
    }

    public func refreshToc(for novel: NovelMeta) {
        queueTocRefresh(for: [novel], priority: true)
    }


    private func queueAutomaticTocRefreshIfDue(force: Bool = false) {
        let now = Date()
        if !force, let lastAutomaticTocRefreshAt, now.timeIntervalSince(lastAutomaticTocRefreshAt) < Self.automaticTocRefreshInterval {
            return
        }
        refreshLibrary(clearDatabaseCache: true)
        guard !novels.isEmpty else {
            lastAutomaticTocRefreshAt = now
            return
        }
        lastAutomaticTocRefreshAt = now
        BackgroundNovelMaintenance.scheduleNextRefresh()
        queueTocRefresh(for: novels)
    }

    private func queueTocRefresh(for novels: [NovelMeta], priority: Bool = false) {
        let urls = novels.map(\.tocUrl).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !urls.isEmpty else { return }
        for url in urls {
            guard activeTocRefreshUrl != url, !queuedTocRefreshUrls.contains(url) else { continue }
            queuedTocRefreshUrls.insert(url)
            if priority {
                tocRefreshQueue.insert(url, at: 0)
            } else {
                tocRefreshQueue.append(url)
            }
        }
        runTocRefreshWorkerIfNeeded()
    }

    private func runTocRefreshWorkerIfNeeded() {
        guard !isDownloading else { return }
        guard !isTocRefreshWorkerRunning else { return }
        isTocRefreshWorkerRunning = true
        Task { @MainActor in
            while true {
                guard !isDownloading else { break }
                guard !tocRefreshQueue.isEmpty else { break }
                let url = tocRefreshQueue.removeFirst()
                queuedTocRefreshUrls.remove(url)
                activeTocRefreshUrl = url
                isRefreshingToc = true
                tocRefreshStatus = "目次を更新中…"
                do {
                    let result = try await downloader.fetchTocOnly(tocUrl: url, outputDir: Self.outputDir(for: url))
                    refreshLibrary(clearDatabaseCache: true)
                    tocRefreshStatus = "目次更新完了: \(result)"
                } catch {
                    tocRefreshStatus = "目次更新エラー: \(error.localizedDescription)"
                }
                activeTocRefreshUrl = nil
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            isRefreshingToc = false
            activeTocRefreshUrl = nil
            isTocRefreshWorkerRunning = false
            if !isDownloading, !tocRefreshQueue.isEmpty { runTocRefreshWorkerIfNeeded() }
        }
    }

    public func selectNovel(_ novel: NovelMeta) {
        selectNovel(novel, preferredChapterID: nil)
    }

    private func selectNovel(_ novel: NovelMeta, preferredChapterID: String?) {
        if let active = activeReaderDownloadUrl, active != novel.tocUrl {
            cancelActiveReaderBoundDownloadIfNeeded()
        }
        selectedNovel = novel
        chapters = library.chaptersForNovel(novel)
        let targetChapterID = preferredChapterID ?? readingPositions[novel.id]?.chapterID
        if let targetChapterID, let preferred = chapters.first(where: { $0.id == targetChapterID }) {
            selected = preferred
        } else if let current = selected, let refreshed = chapters.first(where: { $0.id == current.id }) {
            selected = refreshed
        } else {
            selected = chapters.first
        }
        updateReaderPendingStateForSelection()
        refresh()
        if selectedTab == .reader { startReaderBoundDownloadIfNeeded(from: selected?.id) }
    }

    public func openNovelInReader(_ novel: NovelMeta) {
        library.clearCache()
        let latest = library.listNovels().first(where: { isSameNovel($0, novel) }) ?? novel
        selectNovel(latest)
        selectedTab = .reader
        updateReaderPendingStateForSelection()
        startReaderBoundDownloadIfNeeded(from: selected?.id)
    }

    public func deselectNovel() {
        selectedNovel = nil
        chapters = []
        selected = nil
        refresh()
    }

    private func loadChapters(for novel: NovelMeta) {
        chapters = library.chaptersForNovel(novel)
        if let current = selected, let refreshed = chapters.first(where: { $0.id == current.id }) {
            selected = refreshed
        } else {
            selected = chapters.first
        }
        updateReaderPendingStateForSelection()
        refresh()
        if selectedTab == .reader { startReaderBoundDownloadIfNeeded(from: selected?.id) }
    }

    private func updateReaderPendingStateForSelection() {
        guard selectedTab == .reader || selectedNovel != nil else { return }
        if let novel = selectedNovel, selected?.hasDownloadedBody != true {
            readerPendingTocUrl = novel.tocUrl
            if !isDownloading { downloadStatus = "本文をダウンロード準備中…" }
        } else {
            readerPendingTocUrl = nil
        }
    }

    public func selectChapter(_ card: ChapterCard) {
        selected = card
        readerChromeVisible = false
        showChapterMenu = false
        updateReaderPendingStateForSelection()
        refresh()
        if selectedTab == .reader { startReaderBoundDownloadIfNeeded(from: card.id) }
    }

    @discardableResult
    public func selectNextChapter() -> Bool {
        guard let selected, let idx = chapters.firstIndex(of: selected), idx + 1 < chapters.count else { return false }
        selectChapter(chapters[idx + 1])
        return true
    }

    @discardableResult
    public func selectPreviousChapter() -> Bool {
        guard let selected, let idx = chapters.firstIndex(of: selected), idx > 0 else { return false }
        selectChapter(chapters[idx - 1])
        return true
    }

    public func savedPageForSelectedChapter() -> Int {
        guard let novel = selectedNovel,
              let selected,
              let position = readingPositions[novel.id],
              position.chapterID == selected.id else {
            return 0
        }
        return max(position.page, 0)
    }

    public func recordReaderPage(_ page: Int) {
        guard let novel = selectedNovel, let selected else { return }
        let clampedPage = max(page, 0)
        if let current = readingPositions[novel.id],
           current.chapterID == selected.id,
           current.page == clampedPage {
            return
        }
        readingPositions[novel.id] = ReadingPosition(
            chapterID: selected.id,
            page: clampedPage,
            updatedAt: Date()
        )
        persistReadingPositions()
    }

    public func readingProgressText(for novel: NovelMeta) -> String? {
        guard let position = readingPositions[novel.id] else { return nil }
        let chapterLabel = position.chapterID.isEmpty ? "前回位置" : "第\(position.chapterID)話"
        return "続き: \(chapterLabel) / p.\(position.page + 1)"
    }

    public func isBookmarked(_ chapter: ChapterCard?) -> Bool {
        guard let chapter else { return false }
        return bookmarkedChapterKeys.contains(bookmarkKey(novelID: chapter.novel_id, chapterID: chapter.id))
    }

    public func toggleBookmarkForSelectedChapter() {
        guard let selected else { return }
        let key = bookmarkKey(novelID: selected.novel_id, chapterID: selected.id)
        if bookmarkedChapterKeys.contains(key) {
            bookmarkedChapterKeys.remove(key)
        } else {
            bookmarkedChapterKeys.insert(key)
        }
        persistBookmarks()
    }

    private func bookmarkKey(novelID: String, chapterID: String) -> String {
        "\(novelID)::\(chapterID)"
    }

    private func loadReaderMemory() {
        browserAdBlockEnabled = UserDefaults.standard.object(forKey: Self.browserAdBlockKey) as? Bool ?? true
        loadReaderSettings()
        if let data = UserDefaults.standard.data(forKey: Self.readingPositionsKey),
           let decoded = try? JSONDecoder().decode([String: ReadingPosition].self, from: data) {
            readingPositions = decoded
        }
        bookmarkedChapterKeys = Set(UserDefaults.standard.stringArray(forKey: Self.bookmarksKey) ?? [])
        hiddenDeletedNovelKeys = Set(UserDefaults.standard.stringArray(forKey: Self.deletedNovelKeysKey) ?? [])
        hiddenDeletedNovelURLs = Set(UserDefaults.standard.stringArray(forKey: Self.deletedNovelURLsKey) ?? [])
    }

    private func persistReadingPositions() {
        guard let data = try? JSONEncoder().encode(readingPositions) else { return }
        UserDefaults.standard.set(data, forKey: Self.readingPositionsKey)
    }

    private func persistBookmarks() {
        UserDefaults.standard.set(Array(bookmarkedChapterKeys).sorted(), forKey: Self.bookmarksKey)
    }

    private func loadReaderSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.readerSettingsKey),
              let decoded = try? JSONDecoder().decode(ReaderSettingsSnapshot.self, from: data) else { return }
        fontSize = CGFloat(min(max(decoded.fontSize, 12), 38))
        lineSpacing = CGFloat(min(max(decoded.lineSpacing, 0), 28))
        readerMargin = CGFloat(min(max(decoded.readerMargin, 16), 56))
        readerBrightness = min(max(decoded.readerBrightness, 0.45), 1.0)
        readerDarkTheme = decoded.readerDarkTheme
        showImages = decoded.showImages
        rtl = decoded.rtl
        readerFontName = ["system", "serif", "monospace"].contains(decoded.readerFontName) ? decoded.readerFontName : "system"
        readerFullscreen = decoded.readerFullscreen
        readerChromeVisible = decoded.readerChromeVisible
        bg = Color.codableRGBA(decoded.bgRGBA, fallback: bg)
        fg = Color.codableRGBA(decoded.fgRGBA, fallback: fg)
    }

    public func persistBrowserSettings() {
        UserDefaults.standard.set(browserAdBlockEnabled, forKey: Self.browserAdBlockKey)
    }

    public func persistReaderSettings() {
        let snapshot = ReaderSettingsSnapshot(
            fontSize: Double(fontSize),
            lineSpacing: Double(lineSpacing),
            readerMargin: Double(readerMargin),
            readerBrightness: readerBrightness,
            readerDarkTheme: readerDarkTheme,
            showImages: showImages,
            rtl: rtl,
            readerFontName: readerFontName,
            readerFullscreen: readerFullscreen,
            readerChromeVisible: readerChromeVisible,
            bgRGBA: bg.codableRGBA,
            fgRGBA: fg.codableRGBA
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.readerSettingsKey)
    }

    public func commitReaderAppearanceChange(rebuild: Bool = true, debounce: Bool = true) {
        readerSettingsCommitTask?.cancel()
        let delay: UInt64 = debounce ? 180_000_000 : 0
        readerSettingsCommitTask = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            if rebuild { refresh() }
            persistReaderSettings()
        }
    }

    private func persistDeletedNovelFilters() {
        UserDefaults.standard.set(Array(hiddenDeletedNovelKeys).sorted(), forKey: Self.deletedNovelKeysKey)
        UserDefaults.standard.set(Array(hiddenDeletedNovelURLs).sorted(), forKey: Self.deletedNovelURLsKey)
    }

    private func unhideDeletedNovel(tocUrl: String) {
        hiddenDeletedNovelURLs.remove(tocUrl)
        hiddenDeletedNovelKeys = hiddenDeletedNovelKeys.filter { !$0.hasSuffix("|\(tocUrl)") }
        persistDeletedNovelFilters()
    }

    public func hideReaderChromeAndMenus() {
        readerChromeVisible = false
        showReaderMenu = false
        showChapterMenu = false
        showAppearanceMenu = false
        readerQuickButtonsVisible = false
    }

    public var readerFontLabel: String {
        switch readerFontName {
        case "serif": return "明朝"
        case "monospace": return "等幅"
        default: return "標準"
        }
    }

    public func nextReaderMargin() -> CGFloat {
        let presets: [CGFloat] = [20, 28, 34, 44, 56]
        let currentIndex = presets.enumerated().min { abs($0.element - readerMargin) < abs($1.element - readerMargin) }?.offset ?? 2
        return presets[(currentIndex + 1) % presets.count]
    }

    public func toggleReaderChrome() {
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.03)) {
            readerQuickButtonsVisible = false
            if showReaderMenu || showChapterMenu || showAppearanceMenu {
                showReaderMenu = false
                showChapterMenu = false
                showAppearanceMenu = false
            } else {
                readerChromeVisible.toggle()
            }
        }
    }

    public func revealReaderQuickButtons() {
        let token = UUID()
        quickButtonRevealToken = token
        withAnimation(.interpolatingSpring(stiffness: 280, damping: 20)) {
            showReaderMenu = false
            showChapterMenu = false
            showAppearanceMenu = false
            readerChromeVisible = false
            readerQuickButtonsVisible = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard quickButtonRevealToken == token else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                readerQuickButtonsVisible = false
            }
        }
    }

    public func cycleReaderFont() {
        let fonts = ["system", "serif", "monospace"]
        let next = (fonts.firstIndex(of: readerFontName) ?? 0) + 1
        readerFontName = fonts[next % fonts.count]
        persistReaderSettings()
    }

    public func toggleReaderTheme() {
        readerDarkTheme.toggle()
        if readerDarkTheme {
            bg = .black
            fg = Color(red: 0.72, green: 0.72, blue: 0.72)
        } else {
            bg = Color(red: 0.94, green: 0.90, blue: 0.82)
            fg = .black
        }
        refresh()
        persistReaderSettings()
    }

    public func sortLibrary(_ mode: LibrarySortMode) {
        librarySort = mode
        novels = sortedNovels(novels)
    }

    public func deleteNovel(_ novel: NovelMeta) {
        hiddenDeletedNovelKeys.insert(deletedNovelKey(novel))
        hiddenDeletedNovelURLs.insert(novel.tocUrl)
        persistDeletedNovelFilters()
        novels.removeAll { isSameNovel($0, novel) }
        tocRefreshQueue.removeAll { $0 == novel.tocUrl }
        queuedTocRefreshUrls.remove(novel.tocUrl)
        if activeTocRefreshUrl == novel.tocUrl { activeTocRefreshUrl = nil }
        BackgroundNovelMaintenance.clearPendingFullDownload(url: novel.tocUrl)
        if isDownloading, activeDownloadUrl == novel.tocUrl {
            cancelDownload()
        }
        if isAddingTocToShelf, readerPendingTocUrl == novel.tocUrl {
            try? downloader.stop()
            isAddingTocToShelf = false
            activeTocAddUrl = nil
            activeTocAddOpensReader = false
            tocBackgroundLease.end()
            finishCoreProgressObservation()
        }
        if let selectedNovel, isSameNovel(selectedNovel, novel) { deselectNovel() }
        library.deleteNovel(novel) { [weak self] in
            self?.refreshLibrary(clearDatabaseCache: true)
        }
    }

    private func visibleNovels(_ source: [NovelMeta]) -> [NovelMeta] {
        source.filter { novel in
            !hiddenDeletedNovelKeys.contains(deletedNovelKey(novel))
                && !hiddenDeletedNovelURLs.contains(novel.tocUrl)
        }
    }

    private func deletedNovelKey(_ novel: NovelMeta) -> String {
        "\(novel.storagePath)|\(novel.id)|\(novel.tocUrl)"
    }

    private func isSameNovel(_ lhs: NovelMeta, _ rhs: NovelMeta) -> Bool {
        if !lhs.id.isEmpty || !rhs.id.isEmpty {
            return lhs.id == rhs.id && lhs.tocUrl == rhs.tocUrl && lhs.storagePath == rhs.storagePath
        }
        return lhs.tocUrl == rhs.tocUrl && lhs.storagePath == rhs.storagePath && lhs.outputDir == rhs.outputDir
    }


    public func downloadAllChaptersForSelectedNovel() {
        guard let novel = selectedNovel else { return }
        downloadAllChapters(for: novel)
    }

    public func downloadAllChapters(for novel: NovelMeta) {
        guard !isDownloading else {
            downloadStatus = "ダウンロードはすでに実行中です"
            return
        }
        let latest = library.listNovels().first(where: { isSameNovel($0, novel) }) ?? novel
        if selectedNovel == nil || !isSameNovel(selectedNovel!, latest) {
            selectNovel(latest)
        }
        readerBoundDownloadUrl = nil
        readerPendingTocUrl = nil
        pendingReaderDownloadStartChapter = nil
        BackgroundNovelMaintenance.recordPendingFullDownload(url: latest.tocUrl)
        startDownload(tocUrl: latest.tocUrl, fromChapter: nil, readerBound: false)
    }

    public func exportTextZipForSelectedNovel() {
        guard let novel = selectedNovel else { return }
        exportTextZip(for: novel)
    }

    public func exportTextZip(for novel: NovelMeta) {
        guard !isExportingTextZip else {
            textExportStatus = "TXT ZIPを書き出し中です"
            return
        }
        let latest = library.listNovels().first(where: { isSameNovel($0, novel) }) ?? novel
        isExportingTextZip = true
        textExportStatus = "TXT ZIPを書き出し中…"
        Task {
            do {
                let url = try await NovelTextZipExporter.export(novel: latest)
                await MainActor.run {
                    isExportingTextZip = false
                    textExportStatus = "TXT ZIPを書き出しました"
                    exportedTextArchive = ExportedTextArchive(url: url, title: latest.displayTitle)
                }
            } catch {
                await MainActor.run {
                    isExportingTextZip = false
                    textExportStatus = "TXT ZIP書き出しエラー: \(error.localizedDescription)"
                }
            }
        }
    }

    private func sortedNovels(_ values: [NovelMeta]) -> [NovelMeta] {
        switch librarySort {
        case .updated: return values.sorted { $0.updatedAt > $1.updatedAt }
        case .title: return values.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        case .episodes: return values.sorted { $0.episodeCount > $1.episodeCount }
        }
    }

    // MARK: - Search

    public func runSearch() {
        guard let novel = selectedNovel else { return }
        let previousSelectedID = selected?.id
        let results = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? library.chaptersForNovel(novel)
            : library.searchChapters(query, novel: novel)
        chapters = results
        if let previousSelectedID, let preserved = results.first(where: { $0.id == previousSelectedID }) {
            selected = preserved
        } else if selected == nil {
            selected = results.first
        }
        refresh()
    }

    // MARK: - Render

    public func refresh() {
        guard let s = selected, s.hasDownloadedBody else {
            renderTask?.cancel()
            renderSignature = ""
            renderedChapterKey = ""
            isRenderingChapter = false
            renderedCharacterCount = 0
            attributed = NSAttributedString(string: "")
            return
        }

        let signature = readerRenderSignature(for: s)
        guard signature != renderSignature || attributed.length == 0 else { return }
        let chapterKey = "\(s.novel_id)|\(s.id)"
        renderSignature = signature
        renderTask?.cancel()
        isRenderingChapter = true
        if attributed.length > 0, renderedChapterKey != chapterKey { attributed = NSAttributedString(string: "") }

        let chapter = s
        let fontSize = fontSize
        let lineSpacing = lineSpacing
        let fontName = readerFontName
        let fgRGBA = fg.codableRGBA
        let brightness = readerBrightness
        let showImages = showImages
        renderTask = Task.detached(priority: .userInitiated) {
            let rendered = LibraryEngine.renderChapter(
                chapter: chapter,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                fontName: fontName,
                fgRGBA: fgRGBA,
                brightness: brightness,
                showImages: showImages
            )
            await MainActor.run {
                guard !Task.isCancelled, self.renderSignature == signature else { return }
                self.attributed = rendered.attributed
                self.renderedCharacterCount = rendered.characterCount
                self.renderedChapterKey = chapterKey
                self.isRenderingChapter = false
            }
        }
    }

    private func readerRenderSignature(for chapter: ChapterCard) -> String {
        [
            chapter.novel_id,
            chapter.id,
            chapter.source_signature,
            String(format: "%.2f", fontSize),
            String(format: "%.2f", lineSpacing),
            readerFontName,
            String(format: "%.3f", readerBrightness),
            fg.codableRGBA.map { String(format: "%.3f", $0) }.joined(separator: ","),
            showImages ? "images" : "text"
        ].joined(separator: "|")
    }

    public func closeCurrent() {
        showReaderMenu = false
        showChapterMenu = false
        showAppearanceMenu = false
        readerQuickButtonsVisible = false
        readerBoundDownloadUrl = nil
        readerPendingTocUrl = nil
        selectedNovel = nil
        chapters = []
        selected = nil
        attributed = NSAttributedString(string: "")
        selectedTab = .library
    }

    public func handleSelectedTabChanged(_ tab: AppMainTab) {
        if tab == .reader {
            startReaderBoundDownloadIfNeeded(from: selected?.id)
        } else if activeReaderDownloadUrl != nil {
            downloadStatus = "本文DLをバックグラウンドで継続中…"
        }
    }

    // MARK: - Browser / Download

    public func detectToc() {
        tocUrl = TocMatcher.candidate(browserUrl)?.url ?? ""
    }


    public func rememberBrowserCookieHeaders() {
        for (host, cookie) in browserCookieHeaders {
            BrowserAccessCredentialStore.save(host: host, cookieHeader: cookie)
        }
    }

    private func cookieHeader(for host: String) -> String? {
        let normalizedHost = host.lowercased()
        if let exact = browserCookieHeaders[normalizedHost] { return exact }
        if normalizedHost.hasPrefix("www."), let apex = browserCookieHeaders[String(normalizedHost.dropFirst(4))] { return apex }
        if let www = browserCookieHeaders["www." + normalizedHost] { return www }
        if let matching = browserCookieHeaders.first(where: { BrowserAccessCredentialStore.domainMatches(host: normalizedHost, storedDomain: $0.key) }) {
            return matching.value
        }
        if let cached = BrowserAccessCredentialStore.cookie(for: normalizedHost) {
            return cached
        }
        return nil
    }

    private func applySelectedParserEngine(for host: String) {
        try? NovelCoreBridge.callSetDomainEngine(domain: host, engine: parserEngine.rawValue)
    }

    private func applyBrowserCookieToCore(host: String, cookie: String) {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedHost = host.lowercased()
        try? NovelCoreBridge.callSetExtraCookie(domain: normalizedHost, cookie: trimmed)
        if normalizedHost.hasPrefix("www.") {
            try? NovelCoreBridge.callSetExtraCookie(domain: String(normalizedHost.dropFirst(4)), cookie: trimmed)
        } else {
            try? NovelCoreBridge.callSetExtraCookie(domain: "www." + normalizedHost, cookie: trimmed)
        }
    }

    public func addDetectedTocToShelfForReader(browserHTML: String? = nil) {
        guard !tocUrl.isEmpty else {
            downloadStatus = "目次URLを検出してください"
            return
        }
        if activeReaderDownloadUrl != nil {
            cancelActiveReaderBoundDownloadIfNeeded(status: "新しい小説を開くためDLを停止")
        }
        readerBoundDownloadUrl = tocUrl
        readerPendingTocUrl = tocUrl
        selectedNovel = nil
        chapters = []
        selected = nil
        attributed = NSAttributedString(string: "")
        selectedTab = .reader
        addDetectedTocToShelf(openInReader: true, browserHTML: browserHTML)
    }

    public func addDetectedTocToShelf(browserHTML: String? = nil) {
        guard !tocUrl.isEmpty else {
            downloadStatus = "目次URLを検出してください"
            return
        }
        addDetectedTocToShelf(openInReader: false, browserHTML: browserHTML)
    }

    private func addDetectedTocToShelf(openInReader: Bool, browserHTML: String?) {
        let url = tocUrl
        unhideDeletedNovel(tocUrl: url)
        if let host = URL(string: url)?.host?.lowercased() {
            applySelectedParserEngine(for: host)
            rememberBrowserCookieHeaders()
            if let cookie = cookieHeader(for: host) {
                applyBrowserCookieToCore(host: host, cookie: cookie)
            }
        }
        guard !isAddingTocToShelf else {
            downloadStatus = "目次取得はすでに実行中です"
            return
        }
        tocAddGeneration += 1
        let generation = tocAddGeneration
        isAddingTocToShelf = true
        let out = Self.outputDir(for: url)
        let browserSnapshotHTML = browserHTML?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        downloadStatus = browserSnapshotHTML.count > 256 ? "表示中ページから目次を解析中…" : "目次を取得中…"
        if openInReader, useExistingTocImmediatelyIfAvailable(url: url) {
            downloadStatus = "保存済み目次から本文DLを開始し、目次更新も続けます…"
        }
        activeTocAddUrl = url
        activeTocAddOpensReader = openInReader
        tocBackgroundLease.begin(named: openInReader ? "NovelDL.ReadNowToc" : "NovelDL.AddToShelf")
        beginCoreProgressObservation()
        Task {
            do {
                _ = try await downloader.createLibraryPlaceholder(tocUrl: url, outputDir: out)
                await MainActor.run {
                    guard generation == tocAddGeneration else { return }
                    _ = refreshLibraryForTocAvailability(url: url, openInReader: openInReader)
                    downloadStatus = openInReader
                        ? "ライブラリに追加済み。目次取得と本文DLを準備中…"
                        : "ライブラリに追加済み。目次取得を開始します…"
                }
                let result: String
                if browserSnapshotHTML.count > 256 {
                    do {
                        result = try await downloader.fetchTocOnlyFromBrowserHTML(
                            tocUrl: url,
                            html: browserSnapshotHTML,
                            outputDir: out
                        )
                    } catch {
                        result = try await downloader.fetchTocOnly(tocUrl: url, outputDir: out)
                    }
                } else {
                    result = try await downloader.fetchTocOnly(tocUrl: url, outputDir: out)
                }
                await MainActor.run {
                    guard generation == tocAddGeneration else { return }
                    isAddingTocToShelf = false
                    activeTocAddUrl = nil
                    activeTocAddOpensReader = false
                    tocBackgroundLease.end()
                    if !isDownloading { finishCoreProgressObservation() }
                    let appeared = refreshLibraryForTocAvailability(url: url, openInReader: openInReader)
                    downloadStatus = "目次取得完了: \(result)"
                    if openInReader && !appeared { self.readerPendingTocUrl = nil }
                }
            } catch {
                await MainActor.run {
                    guard generation == tocAddGeneration else { return }
                    isAddingTocToShelf = false
                    activeTocAddUrl = nil
                    activeTocAddOpensReader = false
                    tocBackgroundLease.end()
                    if !isDownloading { finishCoreProgressObservation() }
                    downloadStatus = "目次取得エラー: \(error.localizedDescription)"
                }
            }
        }
    }


    @discardableResult
    private func useExistingTocImmediatelyIfAvailable(url: String) -> Bool {
        refreshLibrary(clearDatabaseCache: true)
        guard let novel = novels.first(where: { $0.tocUrl == url }), novel.episodeCount > 0 else { return false }
        selectNovel(novel)
        selectedTab = .reader
        readerBoundDownloadUrl = url
        readerPendingTocUrl = selected?.hasDownloadedBody == true ? nil : url
        startReaderBoundDownloadIfNeeded(from: selected?.id)
        return true
    }

    @discardableResult
    private func refreshLibraryForTocAvailability(url: String, openInReader: Bool) -> Bool {
        refreshLibrary(clearDatabaseCache: true)
        guard let novel = novels.first(where: { $0.tocUrl == url }) else { return false }
        guard openInReader else { return true }
        selectedTab = .reader
        selectNovel(novel)
        if !isDownloading {
            startReaderBoundDownloadIfNeeded(from: selected?.id)
        }
        return true
    }

    private let readerImmediateDownloadWindow = 15

    private func firstChapterNeedingDownload(from chapterID: String?) -> ChapterCard? {
        guard !chapters.isEmpty else { return nil }
        let startIndex = chapterID.flatMap { id in chapters.firstIndex { $0.id == id } } ?? 0
        if let match = chapters[startIndex...].first(where: { !$0.hasDownloadedBody }) {
            return match
        }
        if startIndex > 0 {
            return chapters[..<startIndex].first(where: { !$0.hasDownloadedBody })
        }
        return nil
    }

    private func readerWindowStartChapterID(from chapterID: String?) -> String? {
        guard !chapters.isEmpty else { return nil }
        let startIndex = chapterID.flatMap { id in chapters.firstIndex { $0.id == id } } ?? 0
        let endIndex = min(chapters.count, startIndex + readerImmediateDownloadWindow)
        guard startIndex < endIndex,
              chapters[startIndex..<endIndex].contains(where: { !$0.hasDownloadedBody }) else {
            return nil
        }
        return chapters[startIndex].id
    }

    private func readerWindowMissingChapterIDs(from chapterID: String?) -> Set<String> {
        guard !chapters.isEmpty else { return [] }
        let startIndex = chapterID.flatMap { id in chapters.firstIndex { $0.id == id } } ?? 0
        let endIndex = min(chapters.count, startIndex + readerImmediateDownloadWindow)
        guard startIndex < endIndex else { return [] }
        return Set(chapters[startIndex..<endIndex].filter { !$0.hasDownloadedBody }.map(\.id))
    }

    private func refreshReaderSelectionFromDownloadedDataIfNeeded(preferredChapterID: String? = nil, force: Bool = false) {
        guard selectedTab == .reader,
              (force || activeReaderDownloadUrl != nil),
              let currentNovel = selectedNovel else {
            return
        }

        library.clearCache()
        let refreshedNovels = visibleNovels(sortedNovels(library.listNovels()))
        novels = refreshedNovels
        if let refreshedNovel = refreshedNovels.first(where: { isSameNovel($0, currentNovel) }) {
            selectedNovel = refreshedNovel
        }
        let novelForChapters = selectedNovel ?? currentNovel
        let previousSelectedID = preferredChapterID ?? selected?.id
        let refreshedChapters = library.chaptersForNovel(novelForChapters)
        guard !refreshedChapters.isEmpty else { return }

        chapters = refreshedChapters
        if let previousSelectedID,
           let refreshedSelected = refreshedChapters.first(where: { $0.id == previousSelectedID }) {
            selected = refreshedSelected
        } else {
            selected = refreshedChapters.first
        }

        updateReaderPendingStateForSelection()
        refresh()
    }

    private func startReaderBoundDownloadIfNeeded(from chapterID: String? = nil) {
        guard selectedTab == .reader else { return }
        guard let novel = selectedNovel else {
            guard let url = readerBoundDownloadUrl, !isDownloading else { return }
            guard readerPendingTocUrl == url else { return }
            startDownload(tocUrl: url, fromChapter: chapterID, readerBound: true)
            return
        }

        readerBoundDownloadUrl = novel.tocUrl
        updateReaderPendingStateForSelection()

        guard let startChapter = readerWindowStartChapterID(from: chapterID ?? selected?.id) else {
            if activeReaderDownloadUrl == nil { readerPendingTocUrl = nil }
            return
        }

        if isDownloading, activeReaderDownloadUrl == novel.tocUrl {
            guard activeReaderDownloadStartChapter != startChapter else { return }
            pendingReaderDownloadStartChapter = nil
            cancelActiveReaderBoundDownloadIfNeeded(status: "選択話からDLを即時再開します")
            startDownload(tocUrl: novel.tocUrl, fromChapter: startChapter, readerBound: true)
            return
        }
        startDownload(tocUrl: novel.tocUrl, fromChapter: startChapter, readerBound: true)
    }

    private func cancelActiveReaderBoundDownloadIfNeeded(status: String = "リーダーを閉じたためDLを停止") {
        guard activeReaderDownloadUrl != nil else { return }
        downloadGeneration += 1
        try? downloader.stop()
        activeReaderDownloadUrl = nil
        activeReaderDownloadStartChapter = nil
        isDownloading = false
        activeDownloadUrl = nil
        downloadBackgroundLease.end()
        finishCoreProgressObservation()
        downloadStatus = status
    }

    public func cancelActiveReaderWork() {
        if isAddingTocToShelf {
            tocAddGeneration += 1
            try? downloader.stop()
            isAddingTocToShelf = false
            activeTocAddUrl = nil
            activeTocAddOpensReader = false
            readerPendingTocUrl = nil
            tocBackgroundLease.end()
            finishCoreProgressObservation()
            downloadStatus = "停止しました"
        } else {
            cancelDownload()
        }
    }

    public func cancelDownload() {
        downloadGeneration += 1
        try? downloader.stop()
        isDownloading = false
        activeDownloadUrl = nil
        downloadBackgroundLease.end()
        activeReaderDownloadUrl = nil
        activeReaderDownloadStartChapter = nil
        pendingReaderDownloadStartChapter = nil
        finishCoreProgressObservation()
        if activeReaderDownloadUrl == nil { BackgroundNovelMaintenance.clearPendingFullDownload() }
        downloadStatus = "停止しました"
    }

    public func downloadFromDetectedToc() {
        addDetectedTocToShelfForReader()
    }

    private func stopQueuedTocRefreshForNovelDownload() {
        tocRefreshQueue.removeAll()
        queuedTocRefreshUrls.removeAll()
        guard isRefreshingToc || isTocRefreshWorkerRunning else { return }
        try? downloader.stop()
        activeTocRefreshUrl = nil
        isRefreshingToc = false
        isTocRefreshWorkerRunning = false
        tocRefreshStatus = "本文DLのため目次更新を停止しました"
    }

    public func handleIncomingNovelURL(_ incomingURL: URL) {
        let candidateURL: String?
        if incomingURL.scheme == "novelios", incomingURL.host == "add" {
            let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false)
            candidateURL = components?.queryItems?.first(where: { $0.name == "url" })?.value
        } else if ["http", "https"].contains(incomingURL.scheme?.lowercased() ?? "") {
            candidateURL = incomingURL.absoluteString
        } else {
            candidateURL = nil
        }
        guard let candidateURL, let candidate = TocMatcher.candidate(candidateURL) else { return }
        browserUrl = candidate.url
        tocUrl = candidate.url
        selectedTab = .library
        addDetectedTocToShelf(browserHTML: nil)
    }


    private func shouldUseBrowserChapterFetch(for url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "syosetu.org" || host == "www.syosetu.org"
    }

    private func browserChapterPayloads(
        for tocUrl: String,
        fromChapter chapterID: String?,
        readerBound: Bool
    ) async throws -> [BrowserChapterHTML] {
        let chapterSnapshots = chapters
        var urlByIndex: [String: URL] = [:]
        var missingURLs: [URL] = []

        let readerTargetIDs = readerBound ? readerWindowMissingChapterIDs(from: chapterID) : []
        for chapter in chapterSnapshots where !chapter.sourceUrl.isEmpty {
            guard let url = BrowserChapterPayloadBuilder.absoluteURL(base: tocUrl, href: chapter.sourceUrl) else { continue }
            urlByIndex[chapter.id] = url
            if !chapter.hasDownloadedBody && (!readerBound || readerTargetIDs.contains(chapter.id)) {
                missingURLs.append(url)
            }
        }

        guard !missingURLs.isEmpty else {
            return chapterSnapshots.map { chapter in
                BrowserChapterHTML(
                    index: chapter.id,
                    href: chapter.sourceUrl,
                    subtitle: chapter.subtitle,
                    chapter: nil,
                    subupdate: nil,
                    html: ""
                )
            }
        }

        downloadStatus = "ブラウザで本文を取得中… 0 / \(missingURLs.count)"
        let fetcher = BrowserChapterFetcher()
        var htmlByURL: [URL: String] = [:]
        var done = 0
        for url in missingURLs {
            let result = await fetcher.fetchHTML(urls: [url])
            if let html = result[url], !html.isEmpty {
                htmlByURL[url] = html
            }
            done += 1
            downloadStatus = "ブラウザで本文を取得中… \(done) / \(missingURLs.count)"
        }

        return chapterSnapshots.map { chapter in
            let url = urlByIndex[chapter.id]
            return BrowserChapterHTML(
                index: chapter.id,
                href: chapter.sourceUrl,
                subtitle: chapter.subtitle,
                chapter: nil,
                subupdate: nil,
                html: url.flatMap { htmlByURL[$0] } ?? ""
            )
        }
    }

    private func startDownload(tocUrl url: String, fromChapter chapterID: String? = nil, readerBound: Bool) {
        stopQueuedTocRefreshForNovelDownload()
        if let host = URL(string: url)?.host?.lowercased() {
            applySelectedParserEngine(for: host)
            rememberBrowserCookieHeaders()
            if let cookie = cookieHeader(for: host) {
                applyBrowserCookieToCore(host: host, cookie: cookie)
            }
        }

        downloadGeneration += 1
        let generation = downloadGeneration
        isDownloading = true
        activeDownloadUrl = url
        if readerBound {
            activeReaderDownloadUrl = url
            activeReaderDownloadStartChapter = chapterID
        }
        downloadStatus = readerBound ? "リーダーDL中…" : "ダウンロード中…"
        BackgroundNovelMaintenance.recordPendingFullDownload(url: url)
        downloadBackgroundLease.begin(named: readerBound ? "NovelDL.ReaderDownload" : "NovelDL.Download")
        beginCoreProgressObservation()

        Task {
            let out = Self.outputDir(for: url)
            do {
                try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
                let result: String
                if shouldUseBrowserChapterFetch(for: url) {
                    let browserChapters = try await browserChapterPayloads(
                        for: url,
                        fromChapter: chapterID,
                        readerBound: readerBound
                    )
                    let chaptersJson = try BrowserChapterPayloadBuilder.encode(browserChapters)
                    result = try await downloader.downloadFromBrowserChapters(
                        tocUrl: url,
                        chaptersJson: chaptersJson,
                        outputDir: out
                    )
                } else if readerBound {
                    result = try await downloader.downloadReaderCached(tocUrl: url, fromChapter: chapterID, outputDir: out)
                } else {
                    result = try await downloader.downloadCached(tocUrl: url, fromChapter: chapterID, outputDir: out)
                }
                await MainActor.run {
                    guard generation == downloadGeneration else { return }
                    isDownloading = false
                    activeDownloadUrl = nil
                    downloadBackgroundLease.end()
                    if readerBound {
                        activeReaderDownloadUrl = nil
                        activeReaderDownloadStartChapter = nil
                        readerBoundDownloadUrl = nil
                        readerPendingTocUrl = nil
                    }
                    BackgroundNovelMaintenance.clearPendingFullDownload(url: url)
                    finishCoreProgressObservation()
                    refreshLibrary(clearDatabaseCache: true)
                    if readerBound, let downloaded = novels.first(where: { $0.tocUrl == url }) {
                        selectNovel(downloaded, preferredChapterID: chapterID)
                    }
                    downloadStatus = "完了: \(result)"
                    if readerBound, let pending = pendingReaderDownloadStartChapter {
                        pendingReaderDownloadStartChapter = nil
                        startReaderBoundDownloadIfNeeded(from: pending)
                    }
                    runTocRefreshWorkerIfNeeded()
                }
            } catch {
                await MainActor.run {
                    guard generation == downloadGeneration else { return }
                    isDownloading = false
                    activeDownloadUrl = nil
                    downloadBackgroundLease.end()
                    if readerBound {
                        activeReaderDownloadUrl = nil
                        activeReaderDownloadStartChapter = nil
                    }
                    finishCoreProgressObservation()
                    if readerBound, let pending = pendingReaderDownloadStartChapter {
                        pendingReaderDownloadStartChapter = nil
                        downloadStatus = "選択話からDLを再開します"
                        startReaderBoundDownloadIfNeeded(from: pending)
                        return
                    }
                    if let host = URL(string: url)?.host?.lowercased() {
                        BrowserAccessCredentialStore.invalidate(host: host)
                    }
                    let message = error.localizedDescription
                    downloadStatus = message.contains("cancelled") ? "停止しました" : "エラー: \(message)"
                }
            }
        }
    }

    // MARK: - Core progress notifications

    private func beginCoreProgressObservation() {
        lastObservedDownloadCompleted = -1
        lastObservedProgressSignature = ""
        handleCoreDownloadProgress(NovelCoreBridge.callGetDownloadProgress())
    }

    private func handleCoreDownloadProgress(_ progress: DownloadProgress) {
        self.progress = progress
        let selectedBodyIsPending = selectedNovel != nil && selected?.hasDownloadedBody != true
        let signature = "\(progress.total):\(progress.completedCount):\(progress.running):\(progress.current)"
        if signature != lastObservedProgressSignature {
            lastObservedProgressSignature = signature
            if isAddingTocToShelf {
                handleTocAddAvailabilityNotification()
            }
            if isDownloading || progress.running {
                refreshLibraryForActiveCoreWork()
            }
        }
        if lastObservedDownloadCompleted < 0 {
            lastObservedDownloadCompleted = progress.completedCount
            if progress.completedCount > 0 || (progress.running && selectedBodyIsPending) {
                refreshReaderSelectionFromDownloadedDataIfNeeded(force: true)
            }
        } else if progress.completedCount != lastObservedDownloadCompleted {
            lastObservedDownloadCompleted = progress.completedCount
            refreshReaderSelectionFromDownloadedDataIfNeeded(force: true)
        } else if progress.running && selectedBodyIsPending {
            refreshReaderSelectionFromDownloadedDataIfNeeded(force: true)
        }
        if progress.total > 0 {
            let prefix = progress.hasFailures ? "一部失敗" : (progress.running ? "DL中…" : "完了")
            let status = progress.running
                ? "\(prefix) \(progress.statusText)  「\(progress.current)」"
                : "\(prefix): \(progress.statusText)"
            if isRefreshingToc && !isDownloading && !isAddingTocToShelf {
                tocRefreshStatus = status
            } else {
                downloadStatus = status
            }
        }
    }


    private func handleTocAddAvailabilityNotification() {
        guard let url = activeTocAddUrl else { return }
        let appeared = refreshLibraryForTocAvailability(url: url, openInReader: activeTocAddOpensReader)
        guard appeared else { return }
        if activeTocAddOpensReader {
            downloadStatus = isDownloading
                ? "目次取得を継続しながら本文DL中…"
                : "目次取得中。取得済み話から本文DLを開始します…"
        } else {
            downloadStatus = "ライブラリに追加済み。目次取得を継続中…"
        }
    }

    private func refreshLibraryForActiveCoreWork() {
        library.clearCache()
        let refreshedNovels = visibleNovels(sortedNovels(library.listNovels()))
        if refreshedNovels != novels { novels = refreshedNovels }
        guard let currentNovel = selectedNovel,
              let refreshedNovel = refreshedNovels.first(where: { isSameNovel($0, currentNovel) }) else {
            if selectedNovel == nil, let pendingURL = readerPendingTocUrl, selectedTab == .reader,
               let pendingNovel = refreshedNovels.first(where: { $0.tocUrl == pendingURL }) {
                selectNovel(pendingNovel)
                startReaderBoundDownloadIfNeeded(from: selected?.id)
            }
            return
        }
        selectedNovel = refreshedNovel
        if selectedTab == .reader {
            refreshReaderSelectionFromDownloadedDataIfNeeded(force: true)
        }
    }

    private func finishCoreProgressObservation() {
        lastObservedDownloadCompleted = -1
        lastObservedProgressSignature = ""
        progress = NovelCoreBridge.callGetDownloadProgress()
    }

    // MARK: - Helpers

    nonisolated static var docsDir: String {
    NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        ?? NSTemporaryDirectory()
}

nonisolated static var libraryRootDir: String {
    (docsDir as NSString).appendingPathComponent("novel_cache")
}

nonisolated static func outputDir(for tocUrl: String) -> String {
        let normalized = URL(string: tocUrl)?.host.map { host in
            let path = URL(string: tocUrl)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "novel"
            return "\(host)_\(path)"
        } ?? tocUrl
        let safe = normalized.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" { return ch }
            return "_"
        }
        let name = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return (libraryRootDir as NSString).appendingPathComponent(name.isEmpty ? "novel" : name)
    }
}

// MARK: - Root view

public struct NovelReaderRootView: View {
    @StateObject private var state = AppState()

    public init() {}

    private var mainTabSelection: Binding<AppMainTab> {
        Binding(
            get: { state.selectedTab == .reader ? .library : state.selectedTab },
            set: { state.selectedTab = $0 }
        )
    }

    public var body: some View {
        ZStack {
            TabView(selection: mainTabSelection) {
                NavigationStack {
                    LibraryPane(state: state)
                        .navigationTitle("Library")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .tabItem { Label("本棚", systemImage: "book") }
                .tag(AppMainTab.library)

                NavigationStack {
                    BrowserPane(state: state)
                        .navigationTitle("文庫")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .tabItem { Label("文庫", systemImage: "books.vertical") }
                .tag(AppMainTab.browser)

                NavigationStack {
                    NovelSearchPane(state: state)
                        .navigationTitle("検索")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .tabItem { Label("検索", systemImage: "magnifyingglass") }
                .tag(AppMainTab.search)

                NavigationStack {
                    AppSettingsPane(state: state)
                        .navigationTitle("設定")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(AppMainTab.settings)
            }

            if state.selectedTab == .reader {
                ReaderPane(state: state)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .sheet(item: $state.exportedTextArchive) { archive in
            TextZipShareSheet(archive: archive)
        }
        .onOpenURL { url in
            state.handleIncomingNovelURL(url)
        }
        .onChange(of: state.selectedTab) { _, tab in state.handleSelectedTabChanged(tab) }
        .task { state.boot() }
    }
}
