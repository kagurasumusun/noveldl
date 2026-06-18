import SwiftUI
import WebKit

@MainActor
enum PrivateBrowserPrewarmer {
    private static var warmed = false

    static func prewarm() {
        guard !warmed else { return }
        warmed = true
        DispatchQueue.main.async {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.loadHTMLString("<html></html>", baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                webView.stopLoading()
            }
        }
    }
}


// MARK: - TOC URL matcher

struct TocCandidate: Equatable, Sendable {
    let url: String
    let host: String
}

enum TocMatcher {
    static func candidate(_ input: String) -> TocCandidate? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = components.host?.lowercased() else { return nil }
        components.scheme = scheme
        components.host = rawHost
        components.fragment = nil
        let path = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = components.percentEncodedQuery ?? ""

        let isMatch: Bool
        switch rawHost {
        case "ncode.syosetu.com", "novel18.syosetu.com", "noc.syosetu.com", "mnlt.syosetu.com", "mid.syosetu.com":
            if let ncode = path.firstMatch(of: #"^(n\d+[a-z]+)(?:/\d+)?$"#, options: [.regularExpression, .caseInsensitive]) {
                components.percentEncodedPath = "/\(ncode.lowercased())/"
                components.percentEncodedQuery = nil
                isMatch = true
            } else {
                isMatch = false
            }
        case "kakuyomu.jp", "www.kakuyomu.jp":
            if let workID = path.firstMatch(of: #"^works/(\d+)(?:/episodes/\d+)?$"#, options: .regularExpression) {
                components.percentEncodedPath = "/works/\(workID)"
                components.percentEncodedQuery = nil
                isMatch = true
            } else {
                isMatch = false
            }
        case "novelup.plus", "www.novelup.plus":
            if let storyID = path.firstMatch(of: #"^story/(\d+)(?:/\d+)?$"#, options: .regularExpression) {
                components.percentEncodedPath = "/story/\(storyID)"
                components.percentEncodedQuery = nil
                isMatch = true
            } else {
                isMatch = false
            }
        case "syosetu.org", "www.syosetu.org":
            if let novelID = path.firstMatch(of: #"^novel/(\d+)(?:/\d+)?$"#, options: .regularExpression) {
                components.percentEncodedPath = "/novel/\(novelID)/"
                components.percentEncodedQuery = nil
                isMatch = true
            } else {
                isMatch = false
            }
        case "hameln.jp", "www.hameln.jp":
            isMatch = query.isEmpty && path.range(of: #"^n/\d+$"#, options: .regularExpression) != nil
        case "www.akatsuki-novels.com":
            isMatch = path == "stories/index" && query.range(of: #"(^|&)novel_id~\d+($|&)"#, options: .regularExpression) != nil
        case "www.mai-net.net":
            isMatch = path == "bbs/sst/sst.php"
                && query.contains("act=dump")
                && query.range(of: #"(^|&)all=\d+"#, options: .regularExpression) != nil
        default:
            isMatch = false
        }
        guard isMatch, let normalized = components.url?.absoluteString else { return nil }
        return TocCandidate(url: normalized, host: rawHost)
    }

    static func match(_ input: String) -> Bool {
        candidate(input) != nil
    }
}


private extension String {
    func firstMatch(of pattern: String, options: NSString.CompareOptions = []) -> String? {
        var regexOptions: NSRegularExpression.Options = []
        if options.contains(.caseInsensitive) { regexOptions.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions),
              let result = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else {
            return nil
        }
        if result.numberOfRanges > 1, let captureRange = Range(result.range(at: 1), in: self) {
            return String(self[captureRange])
        }
        guard let matchRange = Range(result.range, in: self) else { return nil }
        return String(self[matchRange])
    }
}

// MARK: - Supported novel sites

private struct BrowserLoadRequest: Equatable, Sendable {
    let id = UUID()
    let url: String
}

private enum BrowserCommandAction: Equatable, Sendable {
    case back
    case forward
    case reload
}

private struct BrowserCommand: Equatable, Sendable {
    let id = UUID()
    let action: BrowserCommandAction
}

private struct SupportedNovelSite: Identifiable, Sendable {
    let id: String
    let name: String
    let topUrl: String
    let rankingUrl: String
    let categoryUrl: String

    static let all: [SupportedNovelSite] = [
        SupportedNovelSite(
            id: "ncode.syosetu.com",
            name: "小説家になろう",
            topUrl: "https://ncode.syosetu.com/",
            rankingUrl: "https://yomou.syosetu.com/rank/top/",
            categoryUrl: "https://yomou.syosetu.com/search.php"
        ),
        SupportedNovelSite(
            id: "novel18.syosetu.com",
            name: "ムーンライトノベルズ",
            topUrl: "https://novel18.syosetu.com/",
            rankingUrl: "https://yomou.syosetu.com/rank/r18list/type/quarter/",
            categoryUrl: "https://yomou.syosetu.com/search.php?notnizi=1"
        ),
        SupportedNovelSite(
            id: "noc.syosetu.com",
            name: "ノクターンノベルズ",
            topUrl: "https://noc.syosetu.com/",
            rankingUrl: "https://yomou.syosetu.com/rank/r18list/type/quarter/",
            categoryUrl: "https://yomou.syosetu.com/search.php?notnizi=1"
        ),
        SupportedNovelSite(
            id: "mnlt.syosetu.com",
            name: "ムーンライト(女性向け)",
            topUrl: "https://mnlt.syosetu.com/",
            rankingUrl: "https://yomou.syosetu.com/rank/r18list/type/quarter/",
            categoryUrl: "https://yomou.syosetu.com/search.php?notnizi=1"
        ),
        SupportedNovelSite(
            id: "mid.syosetu.com",
            name: "ミッドナイトノベルズ",
            topUrl: "https://mid.syosetu.com/",
            rankingUrl: "https://yomou.syosetu.com/rank/r18list/type/quarter/",
            categoryUrl: "https://yomou.syosetu.com/search.php?notnizi=1"
        ),
        SupportedNovelSite(
            id: "kakuyomu.jp",
            name: "カクヨム",
            topUrl: "https://kakuyomu.jp/",
            rankingUrl: "https://kakuyomu.jp/rankings",
            categoryUrl: "https://kakuyomu.jp/search"
        ),
        SupportedNovelSite(
            id: "novelup.plus",
            name: "ノベルアップ＋",
            topUrl: "https://novelup.plus/",
            rankingUrl: "https://novelup.plus/ranking",
            categoryUrl: "https://novelup.plus/search"
        ),
        SupportedNovelSite(
            id: "syosetu.org",
            name: "ハーメルン",
            topUrl: "https://syosetu.org/",
            rankingUrl: "https://syosetu.org/?mode=rank",
            categoryUrl: "https://syosetu.org/search/"
        ),
        SupportedNovelSite(
            id: "www.akatsuki-novels.com",
            name: "暁",
            topUrl: "https://www.akatsuki-novels.com/",
            rankingUrl: "https://www.akatsuki-novels.com/stories/ranking",
            categoryUrl: "https://www.akatsuki-novels.com/stories/search"
        ),
        SupportedNovelSite(
            id: "www.mai-net.net",
            name: "Arcadia",
            topUrl: "https://www.mai-net.net/",
            rankingUrl: "https://www.mai-net.net/bbs/sst/sst.php",
            categoryUrl: "https://www.mai-net.net/bbs/sst/sst.php"
        )
    ]
}

// MARK: - BrowserPane view

struct BrowserPane: View {
    @ObservedObject var state: AppState
    @State private var loadRequest: BrowserLoadRequest?
    @State private var browserCommand: BrowserCommand?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var showDetectedMenu = false
    @State private var finishedUrl = ""
    @State private var finishedTitle = ""
    @State private var finishedHTML = ""
    @State private var lastPromptedTocUrl = ""
    @State private var crossSiteSearchQuery = ""
    @State private var crossSiteSearchResults: [NovelSearchResultItem] = []
    @State private var crossSiteSearchSites: [SupportedSearchSite] = []
    @State private var crossSiteSearchStatus = ""
    @State private var isCrossSiteSearching = false
    @State private var crossSiteSearchRequestID = UUID()
    @State private var crossSiteSearchTask: Task<Void, Never>?
    @State private var crossSiteSearchRequestedLimit = 40
    @State private var crossSiteSearchDisplayLimit = 20
    @State private var crossSiteSearchLastQuery = ""
    @State private var showCrossSiteSearchSites = false

    private let crossSiteSearchInitialLimit = 40
    private let crossSiteSearchPageSize = 20
    private let crossSiteSearchFetchStep = 40
    private let crossSiteSearchMaxLimit = 180

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if loadRequest == nil {
                siteDirectory
            } else {
                PrivateBrowser(
                    currentUrl: $state.browserUrl,
                    cookieHeaders: $state.browserCookieHeaders,
                    loadRequest: $loadRequest,
                    command: $browserCommand,
                    canGoBack: $canGoBack,
                    canGoForward: $canGoForward,
                    finishedUrl: $finishedUrl,
                    finishedTitle: $finishedTitle,
                    finishedHTML: $finishedHTML,
                    adBlockEnabled: state.browserAdBlockEnabled
                )
                .ignoresSafeArea(edges: .bottom)
            }
            browserBottomBar
            if showDetectedMenu {
                detectedNovelOverlay
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.86), value: showDetectedMenu)
        .foregroundStyle(.white)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if loadRequest != nil {
                    Button { closeBrowser() } label: { Image(systemName: "house") }
                        .foregroundStyle(.white)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("文庫").font(.headline).foregroundStyle(.white)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !state.tocUrl.isEmpty {
                    Button { withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.86)) { showDetectedMenu = true } } label: { Image(systemName: "book.badge.plus") }
                        .foregroundStyle(.white)
                }
            }
        }
        .onChange(of: state.browserCookieHeaders) { _, _ in state.rememberBrowserCookieHeaders() }
        .onChange(of: finishedUrl) { _, url in
            guard let candidate = TocMatcher.candidate(url) else {
                state.tocUrl = ""
                return
            }
            state.tocUrl = candidate.url
            if candidate.url != lastPromptedTocUrl {
                lastPromptedTocUrl = candidate.url
                withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.86)) {
                    showDetectedMenu = true
                }
            }
        }
    }

    private var detectedNovelOverlay: some View {
        VStack {
            DetectedNovelMenu(
                title: state.tocUrl.isEmpty ? "検出した小説の名前" : detectedNovelTitle,
                readNow: {
                    showDetectedMenu = false
                    state.addDetectedTocToShelfForReader(browserHTML: browserHTMLForDetectedToc)
                },
                addToShelf: {
                    showDetectedMenu = false
                    state.addDetectedTocToShelf(browserHTML: browserHTMLForDetectedToc)
                },
                cancel: { showDetectedMenu = false }
            )
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private var detectedNovelTitle: String {
        let cleaned = BrowserTitleCleaner.novelTitle(from: finishedTitle, fallbackUrl: state.tocUrl)
        return cleaned.isEmpty ? "検出した小説の名前" : "『\(cleaned)』"
    }

    private var browserHTMLForDetectedToc: String? {
        let trimmedHTML = finishedHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHTML.isEmpty,
              let displayedToc = TocMatcher.candidate(finishedUrl)?.url,
              displayedToc == state.tocUrl,
              normalizedURLString(finishedUrl) == normalizedURLString(state.tocUrl) else {
            return nil
        }
        return finishedHTML
    }

    private func normalizedURLString(_ value: String) -> String? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        components.fragment = nil
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        return components.url?.absoluteString
    }

    private var siteDirectory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("対応小説サイト")
                        .font(.system(size: 24, weight: .bold))
                    Text("サイトを選ぶと内蔵ブラウザで開きます。横断検索は専用の検索タブから利用できます。")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .padding(.top, 34)

                VStack(alignment: .leading, spacing: 8) {
                    Text("サイト一覧")
                        .font(.system(size: 20, weight: .bold))
                    Text("探すサイトが決まっている場合はこちらから直接開けます。")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .padding(.top, 4)

                LazyVStack(spacing: 10) {
                    ForEach(SupportedNovelSite.all) { site in
                        siteRow(site)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, 150)
        }
    }

    private var crossSiteSearchPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Label("小説を横断検索", systemImage: "magnifyingglass.circle.fill")
                    .font(.system(size: 21, weight: .bold))
                Text("サイト一覧とは分離した検索エリアです。結果は必要な件数だけ取得し、表示行も段階的に増やします。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
            }

            HStack(spacing: 8) {
                TextField("タイトル・作者・キーワード", text: $crossSiteSearchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .onSubmit { runCrossSiteSearch(reset: true) }

                Button { runCrossSiteSearch(reset: true) } label: {
                    if isCrossSiteSearching {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .frame(width: 46, height: 44)
                .background(.blue.opacity(isCrossSiteSearching ? 0.35 : 0.88), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .disabled(isCrossSiteSearching)
            }

            supportedSiteDisclosure

            if !crossSiteSearchStatus.isEmpty {
                Text(crossSiteSearchStatus)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.66))
            }

            if !crossSiteSearchResults.isEmpty {
                LazyVStack(spacing: 8) {
                    ForEach(visibleCrossSiteSearchResults) { result in
                        crossSiteSearchResultRow(result)
                    }
                    crossSiteSearchLoadMoreRow
                }
            }
        }
        .padding(15)
        .background(
            LinearGradient(
                colors: [.blue.opacity(0.22), .white.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.blue.opacity(0.22), lineWidth: 1)
        )
        .onAppear(perform: loadCrossSiteSearchSitesIfNeeded)
        .onDisappear {
            crossSiteSearchTask?.cancel()
            crossSiteSearchTask = nil
        }
    }

    private var visibleCrossSiteSearchResults: [NovelSearchResultItem] {
        Array(crossSiteSearchResults.prefix(crossSiteSearchDisplayLimit))
    }

    private var supportedSiteDisclosure: some View {
        DisclosureGroup(isExpanded: $showCrossSiteSearchSites) {
            if crossSiteSearchSites.isEmpty {
                Text("対応サイトを読み込み中…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.54))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(crossSiteSearchSites) { site in
                        Text(site.label)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.10), in: Capsule())
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            Text("検索対象サイト")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .tint(.white.opacity(0.72))
    }

    @ViewBuilder
    private var crossSiteSearchLoadMoreRow: some View {
        if crossSiteSearchDisplayLimit < crossSiteSearchResults.count || crossSiteSearchRequestedLimit < crossSiteSearchMaxLimit {
            Button { loadMoreCrossSiteSearchResults() } label: {
                HStack(spacing: 8) {
                    if isCrossSiteSearching {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text(loadMoreSearchTitle)
                }
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isCrossSiteSearching)
            .onAppear {
                guard crossSiteSearchDisplayLimit < crossSiteSearchResults.count else { return }
                crossSiteSearchDisplayLimit = min(crossSiteSearchDisplayLimit + crossSiteSearchPageSize, crossSiteSearchResults.count)
            }
        }
    }

    private var loadMoreSearchTitle: String {
        if crossSiteSearchDisplayLimit < crossSiteSearchResults.count {
            return "さらに表示"
        }
        return "さらに検索"
    }

    private func crossSiteSearchResultRow(_ result: NovelSearchResultItem) -> some View {
        Button { open(result.url) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(result.title.isEmpty ? result.url : result.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(result.site)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.74))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.10), in: Capsule())
                }
                if let author = result.author, !author.isEmpty {
                    Text("作者: \(author)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                if let summary = result.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let updated = result.updated, !updated.isEmpty { Text(updated) }
                    if let episodeCount = result.episodeCount { Text("\(episodeCount)話") }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.44))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func siteRow(_ site: SupportedNovelSite) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { open(site.topUrl) } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(site.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text(site.id)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                siteActionButton("トップ", systemImage: "house", url: site.topUrl)
                siteActionButton("ランキング", systemImage: "crown", url: site.rankingUrl)
                siteActionButton("検索", systemImage: "magnifyingglass", url: site.categoryUrl)
            }
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func siteActionButton(_ title: String, systemImage: String, url: String) -> some View {
        Button { open(url) } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.88))
    }

    private var browserBottomBar: some View {
        VStack(spacing: 0) {
            if state.isDownloading {
                VStack(spacing: 5) {
                    ProgressView(value: state.progress.total > 0 ? state.progress.progressFraction : nil)
                        .tint(state.progress.hasFailures ? .orange : .blue)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.downloadStatus)
                                .font(.caption2)
                                .foregroundStyle(state.progress.hasFailures ? .orange : .secondary)
                                .lineLimit(2)
                            if !state.progress.current.isEmpty {
                                Text(state.progress.current)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("停止") { state.cancelDownload() }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
            HStack(spacing: 28) {
                browserBarButton("house") { closeBrowser() }
                    .disabled(loadRequest == nil)
                browserBarButton("chevron.left") { browserCommand = BrowserCommand(action: .back) }
                    .disabled(loadRequest == nil || !canGoBack)
                browserBarButton("chevron.right") { browserCommand = BrowserCommand(action: .forward) }
                    .disabled(loadRequest == nil || !canGoForward)
                browserBarButton("arrow.clockwise") { browserCommand = BrowserCommand(action: .reload) }
                    .disabled(loadRequest == nil)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            Divider().overlay(.white.opacity(0.12))
            HStack(spacing: 46) {
                Label("本棚", systemImage: "book")
                Label("文庫", systemImage: "books.vertical")
                Label("ヘルプ", systemImage: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .background(.black.opacity(0.92))
    }

    private func browserBarButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .regular))
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadCrossSiteSearchSitesIfNeeded() {
        guard crossSiteSearchSites.isEmpty else { return }
        Task.detached(priority: .utility) {
            let sites = (try? NovelCoreBridge.callSupportedSearchSites()) ?? []
            await MainActor.run {
                crossSiteSearchSites = sites
            }
        }
    }

    private func runCrossSiteSearch(reset: Bool) {
        let query = crossSiteSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            crossSiteSearchStatus = "検索語を入力してください"
            crossSiteSearchResults = []
            crossSiteSearchDisplayLimit = crossSiteSearchPageSize
            return
        }
        if reset || query != crossSiteSearchLastQuery {
            crossSiteSearchLastQuery = query
            crossSiteSearchRequestedLimit = crossSiteSearchInitialLimit
            crossSiteSearchDisplayLimit = crossSiteSearchPageSize
            crossSiteSearchResults = []
        }
        crossSiteSearchTask?.cancel()
        let requestID = UUID()
        let limit = min(crossSiteSearchRequestedLimit, crossSiteSearchMaxLimit)
        crossSiteSearchRequestID = requestID
        isCrossSiteSearching = true
        crossSiteSearchStatus = "検索中…（最大 \(limit) 件）"
        crossSiteSearchTask = Task.detached(priority: .userInitiated) {
            do {
                let payload = try NovelCoreBridge.callSearchNovels(query: query, limit: UInt32(limit))
                await MainActor.run {
                    guard crossSiteSearchRequestID == requestID else { return }
                    crossSiteSearchResults = payload.results
                    crossSiteSearchDisplayLimit = min(max(crossSiteSearchDisplayLimit, crossSiteSearchPageSize), payload.results.count)
                    crossSiteSearchStatus = payload.results.isEmpty
                        ? "該当作品は見つかりませんでした"
                        : "\(min(crossSiteSearchDisplayLimit, payload.results.count)) / \(payload.results.count) 件を表示中（取得上限 \(limit) 件）"
                    isCrossSiteSearching = false
                }
            } catch {
                await MainActor.run {
                    guard crossSiteSearchRequestID == requestID else { return }
                    if crossSiteSearchResults.isEmpty { crossSiteSearchResults = [] }
                    crossSiteSearchStatus = "検索エラー: \(error.localizedDescription)"
                    isCrossSiteSearching = false
                }
            }
        }
    }

    private func loadMoreCrossSiteSearchResults() {
        if crossSiteSearchDisplayLimit < crossSiteSearchResults.count {
            crossSiteSearchDisplayLimit = min(crossSiteSearchDisplayLimit + crossSiteSearchPageSize, crossSiteSearchResults.count)
            crossSiteSearchStatus = "\(crossSiteSearchDisplayLimit) / \(crossSiteSearchResults.count) 件を表示中（取得上限 \(crossSiteSearchRequestedLimit) 件）"
            return
        }
        guard crossSiteSearchRequestedLimit < crossSiteSearchMaxLimit else { return }
        crossSiteSearchRequestedLimit = min(crossSiteSearchRequestedLimit + crossSiteSearchFetchStep, crossSiteSearchMaxLimit)
        runCrossSiteSearch(reset: false)
    }

    private func open(_ url: String) {
        state.browserUrl = ""
        state.tocUrl = ""
        canGoBack = false
        canGoForward = false
        browserCommand = nil
        loadRequest = BrowserLoadRequest(url: url)
    }

    private func closeBrowser() {
        loadRequest = nil
        state.browserUrl = ""
        state.tocUrl = ""
        canGoBack = false
        canGoForward = false
    }
}

private struct DetectedNovelMenu: View {
    let title: String
    let readNow: () -> Void
    let addToShelf: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "chevron.down")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
                .padding(.top, 4)
                .padding(.bottom, 2)

            Text(title)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.62)
                .padding(.horizontal, 18)

            Button("今すぐ読む", action: readNow)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.blue)
                .padding(.top, 12)

            Button("本棚に追加する", action: addToShelf)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white.opacity(0.88))

            Button("キャンセル", action: cancel)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 12)
    }
}

private enum BrowserTitleCleaner {
    static func novelTitle(from rawTitle: String, fallbackUrl: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = [" - ", "｜", " | ", "／", "【"]
        let title = separators.reduce(trimmed) { partial, separator in
            partial.components(separatedBy: separator).first ?? partial
        }
        let cleaned = title
            .replacingOccurrences(of: "小説家になろう", with: "")
            .replacingOccurrences(of: "カクヨム", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -｜|／【】[]()（）　\n\t"))
        if !cleaned.isEmpty { return cleaned }
        return URL(string: fallbackUrl)?.host ?? ""
    }
}

// MARK: - Private WKWebView browser

private struct PrivateBrowser: UIViewRepresentable {
    @Binding var currentUrl: String
    @Binding var cookieHeaders: [String: String]
    @Binding var loadRequest: BrowserLoadRequest?
    @Binding var command: BrowserCommand?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var finishedUrl: String
    @Binding var finishedTitle: String
    @Binding var finishedHTML: String
    let adBlockEnabled: Bool

    private static let adBlockRuleListIdentifier = "NovelDLPrivateAdBlockRules"
    private static let adBlockRules = """
    [
      {"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","popup"],"if-domain":["*doubleclick.net","*googlesyndication.com","*googleadservices.com","*adservice.google.com","*adnxs.com","*adsystem.com","*ad-stir.com","*adingo.jp","*i-mobile.co.jp","*microad.jp","*fluct.jp","*nend.net","*ad-generation.jp"]},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*","load-type":["third-party"],"resource-type":["popup"]},"action":{"type":"block"}}
    ]
    """

    // Safari-like mobile UA — improves compatibility with Japanese novel sites
    private static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/18.0 Mobile/15E148 Safari/604.1"

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // Keep browser browsing data out of the system-wide persistent WebKit store.
        // Cookies needed for core downloads are mirrored explicitly into AppState
        // and passed to the Rust core; WebKit history/cache/cookies remain ephemeral.
        cfg.websiteDataStore              = .nonPersistent()
        cfg.suppressesIncrementalRendering = false
        cfg.allowsAirPlayForMediaPlayback = false
        cfg.allowsInlineMediaPlayback     = true
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.limitsNavigationsToAppBoundDomains = false
        cfg.applicationNameForUserAgent = "NovelDLiOS"

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.allowsBackForwardNavigationGestures = true
        web.allowsLinkPreview = false
        web.isOpaque = true
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.keyboardDismissMode = .interactive
        web.customUserAgent  = Self.mobileUA
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        configureContentBlocking(for: web, enabled: adBlockEnabled)

        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let loadRequest,
           context.coordinator.lastHandledRequestID != loadRequest.id,
           let url = URL(string: loadRequest.url) {
            context.coordinator.lastHandledRequestID = loadRequest.id
            uiView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30))
        }

        if context.coordinator.lastAppliedAdBlockEnabled != adBlockEnabled {
            context.coordinator.lastAppliedAdBlockEnabled = adBlockEnabled
            configureContentBlocking(for: uiView, enabled: adBlockEnabled)
            uiView.reload()
        }

        if let command, context.coordinator.lastHandledCommandID != command.id {
            context.coordinator.lastHandledCommandID = command.id
            switch command.action {
            case .back:
                if uiView.canGoBack { uiView.goBack() }
            case .forward:
                if uiView.canGoForward { uiView.goForward() }
            case .reload:
                uiView.reload()
            }
            context.coordinator.updateNavigationAvailability(uiView)
        }
    }

    private func configureContentBlocking(for webView: WKWebView, enabled: Bool) {
        webView.configuration.userContentController.removeAllContentRuleLists()
        guard enabled else { return }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.adBlockRuleListIdentifier,
            encodedContentRuleList: Self.adBlockRules
        ) { ruleList, _ in
            guard let ruleList else { return }
            DispatchQueue.main.async {
                webView.configuration.userContentController.add(ruleList)
            }
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        uiView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: PrivateBrowser
        var lastHandledRequestID: UUID?
        var lastHandledCommandID: UUID?
        var lastAppliedAdBlockEnabled: Bool?

        init(_ parent: PrivateBrowser) { self.parent = parent }

        /// Update URL as soon as a navigation starts (before content loads).
        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            updateUrl(webView)
            updateNavigationAvailability(webView)
        }

        /// Also update when main document response is received (handles redirects).
        func webView(_ webView: WKWebView,
                     didCommit navigation: WKNavigation!) {
            updateUrl(webView)
            updateNavigationAvailability(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateUrl(webView)
            updateFinishedUrl(webView)
            updateFinishedTitle(webView)
            updateFinishedHTML(webView)
            updateNavigationAvailability(webView)
            updateCookieHeader(webView)
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            updateUrl(webView)
            updateNavigationAvailability(webView)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            // Keep existing URL on provisional failure; don't blank it
            updateNavigationAvailability(webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // Do not mirror every navigationAction request into the address field.
            // WKWebView emits actions for subframes/iframes and script-driven ad
            // frames too; using those URLs here makes TOC detection pick ads
            // instead of the page the user is actually viewing. Main-document
            // callbacks below update from `webView.url` after WebKit commits.
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                // Open target=_blank links in the same web view. The address field
                // is updated by the committed main-frame navigation, not by this
                // raw request, so pop-up/ad frame requests do not become the page URL.
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30))
                updateNavigationAvailability(webView)
            }
            return nil
        }

        func updateNavigationAvailability(_ webView: WKWebView) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.canGoBack = webView.canGoBack
                self?.parent.canGoForward = webView.canGoForward
            }
        }

        private func updateUrl(_ webView: WKWebView) {
            updateUrl(webView.url?.absoluteString ?? "")
        }

        private func updateFinishedUrl(_ webView: WKWebView) {
            let raw = webView.url?.absoluteString ?? ""
            guard !raw.isEmpty, raw != "about:blank" else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.finishedUrl = raw
            }
        }

        private func updateFinishedTitle(_ webView: WKWebView) {
            let title = webView.title ?? ""
            DispatchQueue.main.async { [weak self] in
                self?.parent.finishedTitle = title
            }
        }

        private func updateFinishedHTML(_ webView: WKWebView) {
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                guard let html = result as? String, !html.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.parent.finishedHTML = html
                }
            }
        }

        private func updateCookieHeader(_ webView: WKWebView) {
            guard let host = webView.url?.host?.lowercased() else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                let header = cookies
                    .filter { cookie in
                        if let expires = cookie.expiresDate, expires <= Date() { return false }
                        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                        return host == domain || host.hasSuffix("." + domain)
                    }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                guard !header.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.parent.cookieHeaders[host] = header
                }
            }
        }

        private func updateUrl(_ raw: String) {
            // Ignore blank / about:blank
            guard !raw.isEmpty, raw != "about:blank" else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.currentUrl = raw
            }
        }

    }
}
