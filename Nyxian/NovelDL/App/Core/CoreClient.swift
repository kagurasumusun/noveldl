import Foundation
import Observation

/// Swift 6 bridge over the novel_core C ABI.
/// All core calls are synchronous + blocking → always hop through `run`.
///
/// Nyxian は Swift マクロ（@Observable 等）を展開できないため、
/// `@Observable` マクロが生成する中身（swift/lib/Macros ObservableMacro.swift の
/// 展開テンプレートと同一）を手書きで実装している。依存は Swift 標準ライブラリの
/// Observation モジュールのみ（Combine も使わない）。
final class CoreClient: Observable, @unchecked Sendable {
    static let shared = CoreClient()

    // MARK: observation plumbing (@Observable マクロ展開と同一)

    private let _$observationRegistrar = ObservationRegistrar()

    func access<Member>(keyPath: KeyPath<CoreClient, Member>) {
        _$observationRegistrar.access(self, keyPath: keyPath)
    }

    func withMutation<Member, MutationResult>(
        keyPath: KeyPath<CoreClient, Member>,
        _ mutation: () throws -> MutationResult
    ) rethrows -> MutationResult {
        try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
    }

    private var _progress = ProgressSnapshot(total: 0, done: 0, skipped: 0, failed: 0, running: false, current: "")
    var progress: ProgressSnapshot {
        get { access(keyPath: \.progress); return _progress }
        set { withMutation(keyPath: \.progress) { _progress = newValue } }
    }

    private var _library: [LibraryNovelItem] = []
    var library: [LibraryNovelItem] {
        get { access(keyPath: \.library); return _library }
        set { withMutation(keyPath: \.library) { _library = newValue } }
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    private let encoder = JSONEncoder()
    private var bootstrapped = false

    private init() {}

    // MARK: bootstrap

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        nc_http_apple_install()
        let root = Self.libraryRoot().path
        _ = call { novel_core_set_root_dir(root) }
        installProgressCallback()
        Task { await reloadLibrary() }
    }

    static func libraryRoot() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NovelLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: progress

    private func installProgressCallback() {
        novel_core_set_progress_callback({ json, _ in
            guard let json, let data = String(cString: json).data(using: .utf8) else { return }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let snapshot = try? decoder.decode(CoreEnvelope<ProgressSnapshot>.self, from: data)
            guard let p = snapshot?.result else { return }
            Task { @MainActor in
                CoreClient.shared.progress = p
            }
        }, nil)
    }

    // MARK: generic call helpers

    private func call(_ body: () -> UnsafeMutablePointer<CChar>?) -> Result<String, Error> {
        guard let cstr = body() else { return .failure(CoreError.emptyResponse) }
        defer { novel_core_string_free(cstr) }
        return .success(String(cString: cstr))
    }

    private func callVoid(_ body: () -> Void) {
        body()
    }

    private func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        _ body: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?
    ) async throws -> T {
        try await run {
            let result = self.call(body)
            switch result {
            case .failure(let err): throw err
            case .success(let payload):
                guard let data = payload.data(using: .utf8) else { throw CoreError.badJSON }
                let envelope = try self.decoder.decode(CoreEnvelope<T>.self, from: data)
                if envelope.ok, let value = envelope.result { return value }
                throw CoreError.message(envelope.error ?? "unknown core error")
            }
        }
    }

    private func run<T: Sendable>(_ op: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try op()
        }.value
    }

    // MARK: library

    func reloadLibrary() async {
        do {
            let list: LibraryListResult = try await decode(LibraryListResult.self) {
                novel_core_library_list(Self.libraryRoot().path)
            }
            await MainActor.run { self.library = list.novels }
        } catch {
            // surfaced through views polling `library`; keep quiet in background
        }
    }

    func novelDetail(_ novelId: String) async throws -> LibraryNovelDetail {
        try await decode(LibraryNovelDetail.self) {
            novel_core_library_novel(Self.libraryRoot().path, novelId)
        }
    }

    func refreshLibrary() async throws -> RefreshResult {
        try await decode(RefreshResult.self) {
            novel_core_library_refresh(Self.libraryRoot().path)
        }
    }

    func section(novelId: String, index: String) async throws -> SectionResult {
        try await decode(SectionResult.self) {
            novel_core_section_get(Self.libraryRoot().path, novelId, index)
        }
    }

    // MARK: downloads

    struct DownloadOptions: Sendable {
        var url: String
        var outputDir: String
        var episodes: Int = 0
        var fromIndex: String = ""
        var mode: String = "bulk"

        var json: String {
            """
            {"url":"\(url)","output_dir":"\(outputDir)","episodes":\(episodes),\
            "from_index":"\(fromIndex)","mode":"\(mode)"}
            """
        }
    }

    func fetchToc(url: String, outputDir: String) async throws -> FetchTocResult {
        let json = """
            {"url":"\(url)","output_dir":"\(outputDir)"}
            """
        return try await decode(FetchTocResult.self) {
            novel_core_fetch_toc(json)
        }
    }

    func download(_ options: DownloadOptions) async throws -> DownloadResult {
        try await decode(DownloadResult.self) {
            novel_core_download(options.json)
        }
    }

    func novelInfo(url: String) async throws -> NovelInfoResult {
        try await decode(NovelInfoResult.self) { novel_core_novel_info(url) }
    }

    func exportZip(novelId: String) async throws -> ExportResult {
        let json = """
            {"root_dir":"\(Self.libraryRoot().path)","novel_id":"\(novelId)","format":"aozora"}
            """
        return try await decode(ExportResult.self) {
            novel_core_export_txt_zip(json)
        }
    }

    // MARK: search

    func search(_ query: String, limit: UInt32 = 40) async throws -> [SearchResultItem] {
        struct SearchBox: Decodable, Sendable { let query: String; let results: [SearchResultItem] }
        let box: SearchBox = try await decode(SearchBox.self) {
            novel_core_search(query, limit)
        }
        return box.results
    }

    func searchSites() async throws -> [SearchSite] {
        struct SiteBox: Decodable, Sendable { let sites: [SearchSite] }
        let box: SiteBox = try await decode(SiteBox.self) { novel_core_search_sites() }
        return box.sites
    }

    // MARK: presets

    func loadPreset(domain: String) async throws -> String {
        struct Box: Decodable, Sendable { let yaml: String }
        let box: Box = try await decode(Box.self) { novel_core_load_parser_yaml(domain) }
        return box.yaml
    }

    func savePreset(domain: String, yaml: String) async throws {
        struct Box: Decodable, Sendable { let domain: String }
        _ = try await decode(Box.self) { novel_core_save_parser_yaml(domain, yaml) }
    }

    func deletePreset(domain: String) async throws {
        struct Box: Decodable, Sendable { let removed: Bool }
        _ = try await decode(Box.self) { novel_core_delete_parser_yaml(domain) }
    }

    func listPresets() async throws -> [String] {
        struct Entry: Decodable, Sendable { let domain: String; let source: String? }
        struct Box: Decodable, Sendable { let presets: [Entry] }
        let box: Box = try await decode(Box.self) { novel_core_list_parser_yamls() }
        return box.presets.map(\.domain)
    }

    // MARK: config knobs

    func setDownloadInterval(ms: UInt32) {
        novel_core_set_download_interval_ms(ms)
    }

    func setBrowserFetch(command: String?) {
        novel_core_set_browser_fetch_command(command)
    }

    func setDomainCookie(domain: String, cookie: String) {
        novel_core_set_domain_cookie(domain, cookie)
    }

    func cancel() {
        novel_core_cancel()
    }
}

enum CoreError: Error, LocalizedError {
    case emptyResponse
    case badJSON
    case message(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "The core returned no data."
        case .badJSON: return "The core returned malformed JSON."
        case .message(let text): return text
        }
    }
}
