import SwiftUI
import UIKit

/// 読書画面 — 独立ページ(fullScreenCover)。戻るボタンや端からのスワイプ戻りは無い。
/// 上下バーは中央タップでのみ出没。額縁のない全面レイアウト。
struct ReaderView: View {
    @Environment(CoreClient.self) private var core: CoreClient
    @Environment(\.dismiss) private var dismiss

    let novelId: String
    let startAt: String
    let title: String

    @State private var chapterIndex: String
    @State private var chapterTitle = ""
    @State private var chapterLabel = ""
    @State private var chapterProgress: Double = 0
    @State private var attributed = NSAttributedString()
    @State private var imageRefs: [ImageRef] = []
    @State private var loadError: String?
    @State private var showToc = false
    @State private var showMenu = false
    @State private var detail: LibraryNovelDetail?
    @State private var bookmarked = false
    @State private var hintVisible = false

    @AppStorage("readerTheme") private var themeRaw = BookTheme.paper.rawValue
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @AppStorage("readerLineSpacing") private var lineSpacing = 6.0
    @AppStorage("readerMargin") private var margin = 12.0
    @AppStorage("readerFontDesign") private var fontDesign = "serif"
    @AppStorage("readerSwipePaging") private var swipePaging = true
    @AppStorage("readerPageTurn") private var pageTurnRaw = PageTurn.curl.rawValue
    @AppStorage("readerShowRuby") private var showRuby = true
    @AppStorage("readerShowHeader") private var showHeader = true
    @AppStorage("readerShowFooter") private var showFooter = true

    @State private var chromeVisible = true
    @State private var lastHTML = ""
    @State private var readerBox = ScrollBox()

    private var theme: BookTheme { BookTheme(rawValue: themeRaw) ?? .paper }
    private var turn: PageTurn { PageTurn(rawValue: pageTurnRaw) ?? .curl }
    private var chapters: [ChapterMeta] { detail?.chapters ?? [] }
    private var total: Int { max(chapters.count, 1) }
    private var pos: Int { chapters.firstIndex { $0.index == chapterIndex } ?? 0 }
    private var canGoPrev: Bool { pos > 0 }
    private var canGoNext: Bool { pos + 1 < chapters.count }

    init(novelId: String, startAt: String, title: String) {
        self.novelId = novelId
        self.startAt = startAt
        self.title = title
        _chapterIndex = State(initialValue: startAt)
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            ReaderTextView(
                attributed: attributed,
                theme: theme,
                box: readerBox,
                turn: turn,
                sideMargin: max(margin, 12),
                swipePaging: swipePaging,
                onCenterTap: {
                    withAnimation(.easeInOut(duration: 0.22)) { chromeVisible.toggle() }
                },
                onPrevPage: {},
                onNextPage: {},
                onReachStart: {
                    if canGoPrev { goChapter(delta: -1) }
                },
                onReachEnd: {
                    if canGoNext { goChapter(delta: 1) }
                }
            )
            .id(chapterIndex)

            VStack {
                if chromeVisible && showHeader {
                    topBar
                        .transition(.opacity)
                }
                Spacer()
                if chromeVisible && showFooter {
                    bottomBar
                        .transition(.opacity)
                }
            }

            if hintVisible {
                hintPill
                    .transition(.opacity)
                    .frame(maxHeight: .infinity, alignment: .center)
            }

            if let loadError {
                VStack(spacing: Spacing.m) {
                    Text(loadError)
                        .font(AppFont.ui(15))
                        .foregroundStyle(theme.ink)
                        .multilineTextAlignment(.center)
                    QuietButton(title: "作品詳細へ戻る", systemImage: "xmark") { dismiss() }
                }
                .padding(Spacing.xl)
            }
        }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(.hidden, when: .hidden)
        .task(id: chapterIndex) { await load() }
        .sheet(isPresented: $showToc) { tocSheet }
        .sheet(isPresented: $showMenu) { menuSheet }
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "readerHintShown") {
                hintVisible = true
                UserDefaults.standard.set(true, forKey: "readerHintShown")
                Task {
                    try? await Task.sleep(nanoseconds: 4_500_000_000)
                    withAnimation(.easeOut(duration: 0.4)) { hintVisible = false }
                }
            }
        }
    }

    // MARK: 上下バー(中央タップで出没)

    private var topBar: some View {
        HStack(spacing: Spacing.s) {
            chromeButton("list.bullet", "一覧") { showToc = true }
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
            .frame(maxWidth: 180)
            Spacer(minLength: 0)
            chromeButton(bookmarked ? "bookmark.fill" : "bookmark", "栞") {
                bookmarked.toggle()
                saveBookmark(on: bookmarked)
                Haptics.tap()
            }
            chromeButton("square.and.arrow.up", "共有") { share() }
            chromeButton("gearshape", "設定") { showMenu = true }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(theme.background.opacity(0.94))
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            chromeCaptioned("chevron.left", "前話", enabled: canGoPrev) {
                goChapter(delta: -1)
            }
            chromeCaptioned("chevron.up", "前頁") {
                _ = readerBox.pageUp()
            }
            VStack(spacing: 3) {
                Text(chapterLabel)
                    .font(AppFont.ui(11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.ink)
                ReadingRibbon(value: chapterProgress)
                    .frame(maxWidth: 96)
            }
            .frame(maxWidth: .infinity)
            chromeCaptioned("chevron.down", "次頁") {
                _ = readerBox.pageDown()
            }
            chromeCaptioned("chevron.right", "次話", enabled: canGoNext) {
                goChapter(delta: 1)
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(theme.background.opacity(0.94))
    }

    private func chromeButton(_ system: String, _ accessibility: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: system)
                .font(AppFont.ui(15, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(haptic: false))
        .accessibilityLabel(accessibility)
    }

    private func chromeCaptioned(_ system: String, _ caption: String, enabled: Bool = true, act: @escaping () -> Void) -> some View {
        Button {
            act()
            Haptics.tap()
        } label: {
            VStack(spacing: 1) {
                Image(systemName: system)
                    .font(AppFont.ui(13, weight: .semibold))
                Text(caption)
                    .font(AppFont.ui(9, weight: .medium))
            }
            .foregroundStyle(enabled ? theme.ink : theme.ink.opacity(0.3))
            .frame(width: 52, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(haptic: false))
        .disabled(!enabled)
    }

    private var hintPill: some View {
        Text("中央タップでバーの出没・左右タップで送り")
            .font(AppFont.ui(12, weight: .medium))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(Capsule().fill(theme.background))
            .overlay(Capsule().strokeBorder(theme.ink.opacity(0.15), lineWidth: 1))
    }

    // MARK: 読書メニュー(読書時専用)

    private var menuSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text("読書メニュー")
                    .font(AppFont.serif(20, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .padding(.top, Spacing.s)

                menuSectionHeader("表示")
                VStack(spacing: 0) {
                    HStack(spacing: Spacing.s) {
                        ForEach(BookTheme.all, id: \.self) { t in
                            Button {
                                themeRaw = t.rawValue
                                applyStyle()
                                Haptics.tap()
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(t.background)
                                        .frame(width: 34, height: 34)
                                        .overlay(Circle().strokeBorder(t.ink.opacity(0.3), lineWidth: 1))
                                    Text(t.label)
                                        .font(AppFont.ui(11))
                                        .foregroundStyle(AppPalette.inkSoft)
                                }
                                .opacity(theme == t ? 1 : 0.55)
                            }
                            .buttonStyle(PressableButtonStyle(haptic: false))
                        }
                        Spacer()
                    }
                    .padding(Spacing.m)
                    RowDivider()
                    SettingRow(label: "書体") {
                        SegmentTabs(titles: ["明朝", "ゴシック", "等幅"], selection: Binding(
                            get: { fontDesign == "sans" ? 1 : (fontDesign == "mono" ? 2 : 0) },
                            set: {
                                fontDesign = $0 == 1 ? "sans" : ($0 == 2 ? "mono" : "serif")
                                applyStyle()
                            }
                        ))
                        .frame(width: 190)
                    }
                    RowDivider()
                    StepperRow(label: "文字サイズ", value: stepBinding($fontSize), range: 13...26, step: 1, suffix: "pt")
                    RowDivider()
                    StepperRow(label: "行間", value: stepBinding($lineSpacing), range: 2...14, step: 1, suffix: "pt")
                    RowDivider()
                    StepperRow(label: "余白", value: stepBinding($margin), range: 4...32, step: 2, suffix: "pt")
                }
                .background(PaperBackground())

                menuSectionHeader("表示項目")
                VStack(spacing: 0) {
                    toggleRow("ルビ(振り仮名)", showRuby) { showRuby.toggle(); applyStyle() }
                    RowDivider()
                    toggleRow("ヘッダー(タイトル)", showHeader) { showHeader.toggle() }
                    RowDivider()
                    toggleRow("フッター(進捗)", showFooter) { showFooter.toggle() }
                }
                .padding(Spacing.m)
                .background(PaperBackground())

                menuSectionHeader("送り")
                VStack(spacing: 0) {
                    SettingRow(label: "めくりの演出") {
                        SegmentTabs(titles: PageTurn.all.map(\.label), selection: Binding(
                            get: { PageTurn.all.firstIndex(of: turn) ?? 0 },
                            set: { pageTurnRaw = PageTurn.all[$0].rawValue }
                        ))
                        .frame(width: 210)
                    }
                    RowDivider()
                    toggleRow("左右スワイプで送り", swipePaging) { swipePaging.toggle() }
                }
                .background(PaperBackground())

                menuSectionHeader("移動")
                HStack(spacing: Spacing.s) {
                    QuietButton(title: "目次", systemImage: "list.bullet") {
                        showMenu = false
                        showToc = true
                    }
                    QuietButton(title: "前の話", systemImage: "chevron.left", disabled: !canGoPrev) {
                        showMenu = false
                        goChapter(delta: -1)
                    }
                    QuietButton(title: "次の話", systemImage: "chevron.right", disabled: !canGoNext) {
                        showMenu = false
                        goChapter(delta: 1)
                    }
                }
                QuietButton(title: "閉じて作品詳細へ", systemImage: "xmark") {
                    showMenu = false
                    dismiss()
                }
                .padding(.bottom, Spacing.xl)
            }
            .padding(.horizontal, Metrics.gutter)
        }
        .presentationDetents([.height(640), .large])
        .presentationCornerRadius(20)
    }

    private var tocSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("目次")
                    .font(AppFont.serif(20, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .padding(Spacing.l)
                ForEach(detail?.chapters ?? [], id: \.index) { ch in
                    Button {
                        showToc = false
                        if ch.index != chapterIndex {
                            chapterIndex = ch.index
                        }
                    } label: {
                        HStack(spacing: Spacing.m) {
                            Text("\(ch.index)")
                                .font(AppFont.ui(12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(AppPalette.inkFaint)
                                .frame(width: 36, alignment: .trailing)
                            Text(ch.subtitle)
                                .font(AppFont.serif(15))
                                .foregroundStyle(AppPalette.ink)
                                .lineLimit(2)
                            Spacer(minLength: Spacing.s)
                            if ch.index == chapterIndex {
                                Image(systemName: "book.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppPalette.ember)
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
        .presentationDetents([.medium, .large])
    }

    // MARK: 操作

    private func stepBinding(_ base: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { base.wrappedValue },
            set: {
                base.wrappedValue = $0
                applyStyle()
            }
        )
    }

    private func toggleRow(_ label: String, _ isOn: Bool, _ act: @escaping () -> Void) -> some View {
        SettingRow(label: label) {
            Button {
                act()
                Haptics.tap()
            } label: {
                Text(isOn ? "ON" : "OFF")
                    .font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(isOn ? .white : AppPalette.inkSoft)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Capsule().fill(isOn ? AppPalette.ember : AppPalette.track))
            }
            .buttonStyle(PressableButtonStyle(haptic: false))
        }
    }

    private func menuSectionHeader(_ title: String) -> some View {
        HStack(spacing: Spacing.s) {
            Text(title)
                .font(AppFont.ui(12, weight: .semibold))
                .foregroundStyle(AppPalette.gold)
            Rectangle()
                .fill(AppPalette.hairline)
                .frame(height: 1)
        }
    }

    private func goChapter(delta: Int) {
        let target = pos + delta
        guard target >= 0, target < chapters.count else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            chapterIndex = chapters[target].index
        }
        Haptics.success()
    }

    private func share() {
        let urlText = (detail?.novel.sourceUrl).map { "\($0) (\(title) \(chapterLabel))" } ?? title
        let av = UIActivityViewController(activityItems: [urlText], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.keyWindow?.rootViewController {
            root.presentedViewController?.present(av, animated: true) ?? root.present(av, animated: true)
        }
    }

    // MARK: 栞(ブックマーク)

    private var bookmarkKey: String { "readerBookmarks" }

    private func loadBookmark() {
        let list = UserDefaults.standard.stringArray(forKey: bookmarkKey) ?? []
        bookmarked = list.contains("\(novelId)#\(chapterIndex)")
    }

    private func saveBookmark(on: Bool) {
        var list = UserDefaults.standard.stringArray(forKey: bookmarkKey) ?? []
        let id = "\(novelId)#\(chapterIndex)"
        list.removeAll { $0 == id }
        if on { list.append(id) }
        UserDefaults.standard.set(list, forKey: bookmarkKey)
    }

    // MARK: data

    private let markup = ReaderMarkup()

    private func currentStyle() -> ReaderMarkup.Style {
        ReaderMarkup.Style(
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            ink: UIColor(theme.ink),
            maxWidth: UIScreen.main.bounds.width - max(margin, 12) * 2,
            design: fontDesign,
            showRuby: showRuby
        )
    }

    private func applyStyle() {
        guard !lastHTML.isEmpty else { return }
        let result = markup.parse(lastHTML, style: currentStyle())
        attributed = result.text
        imageRefs = result.images
    }

    private func load() async {
        loadError = nil
        if detail == nil {
            detail = try? await core.novelDetail(novelId)
        }
        loadBookmark()
        do {
            let section = try await core.section(novelId: novelId, index: chapterIndex)
            let meta = chapters.first { $0.index == chapterIndex }
            chapterTitle = meta?.subtitle ?? ""
            chapterLabel = "\(pos + 1)/\(total)話"
            chapterProgress = Double(pos + 1) / Double(total)
            let html = section.body.isEmpty ? "本文はまだ取得されていません。作品詳細から取得してください。" : section.body
            lastHTML = html
            let result = markup.parse(html, style: currentStyle())
            attributed = result.text
            imageRefs = result.images
            Task { await loadImages(result.images) }
        } catch {
            loadError = "読めませんでした: \(error.localizedDescription)"
        }
    }

    /// 挿絵を非同期に実画像へ差し替える(読書の応答性を落とさない)。
    private func loadImages(_ refs: [ImageRef]) async {
        let width = UIScreen.main.bounds.width - max(margin, 12) * 2
        let base = URL(string: detail?.novel.sourceUrl ?? "")
        for ref in refs {
            guard let url = ReaderImageStore.resolve(ref.src, base: base) else { continue }
            if let img = await ReaderImageStore.shared.load(url) {
                readerBox.applyImage(at: ref.range, image: img, displayWidth: width)
            }
        }
    }

    private var box: ScrollBox { readerBox }
}

/// 挿絵キャッシュと URL 解決。
enum ReaderImageStore {
    static let shared = Store()

    final class Store {
        private let cache = NSCache<NSURL, UIImage>()

        func load(_ url: URL) async -> UIImage? {
            if let hit = cache.object(forKey: url as NSURL) { return hit }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return nil }
            let scaled = downscale(img, maxW: 1200)
            cache.setObject(scaled, forKey: url as NSURL)
            return scaled
        }
    }

    static func resolve(_ src: String, base: URL?) -> URL? {
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return URL(string: src) }
        guard let base else { return nil }
        return URL(string: src, relativeTo: base)?.absoluteURL
    }

    private static func downscale(_ img: UIImage, maxW: CGFloat) -> UIImage {
        guard img.size.width > maxW else { return img }
        let scale = maxW / img.size.width
        let size = CGSize(width: maxW, height: img.size.height * scale)
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
