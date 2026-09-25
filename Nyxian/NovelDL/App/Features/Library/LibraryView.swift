import SwiftUI

/// 本棚 — カバー主役の書棚グリッド + 「追加 = 自動ダウンロード」。
struct LibraryView: View {
    @Environment(CoreClient.self) private var core: CoreClient
    @State private var refreshing = false
    @State private var importing = false
    @State private var importUrl = ""
    @State private var errorText: String?
    @State private var activeStatus: String?
    @State private var columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SectionBanner(title: "本棚", subtitle: shelfSubtitle)

                    if let activeStatus {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(activeStatus)
                                .font(AppFont.ui(14, weight: .medium))
                                .foregroundStyle(AppPalette.ink)
                            Spacer()
                            if core.progress.running {
                                Text("\(core.progress.done)/\(core.progress.total)")
                                    .font(AppFont.ui(13, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(AppPalette.ember)
                            }
                        }
                        .padding(12)
                        .background(CardBackground())
                    }

                    if core.library.isEmpty {
                        emptyShelf
                    } else {
                        shelfGrid
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        importing = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("URL から追加")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            refreshing = true
                            defer { refreshing = false }
                            _ = try? await core.refreshLibrary()
                            await core.reloadLibrary()
                        }
                    } label: {
                        if refreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel("更新を確認")
                }
            }
            .refreshable { await core.reloadLibrary() }
            .alert("URL から追加", isPresented: $importing) {
                TextField("目次ページの URL", text: $importUrl)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("追加して全話を取得") { Task { await importNovel() } }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("対応サイトの目次 URL を貼り付けてください。目次を取得したあと、そのまま全話のダウンロードを開始します。")
            }
            .alert("本棚", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .navigationDestination(for: LibraryNovelItem.self) { item in
                NovelDetailView(item: item)
            }
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderView(novelId: route.novelId, startAt: route.index, title: route.title)
            }
        }
        .task { await core.reloadLibrary() }
    }

    private var shelfSubtitle: String {
        if core.library.isEmpty { return "作品はまだありません" }
        let works = core.library.count
        let episodes = core.library.reduce(0) { $0 + $1.episodeCount }
        return "\(works)作品・全\(episodes)話"
    }

    private var emptyShelf: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(AppPalette.inkFaint)
            Text("URL から作品を追加できます")
                .font(AppFont.serif(19, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text("「+」から対応サイトの目次 URL を貼ると、目次と全話をまとめて取得します。")
                .font(AppFont.ui(13))
                .foregroundStyle(AppPalette.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var shelfGrid: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(core.library, id: \.novelId) { item in
                NavigationLink(value: item) {
                    VStack(alignment: .leading, spacing: 8) {
                        let total = max(item.episodeCount, 1)
                        let done = item.downloadedCount ?? 0
                        CoverTile(
                            title: item.title,
                            author: item.author,
                            progress: Double(done) / Double(total)
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(AppFont.serif(14, weight: .semibold))
                                .foregroundStyle(AppPalette.ink)
                                .lineLimit(2)
                            Text(item.author)
                                .font(AppFont.ui(12))
                                .foregroundStyle(AppPalette.inkSoft)
                                .lineLimit(1)
                            ReadingRibbon(value: Double(done) / Double(total))
                            Text("\(done)/\(total) 話")
                                .font(AppFont.ui(11, weight: .medium))
                                .foregroundStyle(AppPalette.inkFaint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 追加 = 目次取得 → 自動で全話ダウンロード。「追加しても dl されない」を解消。
    private func importNovel() async {
        let url = importUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        importUrl = ""
        guard !url.isEmpty else { return }
        do {
            let dir = CoreClient.libraryRoot()
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .path
            activeStatus = "目次を取得中…"
            let toc = try await core.fetchToc(url: url, outputDir: dir)
            await core.reloadLibrary()
            // ダウンロードは保存先の正(登録済みライブラリの outputDir)を使う。
            let outputDir = core.library.first(where: { $0.novelId == toc.novelId })?.outputDir ?? dir
            activeStatus = "全話をダウンロード中…"
            let result = try await core.download(
                CoreClient.DownloadOptions(
                    url: url,
                    outputDir: outputDir,
                    episodes: 0,
                    fromIndex: "",
                    mode: "bulk"
                )
            )
            activeStatus = nil
            if result.failed > 0 {
                errorText = "\(result.saved)話を取得・\(result.updated)話を更新しました(\(result.failed)話は失敗。再実行で続きから取得できます)"
            }
            await core.reloadLibrary()
        } catch {
            activeStatus = nil
            errorText = error.localizedDescription
        }
    }
}
