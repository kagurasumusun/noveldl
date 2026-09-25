import SwiftUI
import UIKit

/// Reader — Kindle page serenity with Kobo's control drawer.
/// Tap the page edge to page; tap the top for chrome.
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
    @State private var pages: [NSAttributedString] = []
    @State private var pageIndex = 0
    @State private var chapters: [ChapterMeta] = []
    @State private var showChrome = false
    @State private var showToc = false
    @State private var showType = false
    @State private var showMenu = false
    @State private var loading = true

    private var theme: BookTheme { BookTheme(rawValue: themeRaw) ?? .paper }

    init(novelId: String, startAt: String, title: String) {
        self.novelId = novelId
        self.startAt = startAt
        self.title = title
        // Resume the last reading position when one is stored.
        let saved = ReadingPositionStore.load(novelId)
        _chapterIndex = State(initialValue: saved?.chapter ?? startAt)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.background.ignoresSafeArea()

                if loading {
                    ProgressView()
                        .tint(theme.secondaryInk)
                } else if pages.isEmpty {
                    VStack(spacing: 10) {
                        Text("この話の本文はまだ取得されていません")
                            .font(AppFont.serif(17))
                            .foregroundStyle(theme.ink)
                        Text("作品詳細から全話をダウンロードしてください")
                            .font(AppFont.ui(13))
                            .foregroundStyle(theme.secondaryInk)
                    }
                } else {
                    PageCanvas(
                        pages: pages,
                        pageIndex: $pageIndex,
                        background: UIColor(theme.background),
                        insets: pageInsets
                    )
                    .ignoresSafeArea()
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 16)
                            .onEnded { value in
                                // 横ドラッグで 1 ページ送り(左ドラッグ=次へ)。
                                // 画面端からのスワイプでも戻りジェスチャに奪われない。
                                let dx = value.translation.width
                                let dy = value.translation.height
                                guard abs(dx) > 40, abs(dx) > abs(dy) * 1.4 else { return }
                                if dx < 0 {
                                    nextPage()
                                } else {
                                    previousPage()
                                }
                            }
                    )
                }

                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Text(pageLabel)
                            .font(AppFont.ui(12, design: .monospaced))
                            .foregroundStyle(theme.secondaryInk)
                            .layoutPriority(1)
                        ReadingRibbon(value: progressRatio)
                            .frame(minWidth: 48, maxWidth: 130)
                        Text(chapterLabel)
                            .font(AppFont.ui(13))
                            .foregroundStyle(theme.secondaryInk)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
                    .opacity(showChrome ? 0.0 : 1.0)
                }

                if showChrome {
                    chrome(size: geo.size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.18)) { showChrome.toggle() }
            }
            .simultaneousGesture(
                SpatialTapGesture(count: 1)
                    .onEnded { value in
                        // Kindle page zones: left third = back, right third = next,
                        // center = show/hide chrome. Phone-sized hit targets.
                        let x = value.location.x
                        let w = geo.size.width
                        if x < w / 3 {
                            previousPage()
                        } else if x > w * 2 / 3 {
                            nextPage()
                        } else {
                            withAnimation(.easeOut(duration: 0.18)) { showChrome.toggle() }
                        }
                    }
            )
        }
        .statusBarHidden(!showChrome)
        .task(id: chapterIndex) { await loadChapter() }
        .onChange(of: pageIndex) { _, newValue in
            ReadingPositionStore.save(novelId, chapter: chapterIndex, page: newValue)
        }
        .onChange(of: chapterIndex) { _, newValue in
            ReadingPositionStore.save(novelId, chapter: newValue, page: 0)
        }
        .onDisappear {
            ReadingPositionStore.save(novelId, chapter: chapterIndex, page: pageIndex)
        }
    }

    // MARK: chrome

    private func chrome(size: CGSize) -> some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                }
                Spacer()
                VStack(spacing: 1) {
                    Text(title)
                        .font(AppFont.serif(14, weight: .medium))
                        .lineLimit(1)
                    Text(chapterTitle)
                        .font(AppFont.ui(13))
                        .opacity(0.75)
                        .lineLimit(1)
                }
                Spacer()
                Button { showMenu = true } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("メニュー")
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.background.opacity(0.97))

            Spacer()

            HStack(spacing: 12) {
                Button(action: previousPage) {
                    Image(systemName: "chevron.left")
                        .frame(width: 32, height: 32)
                }
                Slider(
                    value: Binding(
                        get: { Double(pageIndex) },
                        set: { pageIndex = Int($0) }
                    ),
                    in: 0...Double(max(pages.count - 1, 1))
                )
                .tint(AppPalette.ember)
                Button(action: nextPage) {
                    Image(systemName: "chevron.right")
                        .frame(width: 32, height: 32)
                }
                Button { showType = true } label: {
                    Text("Aa")
                        .font(AppFont.serif(17, weight: .semibold))
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(theme.background.opacity(0.97))
        }
        .transition(.opacity)
        .sheet(isPresented: $showToc) {
            tocSheet
        }
        .sheet(isPresented: $showType) {
            typeSheet
        }
        .sheet(isPresented: $showMenu) {
            menuSheet
        }
    }

    private var menuSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("メニュー")
                .font(AppFont.serif(20, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .padding(.top, 22)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            menuRow(icon: "list.bullet", title: "目次", detail: "\(chapters.count) 話") {
                showMenu = false
                showToc = true
            }
            Divider().overlay(AppPalette.hairline).padding(.horizontal, 24)
            menuRow(icon: "textformat.size", title: "文字とレイアウト", detail: "書体・行間・余白") {
                showMenu = false
                showType = true
            }
            Divider().overlay(AppPalette.hairline).padding(.horizontal, 24)
            menuRow(icon: "chevron.left", title: "前の話", detail: previousChapterTitle) {
                showMenu = false
                advanceChapter(delta: -1)
            }
            Divider().overlay(AppPalette.hairline).padding(.horizontal, 24)
            menuRow(icon: "chevron.right", title: "次の話", detail: nextChapterTitle) {
                showMenu = false
                advanceChapter(delta: 1)
            }
            Divider().overlay(AppPalette.hairline).padding(.horizontal, 24)
            menuRow(icon: "arrow.uturn.backward", title: "閉じて作品詳細へ", detail: "") {
                showMenu = false
                dismiss()
            }
            Spacer()
        }
        .presentationDetents([.height(380)])
    }

    private func menuRow(
        icon: String, title: String, detail: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(AppFont.ui(16, weight: .medium))
                    .foregroundStyle(AppPalette.ember)
                    .frame(width: 26)
                Text(title)
                    .font(AppFont.ui(16))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Text(detail)
                    .font(AppFont.ui(13))
                    .foregroundStyle(AppPalette.inkFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var previousChapterTitle: String {
        guard let pos = chapters.firstIndex(where: { $0.index == chapterIndex }),
              pos > 0 else { return "なし" }
        return chapters[pos - 1].subtitle
    }

    private var nextChapterTitle: String {
        guard let pos = chapters.firstIndex(where: { $0.index == chapterIndex }),
              pos + 1 < chapters.count else { return "なし" }
        return chapters[pos + 1].subtitle
    }

    private var tocSheet: some View {
        NavigationStack {
            List(chapters, id: \.index) { ch in
                Button {
                    chapterIndex = ch.index
                    pageIndex = 0
                    showToc = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if let group = ch.chapter, !group.isEmpty {
                                Text(group)
                                    .font(AppFont.ui(12, weight: .semibold))
                                    .foregroundStyle(AppPalette.gold)
                            }
                            Text(ch.subtitle)
                                .font(AppFont.serif(16))
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
                }
            }
            .navigationTitle("目次")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var typeSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("文字とレイアウト")
                .font(AppFont.serif(20, weight: .semibold))

            HStack(spacing: 14) {
                ForEach(BookTheme.allCases) { option in
                    Button {
                        themeRaw = option.rawValue
                    } label: {
                        Text(option.label)
                            .font(AppFont.ui(13, weight: .medium))
                            .foregroundStyle(option.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(option.background)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                                    .strokeBorder(
                                        themeRaw == option.rawValue ? AppPalette.ember : .clear,
                                        lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                ForEach(["serif", "sans", "mono"], id: \.self) { design in
                    Button {
                        fontDesign = design
                    } label: {
                        Text(design == "serif" ? "Mincho" : design == "sans" ? "Gothic" : "Mono")
                            .font(.system(size: 15, design: design == "serif" ? .serif : design == "sans" ? .default : .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(theme.background)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                                    .strokeBorder(fontDesign == design ? AppPalette.ember : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }

            Stepper(value: $fontSize, in: 14...28) {
                LabeledContent("文字サイズ") { Text("\(Int(fontSize))") }
            }
            Stepper(value: $lineSpacing, in: 0...16) {
                LabeledContent("行間") { Text("\(Int(lineSpacing))") }
            }
            Stepper(value: $sideMargin, in: 20...56, step: 4) {
                LabeledContent("余白") { Text("\(Int(sideMargin))") }
            }

            Spacer()
        }
        .padding(24)
        .presentationDetents([.height(430), .medium])
        .onChange(of: fontSize) { Task { await repaginate() } }
        .onChange(of: lineSpacing) { Task { await repaginate() } }
        .onChange(of: sideMargin) { Task { await repaginate() } }
        .onChange(of: fontDesign) { Task { await repaginate() } }
    }

    // MARK: data

    /// ページ送りと描画で必ず同じ余白を使う(ズレると本文が欠ける)。
    private var pageInsets: UIEdgeInsets {
        let side = CGFloat(sideMargin)
        return UIEdgeInsets(top: 54, left: side, bottom: 64, right: side)
    }

    private var pageLabel: String {
        guard !pages.isEmpty else { return "" }
        return "\(pageIndex + 1) / \(pages.count)"
    }

    private var progressRatio: Double {
        guard !pages.isEmpty else { return 0 }
        return Double(pageIndex + 1) / Double(pages.count)
    }

    private var chapterLabel: String {
        guard let idx = Int(chapterIndex) else { return "" }
        return "\(idx) 話"
    }

    private func loadChapter() async {
        loading = true
        defer { loading = false }
        do {
            let section = try await core.section(novelId: novelId, index: chapterIndex)
            chapterTitle = section.subtitle
            let body = [section.introXhtml, section.bodyXhtml, section.postXhtml]
                .compactMap { $0 }
                .joined(separator: "\n")
            let detail = try? await core.novelDetail(novelId)
            chapters = detail?.chapters ?? []
            await paginate(body: body)
        } catch {
            pages = []
        }
    }

    private func repaginate() async {
        guard !pages.isEmpty else { return }
        // rebuild from source (chapter reload keeps it simple + correct)
        await loadChapter()
    }

    private func paginate(body: String) async {
        let style = ReaderMarkup.Style(
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            ink: UIColor(theme.ink),
            maxWidth: 300,
            design: fontDesign)
        let markup = ReaderMarkup().parse(body, style: style)
        let bounds = UIScreen.main.bounds.size
        let page = PagePaginator.paginate(
            markup,
            pageSize: CGSize(width: bounds.width, height: bounds.height),
            insets: pageInsets)
        self.pages = page
        let saved = ReadingPositionStore.load(novelId)
        self.pageIndex = (saved?.chapter == chapterIndex) ? min(saved?.page ?? 0, max(page.count - 1, 0)) : 0
    }

    private func nextPage() {
        guard !pages.isEmpty else { return }
        if pageIndex + 1 < pages.count {
            pageIndex += 1
        } else {
            advanceChapter(delta: 1)
        }
    }

    private func previousPage() {
        if pageIndex > 0 {
            pageIndex -= 1
        } else {
            advanceChapter(delta: -1)
        }
    }

    private func advanceChapter(delta: Int) {
        guard let pos = chapters.firstIndex(where: { $0.index == chapterIndex }),
            chapters.indices.contains(pos + delta)
        else { return }
        chapterIndex = chapters[pos + delta].index
        pageIndex = 0
    }
}


/// Kindle-style reading position: resumes each book where the reader left off.
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
