import SwiftUI

/// 本棚 — 横広の表紙 1 画像を縦 1 列に並べる。追加 = 自動ダウンロード。
struct LibraryView: View {
    @Environment(CoreClient.self) private var core: CoreClient
    @State private var refreshing = false
    @State private var showAddSheet = false
    @State private var importUrl = ""
    @State private var errorText: String?
    @State private var activeStatus: String?
    @State private var readerRoute: ReaderRoute?

    /// 本棚の並び: "grid"(2列) / "list"(1列)。
    @AppStorage("shelfLayout") private var shelfLayout = "grid"
    /// 削除確認中の小説。
    @State private var pendingDelete: LibraryNovelItem?
    @Environment(\.scenePhase) private var scenePhase

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
                        bookshelf
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, Spacing.l)
                .padding(.bottom, 72)
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
            .fullScreenCover(item: $readerRoute) { route in
                ReaderView(novelId: route.novelId, startAt: route.index, title: route.title, tocUrl: route.tocUrl)
            }
        }
        .task {
            await core.reloadLibrary()
            await refreshMetaIfStale()
        }
        // アプリが前面に戻ったときも小説の情報を更新する(最新の目次・改稿・完結状況)。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refreshMetaIfStale() }
            }
        }
    }

    // MARK: 見出し + 操作

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("LIBRARY")
                        .font(AppFont.serif(21, weight: .medium))
                        .foregroundStyle(AppPalette.ink)
                        .tracking(3.5)
                    Text("本棚 — " + shelfSubtitle)
                        .font(AppFont.ui(10.5))
                        .foregroundStyle(AppPalette.inkFaint)
                }
                Spacer()
                HStack(spacing: Spacing.s) {
                    CircleIconButton(system: shelfLayout == "grid" ? "list.bullet" : "square.grid.2x2") {
                        shelfLayout = shelfLayout == "grid" ? "list" : "grid"
                        Haptics.tap()
                    }
                    CircleIconButton(system: "arrow.clockwise") {
                        // 取得はリーダー開始時に行うモデル。更新確認は
                        // 目次・話数・更新日の取り直しのみ(速い)。
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

    // MARK: 本棚 = 横広の表紙を 1 列に

    private var bookshelf: some View {
        Group {
            if shelfLayout == "grid" {
                bookshelfGrid
            } else {
                bookshelfList
            }
        }
        .confirmationDialog(
            "「\(pendingDelete?.title ?? "")」を本棚から削除しますか？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("本棚から削除する", role: .destructive) {
                if let target = pendingDelete {
                    pendingDelete = nil
                    Task {
                        try? await core.deleteNovel(novelId: target.novelId)
                        await core.reloadLibrary()
                    }
                }
            }
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("保存した本文・目次・表紙・改稿履歴も端末から削除されます。サイト側のデータには影響しません。")
        }
    }

    /// 表示時・復帰時のメタ更新(10分スロットルで全件取り直しを避ける)。
    private func refreshMetaIfStale() async {
        let key = "lastMetaRefreshAt"
        let last = UserDefaults.standard.double(forKey: key)
        guard Date().timeIntervalSince1970 - last > 600 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        _ = try? await core.refreshLibrary()
        await core.reloadLibrary()
    }

    /// 2列のグリッド(表紙主導)。
    private var bookshelfGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.m),
                            GridItem(.flexible(), spacing: Spacing.m)],
                  spacing: Spacing.l) {
            ForEach(core.library, id: \.novelId) { item in
                NavigationLink(value: item) {
                    VStack(alignment: .leading, spacing: 6) {
                        CoverTile(
                            title: item.title,
                            author: item.author,
                            progress: Double(item.downloadedCount ?? 0)
                                / Double(max(item.episodeCount, 1)),
                            image: CoverStore.customImage(item.storagePath) ?? core.covers[item.novelId]
                        )
                        Text(item.title)
                            .font(AppFont.ui(12.5, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(item.downloadedCount ?? 0)/\(max(item.episodeCount, 1)) 話")
                            .font(AppFont.ui(10.5).monospacedDigit())
                            .foregroundStyle(AppPalette.inkFaint)
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDelete = item
                    } label: {
                        Label("本棚から削除", systemImage: "trash")
                    }
                }
            }
        }
    }

    /// 従来の1列リスト(横長表紙)。
    private var bookshelfList: some View {
        VStack(spacing: Spacing.xl) {
            ForEach(core.library, id: \.novelId) { item in
                NavigationLink(value: item) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        WideCover(
                            title: item.title,
                            author: item.author,
                            image: CoverStore.customImage(item.storagePath) ?? core.covers[item.novelId],
                            aspect: 2.0
                        )
                        HStack(spacing: Spacing.s) {
                            Text("\(item.downloadedCount ?? 0)/\(max(item.episodeCount, 1)) 話")
                                .font(AppFont.ui(11, weight: .medium).monospacedDigit())
                                .foregroundStyle(AppPalette.inkFaint)
                            Spacer()
                            ReadingRibbon(
                                value: Double(item.downloadedCount ?? 0) / Double(max(item.episodeCount, 1))
                            )
                            .frame(width: 72)
                        }
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDelete = item
                    } label: {
                        Label("本棚から削除", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var emptyShelf: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "books.vertical")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(AppPalette.inkFaint)
                .frame(height: 64)
            Text(shelfSubtitle)
                .font(AppFont.ui(15))
                .foregroundStyle(AppPalette.inkSoft)
            Button {
                showAddSheet = true
            } label: {
                Text("小説を追加")
                    .font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }

    // MARK: 取り込み

    private var addSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("URL を貼り付け")
                            .font(AppFont.ui(13, weight: .semibold))
                            .foregroundStyle(AppPalette.inkSoft)
                        PaperField(placeholder: "https://ncode.syosetu.com/n0000aa/", text: $importUrl, keyboard: .URL)
                        Button {
                            Task { await runImport(url: importUrl) }
                        } label: {
                            Text("取得する")
                                .font(AppFont.ui(15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: Metrics.controlHeight)
                                .background(RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous).fill(AppPalette.ember))
                        }
                        .buttonStyle(PressableButtonStyle())
                        Text("追加すると目次を取り込み、全話をまとめて取得します。取得済みは再取得しません。")
                            .font(AppFont.ui(12))
                            .foregroundStyle(AppPalette.inkFaint)
                    }

                    if let activeStatus {
                        HStack(spacing: Spacing.m) {
                            ProgressView()
                            Text(activeStatus)
                                .font(AppFont.ui(13))
                                .foregroundStyle(AppPalette.ink)
                            Spacer()
                        }
                    }
                    if core.progress.running {
                        Text("\(core.progress.done)/\(core.progress.total) 話")
                            .font(AppFont.ui(13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(AppPalette.ember)
                    }
                }
                .padding(Metrics.gutter)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
            .navigationTitle("小説を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { showAddSheet = false }
                }
            }
        }
    }

    private func runImport(url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 並走ガード(中止状態の上書き・SQLite競合の防止)。
        guard !core.progress.running else {
            errorText = "取得が進行中です。完了後に追加してください。"
            return
        }
        activeStatus = "目次を取得中…"
        errorText = nil
        do {
            // 保存先は必ずライブラリ配下の絶対パスにする。
            // 相対パスを渡すと iOS では書き込み不可の場所へ向かい、
            // DB 作成に失敗して「追加したのに本棚に出ない」になった。
            let slug = trimmed
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "/", with: "_")
            let dir = CoreClient.libraryRoot()
                .appendingPathComponent(slug, isDirectory: true)
                .path
            let fetched = try await core.fetchToc(url: trimmed, outputDir: dir)
            await core.reloadLibrary()
            // サイトに表紙(og:image)があれば保存して本棚に表示する。
            if let coverUrl = fetched.coverUrl {
                let storage = core.library.first { $0.novelId == fetched.novelId }?.storagePath
                await CoreClient.downloadCover(from: coverUrl, storagePath: storage)
                await core.reloadLibrary()
            }
            activeStatus = nil
            showAddSheet = false
            importUrl = ""
            errorText = "「\(fetched.title)」を追加しました(目次のみ)。読み始めると続きを自動で取得します。"
        } catch {
            activeStatus = nil
            errorText = "取り込みに失敗しました: \(error.localizedDescription)"
        }
    }
}
