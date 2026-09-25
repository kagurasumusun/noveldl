import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
#endif

struct ReaderRoute: Hashable, Identifiable {
    let novelId: String
    let index: String
    let title: String
    let tocUrl: String
    var id: String { "\(novelId)#\(index)" }
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
    @State private var episodesLimit = 0
    @State private var fromIndex = ""

    @State private var flatChapters: [ChapterMeta] = []
    @State private var chapterLimit = 60
    @State private var readerRoute: ReaderRoute?
    @State private var customCover: UIImage?
#if canImport(PhotosUI)
    @State private var coverPick: PhotosPickerItem?
#endif
    @State private var showLegacyPicker = false

    private var downloaded: Int { detail?.downloadedCount ?? item.downloadedCount ?? 0 }
    private var total: Int { max(detail?.novel.episodeCount ?? item.episodeCount, 1) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                heroCard
                metaGrid
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
        .fullScreenCover(item: $readerRoute) { route in
            ReaderView(novelId: route.novelId, startAt: route.index, title: route.title, tocUrl: route.tocUrl)
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

    // MARK: 書誌(書影の布を帯に展開した装丁)

    /// 表紙は「横広の 1 画像」のみ(カスタム画像も可)。
    private var heroCard: some View {
        WideCover(
            title: item.title,
            author: item.author,
            image: customCover ?? core.covers[item.novelId]
        )
        .overlay(alignment: .topTrailing) {
            #if canImport(PhotosUI)
            PhotosPicker(selection: $coverPick, matching: .images) {
                coverPickGlyph
            }
            .padding(Spacing.s)
            #else
            Button { showLegacyPicker = true } label: { coverPickGlyph }
                .padding(Spacing.s)
            #endif
        }
        #if canImport(PhotosUI)
        .onChange(of: coverPick) {
            guard let pick = coverPick else { return }
            Task {
                if let data = try? await pick.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    CoverStore.save(img, storagePath: item.storagePath)
                    customCover = CoverStore.customImage(item.storagePath)
                    Haptics.success()
                }
            }
        }
        #else
        .sheet(isPresented: $showLegacyPicker) {
            LegacyImagePicker { img in
                CoverStore.save(img, storagePath: item.storagePath)
                customCover = CoverStore.customImage(item.storagePath)
                Haptics.success()
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private var coverPickGlyph: some View {
        Image(systemName: "photo.on.rectangle.angled")
            .font(AppFont.ui(13, weight: .semibold))
            .foregroundStyle(Color(red: 0.95, green: 0.93, blue: 0.90))
            .frame(width: 38, height: 38)
            .background(Circle().fill(.black.opacity(0.35)))
    }

    /// 情報(META):作者・状態・話数・コメント・更新・取得状況を一枚の棚札に。
    private var metaGrid: some View {
        VStack(spacing: 0) {
            metaRow("作者", item.author)
            RowDivider(leading: Spacing.l)
            if let status = detail?.novel.status, !status.isEmpty {
                metaRow("状態", status)
                RowDivider(leading: Spacing.l)
            }
            metaRow("合計話数", "全\(total)話")
            if let comments = detail?.novel.commentCount, !comments.isEmpty {
                RowDivider(leading: Spacing.l)
                metaRow("コメント", comments)
            }
            if let updated = detail?.novel.siteUpdated, !updated.isEmpty {
                RowDivider(leading: Spacing.l)
                metaRow("更新日", updated)
            } else if let updated = item.updatedAt, !updated.isEmpty {
                RowDivider(leading: Spacing.l)
                metaRow("確認日", shortDate(updated))
            }
            if let next = detail?.novel.nextUpdate, !next.isEmpty {
                RowDivider(leading: Spacing.l)
                metaRow("更新予定", next)
            }
            RowDivider(leading: Spacing.l)
            // 取得状況は控えめな 1 行に(大きく出しすぎない)
            HStack(spacing: Spacing.m) {
                Text("取得済み")
                    .font(AppFont.ui(12))
                    .foregroundStyle(AppPalette.inkFaint)
                Text("\(downloaded)/\(total)")
                    .font(AppFont.ui(13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                ReadingRibbon(value: Double(downloaded) / Double(total))
                    .frame(width: 84)
                Text("\(Int(Double(downloaded) / Double(total) * 100))%")
                    .font(AppFont.ui(11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AppPalette.ember)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, 10)
        }
        .background(PaperBackground())
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(label)
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(AppPalette.inkFaint)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(AppFont.ui(14))
                .foregroundStyle(AppPalette.ink)
            Spacer()
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, 10)
    }

    private func synopsisCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            headerEN("STORY", "あらすじ")
            synopsisBody(text)
        }
    }

    private func synopsisBody(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
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
        VStack(alignment: .leading, spacing: Spacing.s) {
            headerEN("ACTIONS", "操作")
            actionBody
        }
    }

    private var actionBody: some View {
        VStack(spacing: Spacing.m) {
            // 読むを主役に(ダウンロードを大きく出しすぎない)
            if let first = detail?.chapters.first(where: { $0.bodyDownloaded == true })
                ?? detail?.chapters.first {
                Button(action: {
                    readerRoute = ReaderRoute(novelId: item.novelId, index: first.index, title: item.title, tocUrl: item.tocUrl)
                }, label: {
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
                })
                .buttonStyle(PressableButtonStyle())
            }

            // 取得まわりは控えめな一行に
            HStack(spacing: Spacing.s) {
                Button {
                    Task { await runDownload(all: true) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: busy ? "hourglass" : "arrow.down.circle")
                        Text(busy ? "取得中…" : (downloaded >= total ? "更新を確認" : "全話を取得"))
                    }
                    .font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppPalette.ember))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(busy)

                Button {
                    showOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(AppFont.ui(14, weight: .semibold))
                        .foregroundStyle(AppPalette.inkSoft)
                        .frame(width: 46, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppPalette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppPalette.hairline, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(busy)

                Button {
                    Task { await exportZip() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(AppFont.ui(14, weight: .semibold))
                        .foregroundStyle(AppPalette.inkSoft)
                        .frame(width: 46, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppPalette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppPalette.hairline, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(busy)
            }

            if let statusText {
                HStack(spacing: Spacing.s) {
                    ProgressView().scaleEffect(0.8)
                    Text(statusText)
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkSoft)
                    Spacer()
                }
            }

            if core.progress.running {
                HStack {
                    Text("間隔を空けて取得中")
                        .font(AppFont.ui(11))
                        .foregroundStyle(AppPalette.inkFaint)
                    Spacer()
                    Button("中止") { core.cancel() }
                        .font(AppFont.ui(12, weight: .semibold))
                        .foregroundStyle(AppPalette.ember)
                }
            }
        }
    }

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
                headerEN("INDEX", "目次")
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Text("全\(total)話")
                    .font(AppFont.ui(13))
                    .foregroundStyle(AppPalette.inkSoft)
                    .monospacedDigit()
            }
            .padding(.top, Spacing.s)

            VStack(spacing: 0) {
                let visible = Array(flatChapters.prefix(chapterLimit))
                ForEach(visible.indices, id: \.self) { i in
                    let ch = visible[i]
                    if i == 0 || visible[i - 1].chapter != ch.chapter {
                        if let group = ch.chapter, !group.isEmpty {
                            Text(group)
                                .font(AppFont.ui(12, weight: .semibold))
                                .foregroundStyle(AppPalette.gold)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.l)
                                .padding(.top, Spacing.l)
                                .padding(.bottom, Spacing.xs)
                                .background(AppPalette.canvas)
                        }
                    }
                    chapterRow(ch)
                    RowDivider(leading: Spacing.l)
                }
                if flatChapters.count > chapterLimit {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { chapterLimit += 200 }
                    } label: {
                        Text("さらに \(min(200, flatChapters.count - chapterLimit)) 話を表示(残り \(flatChapters.count - chapterLimit))")
                            .font(AppFont.ui(13, weight: .semibold))
                            .foregroundStyle(AppPalette.ember)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .background(PaperBackground())
        }
    }

    /// 英語の見出しを主役に、日本語は小さく添える(メリハリをはっきり)。
    private func headerEN(_ en: String, _ jp: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(en)
                .font(AppFont.serif(15, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .tracking(2.5)
            Text(jp)
                .font(AppFont.ui(10))
                .foregroundStyle(AppPalette.inkFaint)
            Spacer()
        }
        .padding(.top, Spacing.m)
    }

    private func chapterRow(_ ch: ChapterMeta) -> some View {
        Button(action: {
            readerRoute = ReaderRoute(novelId: item.novelId, index: ch.index, title: item.title, tocUrl: item.tocUrl)
        }, label: {
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
        })
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: data

    private func reload() async {
        detail = try? await core.novelDetail(item.novelId)
        flatChapters = detail?.chapters ?? []
        customCover = CoverStore.customImage(item.storagePath)
        if synopsis == nil {
            // あらすじは追加時に保存したものを優先し、無ければ取りに行く
            if let stored = detail?.novel.description, !stored.isEmpty {
                synopsis = stored
            } else {
                synopsis = (try? await core.novelInfo(url: item.tocUrl))?.story
            }
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
            var msg = "取得済み: 新規 \(result.saved)話・更新 \(result.updated)話・スキップ \(result.skipped)話"
            if result.failed > 0 {
                msg += "・失敗 \(result.failed)話(再実行で続きから取得します)"
            }
            errorText = msg
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

    init(
        episodesLimit: Binding<Int>,
        fromIndex: Binding<String>,
        onBulk: @escaping () -> Void,
        onReader: @escaping () -> Void
    ) {
        _episodesLimit = episodesLimit
        _fromIndex = fromIndex
        self.onBulk = onBulk
        self.onReader = onReader
    }

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

#if !canImport(PhotosUI)
/// PhotosUI が使えない環境向けのフォールバック(UIKit のみで完結)。
struct LegacyImagePicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { onPick(img) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}
#endif
