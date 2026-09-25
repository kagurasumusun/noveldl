import SwiftUI
import UIKit

/// 読書画面 — 既読部分はすべて UIKit 標準(UITextView のスクロール)に差し替え。
/// ・本文は常に読める(描画変換の事故を排除)
/// ・上下バーを常時表示(メニューが存在しない問題の根治)
/// ・タップゾーン(左=1画面めくり戻し / 中央=メニュー / 右=1画面めくり送り、末尾で次話)
/// ・書体・行間・余白・テーマは即時反映(カスタマイズが効かない問題の根治)
/// ・画像取得などの同期処理を排除(かくつきの根治)
struct ReaderView: View {
    let novelId: String
    let startAt: String
    let title: String

    @Environment(CoreClient.self) private var core: CoreClient
    @Environment(\.dismiss) private var dismiss

    @AppStorage("readerTheme") private var themeRaw = BookTheme.paper.rawValue
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @AppStorage("readerLineSpacing") private var lineSpacing = 6.0
    @AppStorage("readerSideMargin") private var sideMargin = 34.0
    @AppStorage("readerFontDesign") private var fontDesign = "serif"

    @State private var chapterIndex: String
    @State private var chapterTitle = ""
    @State private var rawBody = ""
    @State private var attributed = NSAttributedString()
    @State private var hasBody = false
    @State private var loading = true
    @State private var fetching = false
    @State private var chapters: [ChapterMeta] = []
    @State private var errorText: String?
    @State private var showToc = false
    @State private var showType = false

    private let scroller = ScrollBox()

    private var theme: BookTheme { BookTheme(rawValue: themeRaw) ?? .paper }

    init(novelId: String, startAt: String, title: String) {
        self.novelId = novelId
        self.startAt = startAt
        self.title = title
        let saved = ReadingPositionStore.load(novelId)
        _chapterIndex = State(initialValue: saved?.chapter ?? startAt)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                theme.background.ignoresSafeArea()
                if loading {
                    ProgressView()
                        .tint(theme.secondaryInk)
                } else if hasBody {
                    ReaderTextView(
                        attributed: attributed,
                        background: UIColor(theme.background),
                        sideMargin: CGFloat(sideMargin),
                        scroller: scroller,
                        onZone: handleZone
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    missingBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .background(theme.background.ignoresSafeArea())
        .task(id: chapterIndex) { await loadChapter() }
        .onChange(of: fontSize) { applyStyle() }
        .onChange(of: lineSpacing) { applyStyle() }
        .onChange(of: sideMargin) { applyStyle() }
        .onChange(of: fontDesign) { applyStyle() }
        .onChange(of: themeRaw) { applyStyle() }
        .onDisappear {
            ReadingPositionStore.save(novelId, chapter: chapterIndex, page: 0)
        }
        .sheet(isPresented: $showToc) { tocSheet }
        .sheet(isPresented: $showType) { typeSheet }
        .alert("リーダー", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: 常時表示バー(メニューはここに必ずある)

    private var topBar: some View {
        HStack(spacing: Spacing.m) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(AppFont.ui(16, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(PressableButtonStyle())
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(title)
                    .font(AppFont.serif(14, weight: .semibold))
                    .lineLimit(1)
                Text(chapterTitle.isEmpty ? chapterLabel : chapterTitle)
                    .font(AppFont.ui(12))
                    .opacity(0.75)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.ink)
            Spacer(minLength: 0)
            Button { showToc = true } label: {
                Image(systemName: "list.bullet")
                    .font(AppFont.ui(15, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(PressableButtonStyle())
            Button { showType = true } label: {
                Text("Aa")
                    .font(AppFont.serif(16, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(PressableButtonStyle())
        }
        .padding(.horizontal, Spacing.s)
        .frame(height: 52)
        .background(theme.background.opacity(0.98))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: Spacing.m) {
            Button {
                withAnimation { advanceChapter(delta: -1) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(AppFont.ui(14, weight: .semibold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canGoPrevious)

            VStack(spacing: 4) {
                Text(chapterLabel)
                    .font(AppFont.ui(12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.ink)
                ReadingRibbon(value: chapterProgress)
                    .frame(maxWidth: 160)
            }

            Button {
                withAnimation { advanceChapter(delta: 1) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(AppFont.ui(14, weight: .semibold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canGoNext)
        }
        .padding(.horizontal, Spacing.l)
        .frame(height: 60)
        .background(theme.background.opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    // MARK: 本文未取得

    private var missingBody: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.secondaryInk)
            Text("この話の本文はまだ取得されていません")
                .font(AppFont.serif(17))
                .foregroundStyle(theme.ink)
            if fetching {
                ProgressView()
            } else {
                Button {
                    Task { await fetchThisChapter() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("この話を取得")
                    }
                    .font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: Metrics.controlHeightSmall)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .fill(AppPalette.ember)
                    )
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    // MARK: タップゾーン

    private func handleZone(_ zone: ReaderZone) {
        switch zone {
        case .previous:
            if !scroller.pageUp() {
                // 先頭ページでは何もしない(誤操作で前に戻らない)
            }
        case .menu:
            showType = true
        case .next:
            if !scroller.pageDown() {
                withAnimation { advanceChapter(delta: 1) }
            }
        }
    }

    // MARK: データ

    private var canGoPrevious: Bool {
        guard let pos = chapters.firstIndex(where: { $0.index == chapterIndex }) else { return false }
        return pos > 0
    }

    private var canGoNext: Bool {
        guard let pos = chapters.firstIndex(where: { $0.index == chapterIndex }) else { return false }
        return pos + 1 < chapters.count
    }

    private var chapterLabel: String {
        guard let pos = chapters.firstIndex(where: { $0.index == chapterIndex }) else {
            return "\(chapterIndex) 話"
        }
        return "\(pos + 1) / \(chapters.count) 話"
    }

    private var chapterProgress: Double {
        guard let pos = chapters.firstIndex(where: { $0.index == chapterIndex }), !chapters.isEmpty
        else { return 0 }
        return Double(pos + 1) / Double(chapters.count)
    }

    private var currentStyle: ReaderMarkup.Style {
        ReaderMarkup.Style(
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            ink: UIColor(theme.ink),
            maxWidth: 280,
            design: fontDesign
        )
    }

    private func loadChapter() async {
        loading = true
        defer { loading = false }
        do {
            let section = try await core.section(novelId: novelId, index: chapterIndex)
            chapterTitle = section.subtitle
            if chapters.isEmpty {
                chapters = (try? await core.novelDetail(novelId))?.chapters ?? []
            }
            let body = [section.introXhtml, section.bodyXhtml, section.postXhtml]
                .compactMap { $0 }
                .joined(separator: "\n")
            rawBody = body
            hasBody = !(section.bodyXhtml ?? "").isEmpty || !body.isEmpty
            applyStyle()
            ReadingPositionStore.save(novelId, chapter: chapterIndex, page: 0)
        } catch {
            rawBody = ""
            attributed = NSAttributedString()
            hasBody = false
            errorText = "この話を開けません: \(error.localizedDescription)"
        }
    }

    /// 書体・行間・余白・テーマの即時反映(取得はせず描画だけ差し替える)。
    private func applyStyle() {
        guard hasBody, !rawBody.isEmpty else { return }
        attributed = ReaderMarkup().parse(rawBody, style: currentStyle)
    }

    private func advanceChapter(delta: Int) {
        guard let pos = chapters.firstIndex(where: { $0.index == chapterIndex }),
              chapters.indices.contains(pos + delta)
        else { return }
        chapterIndex = chapters[pos + delta].index
    }

    /// 未取得の話をその場で 1 話取得して開く。
    private func fetchThisChapter() async {
        guard let meta = core.library.first(where: { $0.novelId == novelId }) else {
            errorText = "作品情報が見つかりません"
            return
        }
        fetching = true
        defer { fetching = false }
        do {
            _ = try await core.download(
                CoreClient.DownloadOptions(
                    url: meta.tocUrl,
                    outputDir: meta.outputDir,
                    episodes: 1,
                    fromIndex: chapterIndex,
                    mode: "bulk"
                )
            )
            await core.reloadLibrary()
            await loadChapter()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: 目次シート

    private var tocSheet: some View {
        NavigationStack {
            List(chapters, id: \.index) { ch in
                Button {
                    chapterIndex = ch.index
                    showToc = false
                } label: {
                    HStack(spacing: Spacing.m) {
                        Text(ch.index)
                            .font(AppFont.ui(12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(AppPalette.inkFaint)
                            .frame(width: 34, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            if let group = ch.chapter, !group.isEmpty {
                                Text(group)
                                    .font(AppFont.ui(11, weight: .semibold))
                                    .foregroundStyle(AppPalette.gold)
                            }
                            Text(ch.subtitle)
                                .font(AppFont.serif(15))
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        if ch.bodyDownloaded == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AppPalette.gold)
                                .font(.system(size: 12))
                        }
                        if ch.index == chapterIndex {
                            Image(systemName: "book.fill")
                                .foregroundStyle(AppPalette.ember)
                                .font(.system(size: 12))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(PressableButtonStyle())
            }
            .navigationTitle("目次")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(20)
    }

    // MARK: 文字とレイアウト(メニューの中身)

    private var typeSheet: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                Text("文字とレイアウト")
                    .font(AppFont.serif(20, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                CircleIconButton(system: "xmark") { showType = false }
            }

            HStack(spacing: Spacing.s) {
                ForEach(BookTheme.allCases) { option in
                    Button {
                        themeRaw = option.rawValue
                    } label: {
                        Text(option.label)
                            .font(AppFont.ui(13, weight: .semibold))
                            .foregroundStyle(option.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(option.background)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                                    .strokeBorder(
                                        themeRaw == option.rawValue ? AppPalette.ember : AppPalette.hairline,
                                        lineWidth: themeRaw == option.rawValue ? 2 : 1)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            SegmentTabs(
                titles: ["明朝", "ゴシック", "等幅"],
                selection: Binding(
                    get: { ["serif", "sans", "mono"].firstIndex(of: fontDesign) ?? 0 },
                    set: { fontDesign = ["serif", "sans", "mono"][$0] }
                )
            )

            VStack(spacing: 0) {
                StepperRow(label: "文字サイズ", value: $fontSize, range: 14...28)
                RowDivider()
                StepperRow(label: "行間", value: $lineSpacing, range: 0...16)
                RowDivider()
                StepperRow(label: "余白", value: $sideMargin, range: 20...56, step: 4)
            }
            .padding(Spacing.m)
            .background(PaperBackground())

            HStack(spacing: Spacing.m) {
                QuietButton(title: "前の話", systemImage: "chevron.left", disabled: !canGoPrevious) {
                    showType = false
                    advanceChapter(delta: -1)
                }
                QuietButton(title: "次の話", systemImage: "chevron.right", disabled: !canGoNext) {
                    showType = false
                    advanceChapter(delta: 1)
                }
            }
            Spacer()
        }
        .padding(Spacing.xl)
        .presentationDetents([.height(520)])
        .presentationCornerRadius(20)
    }
}

// MARK: - 位置記憶

/// Kindle 式の読書位置。章単位のみ記録(描画中の細かい保存は行わない)。
enum ReadingPositionStore {
    private static let key = "readingPositions"

    struct Position: Codable {
        var chapter: String
        var page: Int
    }

    private static var all: [String: Position] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                let map = try? JSONDecoder().decode([String: Position].self, from: data)
            else { return [:] }
            return map
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    static func load(_ novelId: String) -> Position? { all[novelId] }

    static func save(_ novelId: String, chapter: String, page: Int) {
        var map = all
        map[novelId] = Position(chapter: chapter, page: page)
        all = map
    }
}
