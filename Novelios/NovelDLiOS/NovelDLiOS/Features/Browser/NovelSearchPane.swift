import SwiftUI

struct NovelSearchPane: View {
    @ObservedObject var state: AppState
    @State private var query = ""
    @State private var results: [NovelSearchResultItem] = []
    @State private var sites: [SupportedSearchSite] = []
    @State private var status = "タイトル・作者・キーワードで横断検索できます"
    @State private var isSearching = false
    @State private var requestedLimit = 40
    @State private var displayLimit = 20
    @State private var lastQuery = ""
    @State private var showSites = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchRequestID = UUID()

    private let initialLimit = 40
    private let pageSize = 20
    private let fetchStep = 40
    private let maxLimit = 180

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                searchBox
                siteDisclosure
                statusRow
                resultsList
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 120)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("小説検索").font(.headline).foregroundStyle(.white)
            }
        }
        .onAppear(perform: loadSitesIfNeeded)
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("小説検索", systemImage: "magnifyingglass.circle.fill")
                .font(.system(size: 28, weight: .bold))
            Text("ブラウザのサイト一覧から分離した検索専用ページです。結果から即ライブラリ追加または今すぐ読むを開始できます。")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var searchBox: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.58))
            TextField("タイトル・作者・キーワード", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { runSearch(reset: true) }
            Button { runSearch(reset: true) } label: {
                if isSearching {
                    ProgressView().tint(.white)
                } else {
                    Text("検索").font(.callout.weight(.bold))
                }
            }
            .disabled(isSearching)
        }
        .padding(14)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var siteDisclosure: some View {
        DisclosureGroup(isExpanded: $showSites) {
            if sites.isEmpty {
                Text("対応サイトを読み込み中…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.54))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 7)], alignment: .leading, spacing: 7) {
                    ForEach(sites) { site in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.label)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                            Text(site.domainSummary)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.top, 8)
            }
        } label: {
            Label("検索対象サイト", systemImage: "globe.asia.australia")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .tint(.white.opacity(0.72))
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if isSearching { ProgressView().tint(.white) }
            Text(status)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty && !isSearching {
            ContentUnavailableView(
                "検索結果がありません",
                systemImage: "text.page.badge.magnifyingglass",
                description: Text("キーワードを入力して検索してください")
            )
            .foregroundStyle(.white.opacity(0.86))
            .padding(.top, 28)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(Array(results.prefix(displayLimit))) { result in
                    resultCard(result)
                }
                loadMoreRow
            }
        }
    }

    private func resultCard(_ result: NovelSearchResultItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(result.title.isEmpty ? result.url : result.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(result.site)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.11), in: Capsule())
            }

            if let author = result.author, !author.isEmpty {
                Text("作者: \(author)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
            }
            if let summary = result.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                if let updated = result.updated, !updated.isEmpty { Text(updated) }
                if let episodeCount = result.episodeCount { Text("\(episodeCount)話") }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.44))

            HStack(spacing: 10) {
                Button { add(result, readNow: true) } label: {
                    Label("今すぐ読む", systemImage: "book.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button { add(result, readNow: false) } label: {
                    Label("追加", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.caption.weight(.bold))
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.10), .blue.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        if displayLimit < results.count || requestedLimit < maxLimit {
            Button { loadMore() } label: {
                HStack(spacing: 8) {
                    if isSearching { ProgressView().tint(.white) } else { Image(systemName: "arrow.down.circle") }
                    Text(displayLimit < results.count ? "さらに表示" : "さらに検索")
                }
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
            .onAppear {
                guard displayLimit < results.count else { return }
                displayLimit = min(displayLimit + pageSize, results.count)
            }
        }
    }

    private func add(_ result: NovelSearchResultItem, readNow: Bool) {
        let candidate = TocMatcher.candidate(result.url)?.url ?? result.url
        state.tocUrl = candidate
        state.browserUrl = candidate
        if readNow {
            state.addDetectedTocToShelfForReader(browserHTML: nil)
        } else {
            state.addDetectedTocToShelf(browserHTML: nil)
            state.selectedTab = .library
        }
    }

    private func loadSitesIfNeeded() {
        guard sites.isEmpty else { return }
        Task.detached(priority: .utility) {
            let loaded = (try? NovelCoreBridge.callSupportedSearchSites()) ?? []
            await MainActor.run { sites = loaded }
        }
    }

    private func runSearch(reset: Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            status = "検索語を入力してください"
            return
        }
        if reset || trimmed != lastQuery {
            requestedLimit = initialLimit
            displayLimit = pageSize
            results = []
            lastQuery = trimmed
        }
        searchTask?.cancel()
        let requestID = UUID()
        searchRequestID = requestID
        isSearching = true
        status = "検索中…"
        let limit = requestedLimit
        searchTask = Task.detached(priority: .userInitiated) {
            do {
                let payload = try NovelCoreBridge.callSearchNovels(query: trimmed, limit: UInt32(limit))
                await MainActor.run {
                    guard searchRequestID == requestID else { return }
                    results = payload.results
                    displayLimit = min(max(displayLimit, pageSize), payload.results.count)
                    status = payload.results.isEmpty ? "該当する小説が見つかりませんでした" : "\(payload.results.count)件取得しました"
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    guard searchRequestID == requestID else { return }
                    status = "検索エラー: \(error.localizedDescription)"
                    isSearching = false
                }
            }
        }
    }

    private func loadMore() {
        if displayLimit < results.count {
            displayLimit = min(displayLimit + pageSize, results.count)
            return
        }
        requestedLimit = min(requestedLimit + fetchStep, maxLimit)
        runSearch(reset: false)
    }
}
