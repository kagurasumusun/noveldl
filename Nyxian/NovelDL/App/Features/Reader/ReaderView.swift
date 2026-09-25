import SwiftUI
import UIKit

/// 読書画面 — 本文は UITextView のネイティブスクロール。
/// 読書用メニュー(表示/送り/移動)は読書画面専用。アプリ設定とは分離。
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
    @AppStorage("readerSwipePaging") private var swipePaging = true
    @AppStorage("readerPageTurn") private var pageTurnRaw = PageTurn.curl.rawValue

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
    @State private var showMenu = false
    @State private var chromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var showHint = false

    private let scroller = ScrollBox()

    private var theme: BookTheme { BookTheme(rawValue: themeRaw) ?? .paper }
    private var pageTurn: PageTurn { PageTurn(rawValue: pageTurnRaw) ?? .curl }

    init(novelId: String, startAt: String, title: String) {
        self.novelId = novelId
        self.startAt = startAt
        self.title = title
        let saved = ReadingPositionStore.load(novelId)
        _chapterIndex = State(initialValue: saved?.chapter ?? startAt)
    }

    var body: some View {
        ZStack {
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
                        swipePaging: swipePaging,
                        scroller: scroller,
                        onZone: { handleZone($0) }
                    )
                    .id(chapterIndex)
                    .transition(.opacity)
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    missingBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }

            if showHint {
                hintPill
            }
        }
        .background(theme.background.ignoresSafeArea())
        .onAppear {
            scroller.turn = pageTurn
            flashChrome()
            maybeShowHint()
        }
        .onChange(of: pageTurnRaw) { _, v in
            scroller.turn = PageTurn(rawValue: v) ?? .curl
        }
        .onChange(of: showToc) { _, open in if !open { flashChrome() } }
        .onChange(of: showMenu) { _, open in if !open { flashChrome() } }
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
        .sheet(isPresented: $showMenu) { menuSheet }
        .alert("リーダー", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: 常時バー(自動退場する読書用の最小操作)

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
            Button { openMenu() } label: {
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
        .opacity(chromeVisible ? 1 : 0)
        .offset(y: chromeVisible ? 0 : -14)
        .allowsHitTesting(chromeVisible)
        .animation(.easeInOut(duration: 0.4), value: chromeVisible)
    }

    private var bottomBar: some View {
        HStack(spacing: Spacing.m) {
            Button {
                goChapter(delta: -1)
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
                goChapter(delta: 1)
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
        .opacity(chromeVisible ? 1 : 0)
        .offset(y: chromeVisible ? 0 : 14)
        .allowsHitTesting(chromeVisible)
        .animation(.easeInOut(duration: 0.4), value: chromeVisible)
    }

    private var hintPill: some View {
        VStack {
            Spacer()
            Text("中央をタップで読書メニュー・左右で送り")
                .font(AppFont.ui(13, weight: .medium))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(theme.background.opacity(0.9)))
                .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 1))
                .padding(.bottom, 96)
        }
        .transition(.opacity)
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

    // MARK: 操作の度合い(はきはきしすぎない)

    private func flashChrome(autoHide: Bool = true) {
        chromeHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.35)) { chromeVisible = true }
        if autoHide {
            chromeHideTask = Task {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if !Task.isCancelled && !showToc && !showMenu {
                    withAnimation(.easeInOut(duration: 0.45)) { chromeVisible = false }
                }
            }
        }
    }

    private func hideChrome() {
        chromeHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.45)) { chromeVisible = false }
    }

    private func maybeShowHint() {
        guard UserDefaults.standard.string(forKey: "readerHintShown") != "1" else { return }
        UserDefaults.standard.set("1", forKey: "readerHintShown")
        withAnimation(.easeInOut(duration: 0.5)) { showHint = true }
        Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            withAnimation(.easeInOut(duration: 0.6)) { showHint = false }
        }
    }

    private func openMenu() {
        flashChrome(autoHide: false)
        showMenu = true
    }

    // MARK: タップゾーン

    private func handleZone(_ zone: ReaderZone) {
        scroller.turn = pageTurn
        switch zone {
        case .previous:
            if chromeVisible { hideChrome() }
            scroller.pageUp()
        case .menu:
            openMenu()
        case .next:
            if chromeVisible { hideChrome() }
            if !scroller.pageDown() {
                goChapter(delta: 1)
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

    private func goChapter(delta: Int) {
        guard let pos = chapters.firstIndex(where: { $0.index == chapterIndex }),
              chapters.indices.contains(pos + delta)
        else { return }
        Haptics.success()
        withAnimation(.easeInOut(duration: 0.3)) {
            chapterIndex = chapters[pos + delta].index
        }
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

    // MARK: 目次(読書用の移動メニュー)

    private var tocSheet: some View {
        NavigationStack {
            List(chapters, id: \.index) { ch in
                Button {
                    goChapterFromToc(ch.index)
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
                            HStack(spacing: 6) {
                                Text(ch.subtitle)
                                    .font(AppFont.serif(15))
                                    .foregroundStyle(.primary)
                                if let mark = ch.subupdate, !mark.isEmpty {
                                    Text(mark == "revised" ? "改" : mark)
                                        .font(AppFont.ui(10, weight: .bold))
                                        .foregroundStyle(AppPalette.ember)
                                }
                            }
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

    private func goChapterFromToc(_ index: String) {
        showToc = false
        if index != chapterIndex {
            Haptics.success()
            withAnimation(.easeInOut(duration: 0.3)) { chapterIndex = index }
        }
    }

    // MARK: 読書メニュー(読書専用 — アプリ設定とは別)

    private var menuSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack {
                    Text("読書メニュー")
                        .font(AppFont.serif(20, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Spacer()
                    CircleIconButton(system: "xmark") { showMenu = false }
                }

                menuSectionHeader("表示")
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

                menuSectionHeader("送り")
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("めくりの演出")
                        .font(AppFont.ui(13))
                        .foregroundStyle(AppPalette.inkSoft)
                    SegmentTabs(
                        titles: PageTurn.all.map(\.label),
                        selection: Binding(
                            get: { PageTurn.all.firstIndex(of: pageTurn) ?? 0 },
                            set: { pageTurnRaw = PageTurn.all[$0].rawValue }
                        )
                    )
                    RowDivider()
                    SettingRow(label: "左右スワイプで送り", detail: "画面端のタップ送りと共存") {
                        Button {
                            swipePaging.toggle()
                            Haptics.tap()
                        } label: {
                            Text(swipePaging ? "ON" : "OFF")
                                .font(AppFont.ui(13, weight: .semibold))
                                .foregroundStyle(swipePaging ? .white : AppPalette.inkSoft)
                                .padding(.horizontal, 14)
                                .frame(height: 32)
                                .background(
                                    Capsule().fill(swipePaging ? AppPalette.ember : AppPalette.track)
                                )
                        }
                        .buttonStyle(PressableButtonStyle(haptic: false))
                    }
                }
                .padding(Spacing.m)
                .background(PaperBackground())

                menuSectionHeader("移動")
                HStack(spacing: Spacing.m) {
                    QuietButton(title: "目次", systemImage: "list.bullet") {
                        showMenu = false
                        showToc = true
                    }
                    QuietButton(title: "前の話", systemImage: "chevron.left", disabled: !canGoPrevious) {
                        showMenu = false
                        goChapter(delta: -1)
                    }
                    QuietButton(title: "次の話", systemImage: "chevron.right", disabled: !canGoNext) {
                        showMenu = false
                        goChapter(delta: 1)
                    }
                }
            }
            .padding(Spacing.xl)
        }
        .presentationDetents([.height(640), .large])
        .presentationCornerRadius(20)
    }

    private func menuSectionHeader(_ title: String) -> some View {
        HStack(spacing: Spacing.s) {
            Text(title)
                .font(AppFont.ui(12, weight: .semibold))
                .tracking(2)
                .foregroundStyle(AppPalette.gold)
            Rectangle().fill(AppPalette.hairline).frame(height: 1)
        }
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
