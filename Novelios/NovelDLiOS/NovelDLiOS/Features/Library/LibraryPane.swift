import SwiftUI
import GRDB
import UIKit

// MARK: - LibraryEngine (singleton)

private struct DownloadedNovelRecord: Decodable, Sendable {
    let novel_id: String
    let title: String
    let author: String
    let toc_url: String
    let domain: String
    let episode_count: Int
    let updated_at: String
    let output_dir: String
    let storage_path: String
}

struct RenderedChapter: @unchecked Sendable {
    let attributed: NSAttributedString
    let characterCount: Int
}

@MainActor
final class LibraryEngine {
    static let shared = LibraryEngine()

    private var rootDir = ""
    private let dbCacheLimit = 12
    private var dbCache: [String: DatabaseQueue] = [:]
    private var dbCacheLRU: [String] = []

    private init() {}

    func clearCache() {
        dbCache.removeAll()
        dbCacheLRU.removeAll()
    }

    /// Call once at boot with the download library root, not a single DB path.
    func configure(rootDir: String) {
        self.rootDir = rootDir
        clearCache()
    }

    private func queue(for storagePath: String) -> DatabaseQueue? {
        if let cached = dbCache[storagePath] {
            touchCachedDatabase(storagePath)
            return cached
        }
        guard FileManager.default.fileExists(atPath: storagePath),
              let queue = try? DatabaseQueue(path: storagePath, configuration: readOnlyConfig()) else {
            return nil
        }
        while dbCache.count >= dbCacheLimit, let victim = dbCacheLRU.last {
            dbCache.removeValue(forKey: victim)
            dbCacheLRU.removeLast()
        }
        dbCache[storagePath] = queue
        touchCachedDatabase(storagePath)
        return queue
    }

    private func touchCachedDatabase(_ storagePath: String) {
        dbCacheLRU.removeAll { $0 == storagePath }
        dbCacheLRU.insert(storagePath, at: 0)
    }

    private func removeCachedDatabase(_ storagePath: String) {
        dbCache.removeValue(forKey: storagePath)
        dbCacheLRU.removeAll { $0 == storagePath }
    }

    private func queuesForNovelShards(_ novel: NovelMeta) -> [(path: String, queue: DatabaseQueue)] {
        NovelStorageLayout.shardDatabasePaths(for: novel).compactMap { path in
            guard let queue = queue(for: path) else { return nil }
            return (path, queue)
        }
    }

    private func hasTable(_ table: String, in db: Database) -> Bool {
        (try? db.tableExists(table)) ?? false
    }

    private func hasColumn(_ column: String, in table: String, db: Database) -> Bool {
        (try? String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)", arguments: [table]).contains(column)) ?? false
    }

    private func hasZstdDictionaryColumns(in db: Database) -> Bool {
        hasTable("zstd_dictionaries", in: db)
            && hasColumn("body_zstd_dict_id", in: "sections", db: db)
    }

    private func readOnlyConfig() -> Configuration {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(30)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only=ON")
            try db.execute(sql: "PRAGMA busy_timeout=30000")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
            try db.execute(sql: "PRAGMA mmap_size=268435456")
            try db.execute(sql: "PRAGMA cache_size=-32768")
        }
        return config
    }

    nonisolated private static func writableConfig() -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(30)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout=30000")
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
            try db.execute(sql: "PRAGMA mmap_size=268435456")
            try db.execute(sql: "PRAGMA cache_size=-32768")
        }
        return config
    }

    // MARK: Novel list

    func listNovels() -> [NovelMeta] {
        guard !rootDir.isEmpty else { return [] }
        let result = NovelCoreBridge.callListDownloadedNovels(rootDir: rootDir)
        guard result.hasPrefix("OK:"),
              let data = String(result.dropFirst(3)).data(using: .utf8),
              let records = try? JSONDecoder().decode([DownloadedNovelRecord].self, from: data) else {
            return []
        }
        return records.map { record in
            NovelMeta(
                id: record.novel_id,
                title: record.title,
                author: record.author,
                tocUrl: record.toc_url,
                domain: record.domain,
                episodeCount: record.episode_count,
                updatedAt: record.updated_at,
                outputDir: record.output_dir,
                storagePath: record.storage_path
            )
        }
    }

    // MARK: Chapter list for a novel

    func chaptersForNovel(_ novel: NovelMeta) -> [ChapterCard] {
        queuesForNovelShards(novel).flatMap { shard in
            (try? shard.queue.read { d in
                guard hasTable("sections", in: d) else { return [] }
                let useDictionaries = hasZstdDictionaryColumns(in: d)
                let sql = useDictionaries ? """
                    SELECT
                        s.chapter_index       AS id,
                        s.novel_id,
                        s.subtitle,
                        CASE WHEN s.body_downloaded != 0 THEN s.intro_xhtml_zstd ELSE NULL END AS intro_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN s.body_xhtml_zstd ELSE NULL END AS body_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN s.post_xhtml_zstd ELSE NULL END AS post_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN intro_dict.dictionary ELSE NULL END AS intro_zstd_dict,
                        CASE WHEN s.body_downloaded != 0 THEN body_dict.dictionary ELSE NULL END AS body_zstd_dict,
                        CASE WHEN s.body_downloaded != 0 THEN post_dict.dictionary ELSE NULL END AS post_zstd_dict,
                        s.source_signature,
                        s.source_url          AS sourceUrl,
                        s.body_downloaded,
                        ?                     AS storagePath
                    FROM sections s
                    LEFT JOIN zstd_dictionaries intro_dict
                      ON intro_dict.novel_id = s.novel_id AND intro_dict.dict_id = s.intro_zstd_dict_id
                    LEFT JOIN zstd_dictionaries body_dict
                      ON body_dict.novel_id = s.novel_id AND body_dict.dict_id = s.body_zstd_dict_id
                    LEFT JOIN zstd_dictionaries post_dict
                      ON post_dict.novel_id = s.novel_id AND post_dict.dict_id = s.post_zstd_dict_id
                    WHERE s.novel_id = ?
                    ORDER BY s.sort_key, s.chapter_index
                """ : """
                    SELECT
                        chapter_index       AS id,
                        novel_id,
                        subtitle,
                        CASE WHEN body_downloaded != 0 THEN intro_xhtml_zstd ELSE NULL END AS intro_xhtml_zstd,
                        CASE WHEN body_downloaded != 0 THEN body_xhtml_zstd ELSE NULL END AS body_xhtml_zstd,
                        CASE WHEN body_downloaded != 0 THEN post_xhtml_zstd ELSE NULL END AS post_xhtml_zstd,
                        NULL                AS intro_zstd_dict,
                        NULL                AS body_zstd_dict,
                        NULL                AS post_zstd_dict,
                        source_signature,
                        source_url          AS sourceUrl,
                        body_downloaded,
                        ?                   AS storagePath
                    FROM sections
                    WHERE novel_id = ?
                    ORDER BY sort_key, chapter_index
                """
                return try ChapterCard.fetchAll(d, sql: sql, arguments: [shard.path, novel.id])
            }) ?? []
        }
    }

    func deleteNovel(_ novel: NovelMeta, completion: @escaping @MainActor @Sendable () -> Void) {
        let rootDir = rootDir
        removeCachedDatabase(novel.storagePath)
        for path in NovelStorageLayout.shardDatabasePaths(for: novel) {
            removeCachedDatabase(path)
        }
        DispatchQueue.global(qos: .utility).async {
            Self.deleteNovelData(novel, rootDir: rootDir)
            Task { @MainActor in completion() }
        }
    }

    nonisolated private static func deleteNovelData(_ novel: NovelMeta, rootDir: String) {
        for shardPath in NovelStorageLayout.shardDatabasePaths(for: novel) {
            for attempt in 0..<5 {
                do {
                    let db = try DatabaseQueue(path: shardPath, configuration: writableConfig())
                    try db.write { d in
                        try d.execute(sql: "PRAGMA busy_timeout=30000")
                        if try d.tableExists("sections_fts") {
                            try d.execute(sql: "DELETE FROM sections_fts WHERE novel_id = ?", arguments: [novel.id])
                        }
                        if try d.tableExists("images") {
                            try d.execute(sql: "DELETE FROM images WHERE novel_id = ?", arguments: [novel.id])
                        }
                        if try d.tableExists("sections") {
                            try d.execute(sql: "DELETE FROM sections WHERE novel_id = ?", arguments: [novel.id])
                        }
                    }
                    break
                } catch {
                    guard attempt < 4 else { break }
                    Thread.sleep(forTimeInterval: 0.35 * Double(attempt + 1))
                }
            }
        }

        if FileManager.default.fileExists(atPath: novel.storagePath) {
            for attempt in 0..<5 {
                do {
                    let db = try DatabaseQueue(path: novel.storagePath, configuration: writableConfig())
                    try db.write { d in
                        try d.execute(sql: "PRAGMA busy_timeout=30000")
                        if try d.tableExists("novels") {
                            try d.execute(sql: "DELETE FROM novels WHERE novel_id = ?", arguments: [novel.id])
                        }
                    }
                    break
                } catch {
                    guard attempt < 4 else { break }
                    Thread.sleep(forTimeInterval: 0.35 * Double(attempt + 1))
                }
            }
        }

        let shardDir = NovelStorageLayout.shardDirectory(for: novel)
        try? FileManager.default.removeItem(at: shardDir)

        let rootURL = URL(fileURLWithPath: rootDir).standardizedFileURL
        let outputURL = URL(fileURLWithPath: novel.outputDir).standardizedFileURL
        guard outputURL.path != rootURL.path,
              outputURL.path.hasPrefix(rootURL.path + "/") else {
            return
        }
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: Search within a novel

    func searchChapters(_ query: String, novel: NovelMeta) -> [ChapterCard] {
        guard !query.isEmpty else { return chaptersForNovel(novel) }
        return queuesForNovelShards(novel).flatMap { shard in
            (try? shard.queue.read { d in
                guard hasTable("sections", in: d), hasTable("sections_fts", in: d) else { return [] }
                let useDictionaries = hasZstdDictionaryColumns(in: d)
                let sql = useDictionaries ? """
                    SELECT
                        s.chapter_index     AS id,
                        s.novel_id,
                        s.subtitle,
                        CASE WHEN s.body_downloaded != 0 THEN s.intro_xhtml_zstd ELSE NULL END AS intro_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN s.body_xhtml_zstd ELSE NULL END AS body_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN s.post_xhtml_zstd ELSE NULL END AS post_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN intro_dict.dictionary ELSE NULL END AS intro_zstd_dict,
                        CASE WHEN s.body_downloaded != 0 THEN body_dict.dictionary ELSE NULL END AS body_zstd_dict,
                        CASE WHEN s.body_downloaded != 0 THEN post_dict.dictionary ELSE NULL END AS post_zstd_dict,
                        s.source_signature,
                        s.source_url        AS sourceUrl,
                        s.body_downloaded,
                        ?                   AS storagePath
                    FROM sections s
                    JOIN sections_fts f
                      ON s.novel_id = f.novel_id AND s.chapter_index = f.chapter_index
                    LEFT JOIN zstd_dictionaries intro_dict
                      ON intro_dict.novel_id = s.novel_id AND intro_dict.dict_id = s.intro_zstd_dict_id
                    LEFT JOIN zstd_dictionaries body_dict
                      ON body_dict.novel_id = s.novel_id AND body_dict.dict_id = s.body_zstd_dict_id
                    LEFT JOIN zstd_dictionaries post_dict
                      ON post_dict.novel_id = s.novel_id AND post_dict.dict_id = s.post_zstd_dict_id
                    WHERE s.novel_id = ? AND sections_fts MATCH ?
                    ORDER BY rank
                """ : """
                    SELECT
                        s.chapter_index     AS id,
                        s.novel_id,
                        s.subtitle,
                        CASE WHEN s.body_downloaded != 0 THEN s.intro_xhtml_zstd ELSE NULL END AS intro_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN s.body_xhtml_zstd ELSE NULL END AS body_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN s.post_xhtml_zstd ELSE NULL END AS post_xhtml_zstd,
                        NULL                AS intro_zstd_dict,
                        NULL                AS body_zstd_dict,
                        NULL                AS post_zstd_dict,
                        s.source_signature,
                        s.source_url        AS sourceUrl,
                        s.body_downloaded,
                        ?                   AS storagePath
                    FROM sections s
                    JOIN sections_fts f
                      ON s.novel_id = f.novel_id AND s.chapter_index = f.chapter_index
                    WHERE s.novel_id = ? AND sections_fts MATCH ?
                    ORDER BY rank
                """
                return try ChapterCard.fetchAll(d, sql: sql, arguments: [shard.path, novel.id, query])
            }) ?? []
        }
    }

    // MARK: Render (decompress + parse)

    func render(
        chapter: ChapterCard,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        fontName: String,
        fg: UIColor,
        showImages: Bool
    ) -> NSAttributedString {
        Self.renderChapter(
            chapter: chapter,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            fontName: fontName,
            fg: fg,
            showImages: showImages
        ).attributed
    }

    nonisolated static func renderChapter(
        chapter: ChapterCard,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        fontName: String,
        fgRGBA: [Double],
        brightness: Double,
        showImages: Bool
    ) -> RenderedChapter {
        let base = UIColor(
            red: CGFloat(fgRGBA.indices.contains(0) ? fgRGBA[0] : 0.72),
            green: CGFloat(fgRGBA.indices.contains(1) ? fgRGBA[1] : 0.72),
            blue: CGFloat(fgRGBA.indices.contains(2) ? fgRGBA[2] : 0.72),
            alpha: CGFloat(fgRGBA.indices.contains(3) ? fgRGBA[3] : 1.0)
        )
        return renderChapter(
            chapter: chapter,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            fontName: fontName,
            fg: base.withAlphaComponent(brightness),
            showImages: showImages
        )
    }

    nonisolated static func renderChapter(
        chapter: ChapterCard,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        fontName: String,
        fg: UIColor,
        showImages: Bool
    ) -> RenderedChapter {
        guard chapter.hasDownloadedBody else {
            return RenderedChapter(attributed: NSAttributedString(string: ""), characterCount: 0)
        }

        let parts: [String?] = [
            decompress(chapter.intro_xhtml_zstd, dictionary: chapter.intro_zstd_dict),
            decompress(chapter.body_xhtml_zstd, dictionary: chapter.body_zstd_dict),
            decompress(chapter.post_xhtml_zstd, dictionary: chapter.post_zstd_dict)
        ]
        let xhtml = parts.compactMap { $0 }.joined(separator: "\n")

        if xhtml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return RenderedChapter(attributed: NSAttributedString(string: ""), characterCount: 0)
        }
        let attributed = ChapterParser().parse(
            xhtml: xhtml,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            fg: fg,
            showImages: showImages,
            fontName: fontName
        )
        return RenderedChapter(
            attributed: attributed,
            characterCount: attributed.string.unicodeScalars.reduce(0) { count, scalar in
                CharacterSet.whitespacesAndNewlines.contains(scalar) ? count : count + 1
            }
        )
    }

    // MARK: zstd decompression

    /// Decompress a nullable blob. Returns nil when blob is nil or decompression fails.
    nonisolated private static func decompress(_ data: Data?, dictionary: Data? = nil) -> String? {
        NovelCoreBridge.tryDecompressZstdData(data, dictionary: dictionary)
    }

    /// Non-optional overload for the required body blob.
    nonisolated private static func decompress(_ data: Data, dictionary: Data? = nil) -> String? {
        NovelCoreBridge.tryDecompressZstdData(data, dictionary: dictionary)
    }
}

// MARK: - LibraryPane (entry point: novel list)

struct LibraryPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        NovelListView(state: state)
    }
}

// MARK: - Novel list

struct NovelListView: View {
    @ObservedObject var state: AppState
    @State private var query = ""

    private var filteredNovels: [NovelMeta] {
        guard !query.isEmpty else { return state.novels }
        return state.novels.filter { novel in
            novel.displayTitle.localizedCaseInsensitiveContains(query)
                || novel.author.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            if !state.textExportStatus.isEmpty {
                Label(state.textExportStatus, systemImage: state.isExportingTextZip ? "archivebox" : "square.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            if filteredNovels.isEmpty {
                ContentUnavailableView(
                    "小説がありません",
                    systemImage: "books.vertical",
                    description: Text("文庫タブから小説をダウンロードしてください")
                )
            } else {
                List {
                    ForEach(filteredNovels) { novel in
                        Button { state.openNovelInReader(novel) } label: {
                            NovelRow(novel: novel, progressText: state.readingProgressText(for: novel))
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { state.deleteNovel(novel) } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button { state.openNovelInReader(novel) } label: { Label("読む", systemImage: "book") }
                            Button { state.downloadAllChapters(for: novel) } label: { Label("全話ダウンロード", systemImage: "arrow.down.circle") }
                            Button { state.exportTextZip(for: novel) } label: { Label("TXT ZIP書き出し", systemImage: "archivebox") }
                                .disabled(state.isExportingTextZip)
                            Button(role: .destructive) { state.deleteNovel(novel) } label: { Label("削除", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("並び替え", selection: $state.librarySort) {
                        ForEach(LibrarySortMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Divider()
                    Button { state.refreshLibraryAndUpdateTocs() } label: { Label("再読み込み", systemImage: "arrow.clockwise") }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .onChange(of: state.librarySort) { _, mode in state.sortLibrary(mode) }
            }
            ToolbarItem(placement: .principal) {
                Text("本棚").font(.headline).foregroundStyle(.white)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { state.refreshLibraryAndUpdateTocs() } label: {
                    Image(systemName: "sun.max")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("本棚")
                .font(.title2.weight(.bold))
            Spacer()
            Text("\(state.novelCount)作品 / \(state.downloadCount)話")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("検索", text: $query)
                .textInputAutocapitalization(.never)
        }
        .font(.body)
        .padding(11)
        .background(Color.white.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}

private struct NovelRow: View {
    let novel: NovelMeta
    let progressText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(novel.displayTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if novel.episodeCount > 0 {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Spacer()
                Text(relativeUpdatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("最新: \(novel.episodeCount)話")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(novel.author.isEmpty ? hostText : novel.author)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if let progressText {
                Label(progressText, systemImage: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.blue.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        .listRowBackground(Color.black)
    }

    private var hostText: String {
        URL(string: novel.tocUrl)?.host ?? "小説サイト"
    }

    private var relativeUpdatedText: String {
        if novel.updatedAt.isEmpty { return "—" }
        return novel.updatedAt
    }
}

struct TextZipShareSheet: View {
    let archive: ExportedTextArchive

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "archivebox")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
                Text("TXT ZIPを書き出しました")
                    .font(.headline)
                Text(archive.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: archive.url) {
                    Label("共有 / 保存", systemImage: "square.and.arrow.up")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .navigationTitle("書き出し")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Chapter list for one novel

struct ChapterListView: View {
    @ObservedObject var state: AppState
    let novel: NovelMeta

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                TextField("話を検索…", text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { state.runSearch() }
                Button("検索") { state.runSearch() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            HStack(spacing: 10) {
                Button { state.downloadAllChapters(for: novel) } label: {
                    Label("全話ダウンロード", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isDownloading)

                Button { state.exportTextZip(for: novel) } label: {
                    Label("TXT ZIP", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                .disabled(state.isExportingTextZip)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal)
            .padding(.vertical, 8)

            if state.chapters.isEmpty {
                ContentUnavailableView(
                    "話がありません",
                    systemImage: "doc.text",
                    description: Text("検索語を変えるかダウンロードし直してください")
                )
            } else {
                List(state.chapters) { c in
                    Button {
                        state.selectChapter(c)
                        state.selectedTab = .reader
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.subtitle)
                                    .lineLimit(2)
                                    .foregroundStyle(state.selected?.id == c.id ? .blue : .primary)
                                Text("#\(c.id)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if c.hasDownloadedBody {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            } else {
                                Image(systemName: "icloud.and.arrow.down")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            if state.selected?.id == c.id {
                                Image(systemName: "largecircle.fill.circle")
                                    .foregroundStyle(.blue)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(novel.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    state.deselectNovel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("小説一覧")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { state.downloadAllChapters(for: novel) } label: {
                        Label("全話ダウンロード", systemImage: "arrow.down.circle")
                    }
                    Button { state.exportTextZip(for: novel) } label: {
                        Label("TXT ZIP書き出し", systemImage: "archivebox")
                    }
                    .disabled(state.isExportingTextZip)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            // Load chapters if not already loaded for this novel
            if state.selectedNovel?.id != novel.id || state.chapters.isEmpty {
                state.selectNovel(novel)
            }
        }
    }
}