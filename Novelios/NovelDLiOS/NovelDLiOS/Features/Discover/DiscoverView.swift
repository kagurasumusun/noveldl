import SwiftUI

/// さがす — サイト横断の作品検索。追加 = 自動で全話取得。
struct DiscoverView: View {
    @Environment(CoreClient.self) private var core: CoreClient
    @State private var query = ""
    @State private var results: [SearchResultItem] = []
    @State private var searching = false
    @State private var errorText: String?
    @State private var addingUrl: String?
    @State private var sites: [SearchSite] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    SectionBanner(
                        title: "さがす",
                        subtitle: sites.isEmpty ? nil : sites.map(\.label).joined(separator: "・")
                    )

                    HStack(spacing: Spacing.m) {
                        Image(systemName: "magnifyingglass")
                            .font(AppFont.ui(14, weight: .medium))
                            .foregroundStyle(AppPalette.inkFaint)
                        TextField("タイトル・作者名・キーワード", text: $query)
                            .font(AppFont.ui(15))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await run() } }
                        if searching {
                            ProgressView().scaleEffect(0.8)
                        } else if !query.isEmpty {
                            Button {
                                query = ""
                                results = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(AppFont.ui(14))
                                    .foregroundStyle(AppPalette.inkFaint)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                    .padding(.horizontal, Spacing.l)
                    .frame(height: 50)
                    .background(PaperBackground())

                    if results.isEmpty && !searching {
                        VStack(spacing: Spacing.m) {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(AppPalette.inkFaint)
                            Text("次の一行を探しましょう")
                                .font(AppFont.serif(18, weight: .semibold))
                                .foregroundStyle(AppPalette.ink)
                            Text("見つけた作品は「本棚に追加」で目次と全話をまとめて取得します。")
                                .font(AppFont.ui(13))
                                .foregroundStyle(AppPalette.inkSoft)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 56)
                    }

                    ForEach(results) { hit in
                        resultRow(hit)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, Spacing.l)
                .padding(.bottom, 40)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            sites = (try? await core.searchSites()) ?? []
        }
        .alert("さがす", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func resultRow(_ hit: SearchResultItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(hit.title)
                        .font(AppFont.serif(16, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                        .lineLimit(2)
                    if let author = hit.author, !author.isEmpty {
                        Text(author)
                            .font(AppFont.ui(13))
                            .foregroundStyle(AppPalette.inkSoft)
                    }
                }
                Spacer()
                if let site = hit.site {
                    InfoChip(text: site)
                }
            }
            if let summary = hit.summary, !summary.isEmpty {
                Text(summary)
                    .font(AppFont.ui(13))
                    .foregroundStyle(AppPalette.inkFaint)
                    .lineLimit(3)
                    .lineSpacing(3)
            }
            RowDivider()
            HStack {
                if let updated = hit.updated {
                    Text(shortDate(updated))
                        .font(AppFont.ui(11))
                        .foregroundStyle(AppPalette.inkFaint)
                        .monospacedDigit()
                }
                if let count = hit.episodeCount {
                    Text("・全\(count)話")
                        .font(AppFont.ui(11))
                        .foregroundStyle(AppPalette.inkFaint)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    Task { await add(hit) }
                } label: {
                    HStack(spacing: 4) {
                        if addingUrl == hit.url {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "plus.circle.fill")
                        }
                        Text(addingUrl == hit.url ? "取得中…" : "本棚に追加")
                    }
                    .font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(AppPalette.ember)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(addingUrl != nil)
            }
        }
        .padding(Spacing.l)
        .background(PaperBackground())
    }

    private func shortDate(_ s: String) -> String { String(s.prefix(10)) }

    private func run() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await core.search(text)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 追加 = 目次取得 → 自動で全話ダウンロード。
    private func add(_ hit: SearchResultItem) async {
        addingUrl = hit.url
        defer { addingUrl = nil }
        do {
            let slug = hit.url
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "/", with: "_")
            let dir = CoreClient.libraryRoot()
                .appendingPathComponent(slug, isDirectory: true)
                .path
            let toc = try await core.fetchToc(url: hit.url, outputDir: dir)
            await core.reloadLibrary()
            let outputDir = core.library.first(where: { $0.novelId == toc.novelId })?.outputDir ?? dir
            _ = try await core.download(
                CoreClient.DownloadOptions(
                    url: hit.url,
                    outputDir: outputDir,
                    episodes: 0,
                    fromIndex: "",
                    mode: "bulk"
                )
            )
            Haptics.success()
            await core.reloadLibrary()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
