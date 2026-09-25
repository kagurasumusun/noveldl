import SwiftUI

/// Reader — Kindle page serenity with Kobo's control drawer.
/// Tap the page edge to page; tap the top for chrome.
struct ReaderView: View {
    let novelId: String
    let startAt: String
    let title: String

    @Environment(CoreClient.self) private var core
    @Environment(\.dismiss) private var dismiss

    @AppStorage("readerTheme") private var themeRaw = BookTheme.paper.rawValue
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @AppStorage("readerLineSpacing") private var lineSpacing = 6.0

    @State private var chapterIndex: String
    @State private var chapterTitle = ""
    @State private var pages: [NSAttributedString] = []
    @State private var pageIndex = 0
    @State private var chapters: [ChapterMeta] = []
    @State private var showChrome = false
    @State private var showToc = false
    @State private var showType = false
    @State private var loading = true

    private var theme: BookTheme { BookTheme(rawValue: themeRaw) ?? .paper }

    init(novelId: String, startAt: String, title: String) {
        self.novelId = novelId
        self.startAt = startAt
        self.title = title
        _chapterIndex = State(initialValue: startAt)
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
                        Text("This chapter has no body yet.")
                            .font(AppFont.serif(17))
                            .foregroundStyle(theme.ink)
                        Text("Download it from the book detail page.")
                            .font(AppFont.ui(12))
                            .foregroundStyle(theme.secondaryInk)
                    }
                } else {
                    PageCanvas(
                        pages: pages,
                        pageIndex: $pageIndex,
                        background: UIColor(theme.background),
                        onSwipeNext: nextPage,
                        onSwipePrevious: previousPage
                    )
                    .ignoresSafeArea()
                }

                VStack {
                    Spacer()
                    HStack {
                        Text(pageLabel)
                            .font(AppFont.ui(10, design: .monospaced))
                            .foregroundStyle(theme.secondaryInk)
                        ReadingRibbon(value: progressRatio)
                            .frame(width: 110)
                        Text(chapterLabel)
                            .font(AppFont.ui(10))
                            .foregroundStyle(theme.secondaryInk)
                    }
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
        }
        .statusBarHidden(!showChrome)
        .task(id: chapterIndex) { await loadChapter() }
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
                        .font(AppFont.ui(10))
                        .opacity(0.75)
                        .lineLimit(1)
                }
                Spacer()
                Button { showToc = true } label: {
                    Image(systemName: "list.bullet")
                }
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.background.opacity(0.97))

            Spacer()

            HStack(spacing: 18) {
                Button(action: previousPage) {
                    Image(systemName: "chevron.left")
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
                                    .font(AppFont.ui(10, weight: .semibold))
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
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var typeSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Typography")
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

            Stepper(value: $fontSize, in: 14...28) {
                LabeledContent("Text size") { Text("\(Int(fontSize))") }
            }
            Stepper(value: $lineSpacing, in: 0...16) {
                LabeledContent("Line spacing") { Text("\(Int(lineSpacing))") }
            }

            Spacer()
        }
        .padding(24)
        .presentationDetents([.height(340)])
        .onChange(of: fontSize) { Task { await repaginate() } }
        .onChange(of: lineSpacing) { Task { await repaginate() } }
    }

    // MARK: data

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
        return "Ch \(idx)"
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
            maxWidth: 300)
        let markup = ReaderMarkup().parse(body, style: style)
        let bounds = UIScreen.main.bounds.size
        let page = PagePaginator.paginate(
            markup,
            pageSize: CGSize(width: bounds.width, height: bounds.height),
            insets: UIEdgeInsets(top: 54, left: 34, bottom: 64, right: 34))
        self.pages = page
        self.pageIndex = 0
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
