import SwiftUI

/// 本棚 — カバー主役の書棚。追加 = 自動ダウンロード。
struct LibraryView: View {
    @Environment(CoreClient.self) private var core: CoreClient
    @State private var refreshing = false
    @State private var showAddSheet = false
    @State private var importUrl = ""
    @State private var errorText: String?
    @State private var activeStatus: String?
    @State private var columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    header
                    if let activeStatus {
                        HStack(spacing: Spacing.m) {
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
                        .padding(Spacing.l)
                        .background(PaperBackground())
                    }
                    if core.library.isEmpty {
                        emptyShelf
                    } else {
                        shelfGrid
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, Spacing.l)
                .padding(.bottom, 40)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await core.reloadLibrary() }
            .sheet(isPresented: $showAddSheet) { addSheet }
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

    // MARK: 見出し + 操作

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("本棚")
                        .font(AppFont.serif(30, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(shelfSubtitle)
                        .font(AppFont.ui(13))
                        .foregroundStyle(AppPalette.inkFaint)
                }
                Spacer()
                HStack(spacing: Spacing.s) {
                    CircleIconButton(system: "arrow.clockwise") {
                        Task {
                            refreshing = true
                            _ = try? await core.refreshLibrary()
                            await core.reloadLibrary()
                            refreshing = false
                        }
                    }
                    CircleIconButton(system: "plus", filled: true) {
                        showAddSheet = true
                    }
                }
            }
            Rectangle().fill(AppPalette.ink).frame(width: 28, height: 2)
        }
    }

    private var shelfSubtitle: String {
        if core.library.isEmpty { return "作品はまだありません" }
        let works = core.library.count
        let episodes = core.library.reduce(0) { $0 + $1.episodeCount }
        return "\(works)作品・全\(episodes)話"
    }

    // MARK: 書棚

    private var shelfGrid: some View {
        LazyVGrid(columns: columns, spacing: Spacing.xl) {
            ForEach(core.library, id: \.novelId) { item in
                NavigationLink(value: item) {
                    shelfCell(item)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    private func shelfCell(_ item: LibraryNovelItem) -> some View {
        let total = max(item.episodeCount, 1)
        let done = item.downloadedCount ?? 0
        return VStack(alignment: .leading, spacing: Spacing.s) {
            CoverTile(
                title: item.title,
                author: item.author,
                progress: Double(done) / Double(total)
            )
            .shadow(color: AppPalette.shelfShadow, radius: 8, x: 0, y: 6)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(item.title)
                    .font(AppFont.serif(14, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(2)
                Text(item.author)
                    .font(AppFont.ui(12))
                    .foregroundStyle(AppPalette.inkFaint)
                    .lineLimit(1)
                HStack(spacing: Spacing.s) {
                    Text("\(done)/\(total) 話")
                        .font(AppFont.ui(11, weight: .medium).monospacedDigit())
                        .foregroundStyle(AppPalette.inkSoft)
                    ReadingRibbon(value: Double(done) / Double(total))
                }
                .padding(.top, 2)
            }
        }
    }

    private var emptyShelf: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "books.vertical")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(AppPalette.inkFaint)
            Text("URL から作品を追加できます")
                .font(AppFont.serif(19, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text("右上の＋から対応サイトの目次 URL を貼ると、目次と全話をまとめて取得します。")
                .font(AppFont.ui(13))
                .foregroundStyle(AppPalette.inkSoft)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, Spacing.xl)
            EmberButton(title: "作品を追加", systemImage: "plus", prominent: true) {
                showAddSheet = true
            }
            .frame(maxWidth: 260)
            .padding(.top, Spacing.s)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    // MARK: 追加シート

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Text("作品を追加")
                    .font(AppFont.serif(22, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                CircleIconButton(system: "xmark") { showAddSheet = false }
            }
            Text("対応サイトの目次ページ URL を貼り付けてください。目次を取得したあと、そのまま全話のダウンロードを開始します。")
                .font(AppFont.ui(13))
                .foregroundStyle(AppPalette.inkSoft)
                .lineSpacing(3)
            PaperField(placeholder: "https://ncode.syosetu.com/n0000aa/", text: $importUrl, keyboard: .URL)
            EmberButton(title: "追加して全話を取得", systemImage: "arrow.down.circle.fill", prominent: true) {
                showAddSheet = false
                Task { await importNovel() }
            }
            .disabled(importUrl.isEmpty)
            Spacer()
        }
        .padding(Spacing.xl)
        .presentationDetents([.height(320)])
        .presentationCornerRadius(20)
    }

    /// 追加 = 目次取得 → 自動で全話ダウンロード。
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
            Haptics.success()
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
