import SwiftUI

struct ReaderRoute: Hashable {
    let novelId: String
    let index: String
    let title: String
}

/// 作品詳細 — 書誌・あらすじ・操作・目次を一枚の紙面として構成。
struct NovelDetailView: View {
    let item: LibraryNovelItem

    @Environment(CoreClient.self) private var core: CoreClient
    @Environment(\.dismiss) private var dismiss
    @State private var detail: LibraryNovelDetail?
    @State private var synopsis: String?
    @State private var synopsisExpanded = false
    @State private var busy = false
    @State private var statusText: String?
    @State private var errorText: String?
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
            VStack(alignment: .leading, spacing: Spacing.l) {
                heroCard
                if let synopsis, !synopsis.isEmpty {
                    synopsisCard(synopsis)
                }
                actionCard
                chapterSection
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.s)
            .padding(.bottom, 40)
        }
        .background(AppPalette.canvas.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showOptions) { optionsSheet }
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

    // MARK: 書誌(書影の布を帯に展開した装丁)

    private var heroCard: some View {
        let cloth = CoverTile.clothColor(title: item.title, author: item.author)
        let cream = Color(red: 0.925, green: 0.890, blue: 0.808)
        return VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [cloth.opacity(0.92), cloth],
                    startPoint: .top, endPoint: .bottom
                )
                .overlay(alignment: .top) {
                    VStack(spacing: 2) {
                        Rectangle().fill(cream.opacity(0.55)).frame(height: 1)
                        Rectangle().fill(cream.opacity(0.3)).frame(height: 1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                }

                HStack(alignment: .bottom, spacing: Spacing.l) {
                    CoverTile(
                        title: item.title,
                        author: item.author,
                        progress: Double(downloaded) / Double(total),
                        width: 104
                    )
                    .shadow(color: AppPalette.shelfShadow, radius: 10, x: 0, y: 8)
                    .offset(y: 30)
                    .padding(.leading, Spacing.l)

                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(item.title)
                            .font(AppFont.serif(19, weight: .semibold))
                            .foregroundStyle(cream)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Rectangle().fill(cream.opacity(0.55)).frame(width: 22, height: 1)
                        Text(item.author)
                            .font(AppFont.ui(14, weight: .medium))
                            .foregroundStyle(cream.opacity(0.8))
                    }
                    .padding(.bottom, Spacing.xl)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 168)
            .clipped()

            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    InfoChip(text: item.domain)
                    if let updated = item.updatedAt, !updated.isEmpty {
                        InfoChip(text: "更新 \(shortDate(updated))")
                    }
                    Spacer()
                }
                .padding(.top, 38)
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
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.l)
        }
        .background(PaperBackground())
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    // MARK: あらすじ    // MARK: あらすじ

    private func synopsisCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
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
                    withAnimation(.easeOut(duration: 0.18)) { synopsisExpanded.toggle() }
                } label: {
                    Text(synopsisExpanded ? "閉じる" : "もっと読む")
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(AppPalette.ember)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperBackground())
    }

    // MARK: 操作

    private var actionCard: some View {
        VStack(spacing: Spacing.m) {
            EmberButton(
                title: busy
                    ? "ダウンロード中…"
                    : (downloaded >= total ? "未取得・更新分を確認して取得" : "全話をダウンロード"),
                systemImage: "arrow.down.circle.fill",
                prominent: true,
                disabled: busy
            ) {
                Task { await runDownload(all: true) }
            }

            if let statusText {
                HStack(spacing: Spacing.s) {
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
                .buttonStyle(PressableButtonStyle())
            }

            HStack(spacing: Spacing.m) {
                QuietButton(title: "範囲を指定…", systemImage: "slider.horizontal.3", disabled: busy) {
                    showOptions = true
                }
                QuietButton(title: "書き出し", systemImage: "square.and.arrow.up", disabled: busy) {
                    Task { await exportZip() }
                }
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
                        .buttonStyle(PressableButtonStyle())
                }
            }
        }
        .padding(Spacing.l)
        .background(PaperBackground())
    }

    // MARK: 範囲指定シート(アラートの数値入力を廃止)

    private var optionsSheet: some View {
        OptionsSheetBody(
            episodesLimit: episodesLimitBinding,
            fromIndex: fromIndexBinding,
            onBulk: {
                showOptions = false
                Task { await runDownload() }
            },
            onReader: {
                showOptions = false
                Task { await runDownload(mode: "reader") }
            }
        )
    }

    private var episodesLimitBinding: Binding<Int> {
        Binding(get: { episodesLimit }, set: { episodesLimit = $0 })
    }

    private var fromIndexBinding: Binding<String> {
        Binding(get: { fromIndex }, set: { fromIndex = $0 })
    }

    // MARK: 目次

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
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
            .padding(.top, Spacing.s)

            VStack(spacing: 0) {
                ForEach(groupedChapters) { group in
                    if !group.id.isEmpty {
                        Text(group.id)
                            .font(AppFont.ui(12, weight: .semibold))
                            .foregroundStyle(AppPalette.gold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.l)
                            .padding(.top, Spacing.l)
                            .padding(.bottom, Spacing.xs)
                            .background(AppPalette.canvas)
                    }
                    ForEach(group.chapters, id: \.index) { ch in
                        NavigationLink(
                            value: ReaderRoute(novelId: item.novelId, index: ch.index, title: item.title)
                        ) {
                            HStack(spacing: Spacing.m) {
                                Text(ch.index)
                                    .font(AppFont.ui(12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(AppPalette.inkFaint)
                                    .frame(width: 36, alignment: .trailing)
                                Text(ch.subtitle)
                                    .font(AppFont.serif(15))
                                    .foregroundStyle(AppPalette.ink)
                                    .lineLimit(2)
                                Spacer(minLength: Spacing.s)
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
                            .padding(.horizontal, Spacing.l)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableButtonStyle())
                        RowDivider(leading: Spacing.l)
                    }
                }
            }
            .background(PaperBackground())
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

    private func runDownload(mode: String = "bulk", all: Bool = false) async {
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

/// 範囲指定シート本体(数値ステッパー + 開始話)。
private struct OptionsSheetBody: View {
    @Binding var episodesLimit: Int
    @Binding var fromIndex: String
    let onBulk: () -> Void
    let onReader: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Text("範囲を指定")
                    .font(AppFont.serif(22, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
            }
            Text("取得話数 0 で全話をまとめて取得します。失敗した話は再実行で続きから取得されます。")
                .font(AppFont.ui(13))
                .foregroundStyle(AppPalette.inkSoft)
                .lineSpacing(3)

            VStack(spacing: Spacing.s) {
                StepperRow(label: "取得話数(0 = 全話)", value: Binding(
                    get: { Double(episodesLimit) },
                    set: { episodesLimit = Int($0) }
                ), range: 0...5000, step: 1)
                RowDivider()
                HStack(spacing: Spacing.m) {
                    Text("開始話(空欄 = 先頭)")
                        .font(AppFont.ui(15))
                        .foregroundStyle(AppPalette.ink)
                    Spacer()
                    TextField("1", text: $fromIndex)
                        .keyboardType(.numberPad)
                        .font(AppFont.ui(15).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                .frame(height: Metrics.rowHeight)
            }
            .padding(Spacing.m)
            .background(PaperBackground())

            EmberButton(title: "一括取得", systemImage: "arrow.down.circle.fill", prominent: true) {
                onBulk()
            }
            QuietButton(title: "読者モード(先頭15話を先行取得)", systemImage: "book") {
                onReader()
            }
            Spacer()
        }
        .padding(Spacing.xl)
        .presentationDetents([.height(480)])
        .presentationCornerRadius(20)
    }
}
