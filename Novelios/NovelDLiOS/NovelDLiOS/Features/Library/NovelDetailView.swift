import SwiftUI

struct ReaderRoute: Hashable {
    let novelId: String
    let index: String
    let title: String
}

/// 作品詳細 — 書影と装丁情報を主役にした「本の紹介頁」。
/// あらすじ・進捗・取得操作・目次を一枚の紙面として構成。
struct NovelDetailView: View {
    let item: LibraryNovelItem

    @Environment(CoreClient.self) private var core: CoreClient
    @State private var detail: LibraryNovelDetail?
    @State private var synopsis: String?
    @State private var synopsisExpanded = false
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
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                if let synopsis, !synopsis.isEmpty {
                    synopsisCard(synopsis)
                }
                actionCard
                chapterSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(AppPalette.canvas.ignoresSafeArea())
        .navigationTitle("")
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

    // MARK: 書影 + 装丁情報

    private var heroCard: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverTile(
                title: item.title,
                author: item.author,
                progress: Double(downloaded) / Double(total),
                width: 118
            )
            .shadow(color: AppPalette.shelfShadow, radius: 8, x: 0, y: 6)

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(AppFont.serif(21, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.author)
                    .font(AppFont.ui(15))
                    .foregroundStyle(AppPalette.inkSoft)
                HStack(spacing: 6) {
                    InfoChip(text: item.domain)
                    if let updated = item.updatedAt, !updated.isEmpty {
                        InfoChip(text: "更新 \(shortDate(updated))")
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("取得済み")
                            .font(AppFont.ui(12))
                            .foregroundStyle(AppPalette.inkFaint)
                        Text("\(downloaded) / \(total) 話")
                            .font(AppFont.ui(15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(AppPalette.ink)
                        Spacer()
                        Text("\(Int(Double(downloaded) / Double(total) * 100))%")
                            .font(AppFont.ui(13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(AppPalette.ember)
                    }
                    ReadingRibbon(value: Double(downloaded) / Double(total))
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(CardBackground())
    }

    // MARK: あらすじ

    private func synopsisCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("あらすじ")
                .font(AppFont.serif(17, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text(text)
                .font(AppFont.ui(14))
                .foregroundStyle(AppPalette.inkSoft)
                .lineSpacing(5)
                .lineLimit(synopsisExpanded ? nil : 5)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > 90 {
                Button {
                    synopsisExpanded.toggle()
                } label: {
                    Text(synopsisExpanded ? "閉じる" : "もっと読む")
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(AppPalette.ember)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    // MARK: 操作

    private var actionCard: some View {
        VStack(spacing: 10) {
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

            if core.progress.running {
                HStack {
                    Text("サイトに負荷をかけない間隔で取得中")
                        .font(AppFont.ui(11))
                        .foregroundStyle(AppPalette.inkFaint)
                    Spacer()
                    Button("中止") { core.cancel() }
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(AppPalette.ember)
                }
            }
        }
        .padding(16)
        .background(CardBackground())
    }

    // MARK: 目次

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("目次")
                    .font(AppFont.serif(19, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Text("全\(total)話")
                    .font(AppFont.ui(13))
                    .foregroundStyle(AppPalette.inkSoft)
                    .monospacedDigit()
            }
            .padding(.top, 6)

            VStack(spacing: 0) {
                ForEach(groupedChapters) { group in
                    if !group.id.isEmpty {
                        Text(group.id)
                            .font(AppFont.ui(12, weight: .semibold))
                            .foregroundStyle(AppPalette.gold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                            .background(AppPalette.canvas)
                    }
                    ForEach(group.chapters, id: \.index) { ch in
                        NavigationLink(
                            value: ReaderRoute(novelId: item.novelId, index: ch.index, title: item.title)
                        ) {
                            HStack(spacing: 12) {
                                Text(ch.index)
                                    .font(AppFont.ui(12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(AppPalette.inkFaint)
                                    .frame(width: 36, alignment: .trailing)
                                Text(ch.subtitle)
                                    .font(AppFont.serif(15))
                                    .foregroundStyle(AppPalette.ink)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                if ch.bodyDownloaded == true {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13))
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(AppPalette.hairline).padding(.leading, 14)
                    }
                }
            }
            .background(CardBackground())
        }
    }

    // MARK: data

    private func reload() async {
        detail = try? await core.novelDetail(item.novelId)
        if synopsis == nil {
            synopsis = (try? await core.novelInfo(url: item.tocUrl))?.story
        }
    }

    private func shortDate(_ s: String) -> String {
        String(s.prefix(10))
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
