import SwiftUI

struct ReaderRoute: Hashable {
    let novelId: String
    let index: String
    let title: String
}

/// 作品詳細 — 「全話をダウンロード」が主役。範囲指定・書き出しは脇に。
struct NovelDetailView: View {
    let item: LibraryNovelItem

    @Environment(CoreClient.self) private var core: CoreClient
    @State private var detail: LibraryNovelDetail?
    @State private var busy = false
    @State private var statusText: String?
    @State private var errorText: String?
    @State private var episodesLimit = 0
    @State private var fromIndex = ""
    @State private var showOptions = false

    private struct ChapterGroup: Identifiable {
        let id: String
        let chapters: [ChapterMeta]
    }

    private var groupedChapters: [ChapterGroup] {
        let chapters = detail?.chapters ?? []
        var order: [String] = []
        var buckets: [String: [ChapterMeta]] = [:]
        for ch in chapters {
            let key = ch.chapter ?? ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(ch)
        }
        return order.map { ChapterGroup(id: $0, chapters: buckets[$0] ?? []) }
    }

    private var downloaded: Int { detail?.downloadedCount ?? item.downloadedCount ?? 0 }
    private var total: Int { max(detail?.novel.episodeCount ?? item.episodeCount, 1) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                Divider().overlay(AppPalette.hairline)
                chapterList
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .background(AppPalette.canvas.ignoresSafeArea())
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("範囲を指定してダウンロード", isPresented: $showOptions) {
            TextField("取得話数(空欄・0 = 全話)", text: Binding(
                get: { episodesLimit == 0 ? "" : String(episodesLimit) },
                set: { episodesLimit = Int($0) ?? 0 }
            ))
            .keyboardType(.numberPad)
            TextField("開始話(空欄 = 先頭)", text: $fromIndex)
                .keyboardType(.numberPad)
            Button("一括取得") { Task { await runDownload(mode: "bulk") } }
            Button("読者モード(先頭15話を先行取得)") { Task { await runDownload(mode: "reader") } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("取得話数 0 または空欄で全話をまとめて取得します。失敗した話があっても残りは続行され、次回の再実行で取りこぼし分だけ取得します。")
        }
        .alert("詳細", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .task { await reload() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverTile(
                title: item.title,
                author: item.author,
                progress: Double(downloaded) / Double(total),
                width: 92
            )
            .shadow(color: AppPalette.shelfShadow, radius: 6, x: 0, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(AppFont.serif(21, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.author)
                    .font(AppFont.ui(14))
                    .foregroundStyle(AppPalette.inkSoft)
                InfoChip(text: item.domain)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(downloaded)/\(total) 話を取得済み")
                        .font(AppFont.ui(13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(AppPalette.ink)
                    ReadingRibbon(value: Double(downloaded) / Double(total))
                        .frame(width: 140)
                }
                .padding(.top, 2)
            }
            Spacer()
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            // 主行動:全話をただ押すだけ。
            EmberButton(
                title: busy
                    ? "ダウンロード中…"
                    : (downloaded >= total ? "未取得・更新分を確認して取得" : "全話をダウンロード"),
                systemImage: "arrow.down.circle.fill",
                prominent: true
            ) {
                Task { await runDownload(mode: "bulk", all: true) }
            }
            .disabled(busy)

            if let statusText {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(statusText)
                        .font(AppFont.ui(13))
                        .foregroundStyle(AppPalette.inkSoft)
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                QuietButton(title: "範囲を指定…", systemImage: "slider.horizontal.3") {
                    showOptions = true
                }
                .disabled(busy)
                QuietButton(title: "書き出し", systemImage: "square.and.arrow.up") {
                    Task { await exportZip() }
                }
                .disabled(busy)
            }

            if let first = detail?.chapters.first(where: { $0.bodyDownloaded == true })
                ?? detail?.chapters.first {
                NavigationLink(
                    value: ReaderRoute(novelId: item.novelId, index: first.index, title: item.title)
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: "book")
                        Text(detail?.chapters.contains(where: { $0.bodyDownloaded == true }) == true
                             ? "読む(続きから)" : "読む(先頭)")
                    }
                    .font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(AppPalette.ember)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.controlHeightSmall)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .fill(AppPalette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .strokeBorder(AppPalette.ember.opacity(0.45), lineWidth: 1)
                    )
                }
            }

            if core.progress.running {
                HStack {
                    Text("サイトに負荷をかけない間隔で取得中(設定で変更可)")
                        .font(AppFont.ui(11))
                        .foregroundStyle(AppPalette.inkFaint)
                    Spacer()
                    Button("中止") { core.cancel() }
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(AppPalette.ember)
                }
            }
        }
    }

    private var chapterList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groupedChapters) { group in
                if !group.id.isEmpty {
                    Text(group.id)
                        .font(AppFont.ui(12, weight: .semibold))
                        .foregroundStyle(AppPalette.gold)
                        .padding(.top, 18)
                        .padding(.bottom, 6)
                }
                ForEach(group.chapters, id: \.index) { ch in
                    NavigationLink(
                        value: ReaderRoute(novelId: item.novelId, index: ch.index, title: item.title)
                    ) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(ch.index)
                                .font(AppFont.ui(11, design: .monospaced))
                                .foregroundStyle(AppPalette.inkFaint)
                                .frame(width: 34, alignment: .trailing)
                            Text(ch.subtitle)
                                .font(AppFont.serif(15))
                                .foregroundStyle(AppPalette.ink)
                            Spacer()
                            if ch.bodyDownloaded == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppPalette.gold)
                            }
                            if let mark = ch.subupdate, !mark.isEmpty {
                                Text(mark == "revised" ? "改" : mark)
                                    .font(AppFont.ui(10, weight: .bold))
                                    .foregroundStyle(AppPalette.ember)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(AppPalette.ember.opacity(0.5), lineWidth: 1)
                                    )
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(AppPalette.hairline)
                }
            }
        }
    }

    private func reload() async {
        do {
            detail = try await core.novelDetail(item.novelId)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// all: true なら話数指定を無視して全話(失敗分は再実行で拾う)。
    private func runDownload(mode: String, all: Bool = false) async {
        busy = true
        statusText = all ? "全話をダウンロード中…" : "ダウンロード中…"
        defer {
            busy = false
            statusText = nil
        }
        do {
            let options = CoreClient.DownloadOptions(
                url: item.tocUrl,
                outputDir: item.outputDir,
                episodes: all ? 0 : episodesLimit,
                fromIndex: all ? "" : fromIndex,
                mode: mode
            )
            let result = try await core.download(options)
            await reload()
            await core.reloadLibrary()
            if result.failed > 0 {
                errorText = "\(result.saved)話を取得・\(result.updated)話を更新(\(result.failed)話は失敗。「全話をダウンロード」の再実行で続きから取得します)"
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func exportZip() async {
        do {
            let result = try await core.exportZip(novelId: item.novelId)
            errorText = "\(result.files)ファイルを書き出しました: \(result.zipPath)"
        } catch {
            errorText = error.localizedDescription
        }
    }
}
