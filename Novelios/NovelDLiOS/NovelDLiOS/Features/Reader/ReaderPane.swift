import SwiftUI
import UIKit
import CoreText

// MARK: - XHTML → NSAttributedString parser

final class ChapterParser: @unchecked Sendable {
    private var imageCache = NSCache<NSString, UIImage>()
    private let rubyKey = NSAttributedString.Key(rawValue: kCTRubyAnnotationAttributeName as String)
    private let maxImageBytes = 6 * 1024 * 1024

    init() {
        imageCache.countLimit = 48
        imageCache.totalCostLimit = 24 * 1024 * 1024
    }

    func parse(
        xhtml: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        fg: UIColor,
        showImages: Bool,
        fontName: String = "system",
        imageMaxWidth: CGFloat = 320
    ) -> NSAttributedString {
        let scaledFontSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: fontSize)
        let scaledLineSpacing = UIFontMetrics(forTextStyle: .body).scaledValue(for: lineSpacing)
        let font: UIFont
        switch fontName {
        case "serif": font = UIFont(name: "Hiragino Mincho ProN", size: scaledFontSize) ?? UIFont.serifPreferred(size: scaledFontSize)
        case "monospace": font = UIFont.monospacedSystemFont(ofSize: scaledFontSize, weight: .regular)
        default: font = UIFont.systemFont(ofSize: scaledFontSize)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.lineSpacing = scaledLineSpacing
                p.paragraphSpacing = max(2, scaledLineSpacing * 0.35)
                p.lineBreakMode = .byWordWrapping
                return p
            }()
        ]
        let out = NSMutableAttributedString()
        let ns  = xhtml as NSString
        // Matches ruby first so its rb/rt children are handled as one semantic unit.
        // Then handles: <img src="...">, <br/>, </p>, <p ...>, any other tag.
        let re  = try? NSRegularExpression(
            pattern: #"(?is)<ruby\b[^>]*>(.*?)</ruby>|<img\s+[^>]*src\s*=\s*['"]([^'"]+)['"][^>]*>|<br\s*/?>|</p>|<p[^>]*>|<[^>]+>"#
        )
        var cursor = 0
        for m in re?.matches(in: xhtml, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let r = m.range
            // Append text before tag
            if r.location > cursor {
                let raw = ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                appendText(raw, to: out, attributes: attrs)
            }

            if m.range(at: 1).location != NSNotFound {
                let inner = ns.substring(with: m.range(at: 1))
                out.append(rubyAttributedString(inner: inner, attributes: attrs))
            } else {
                let token = ns.substring(with: r).lowercased()
                if token.contains("<img"), showImages {
                    let sr = m.range(at: 2)
                    if sr.location != NSNotFound {
                        out.append(imageAttachment(src: ns.substring(with: sr), maxWidth: imageMaxWidth))
                    }
                } else if token.contains("<br") || token.hasPrefix("<p") || token == "</p>" {
                    out.append(NSAttributedString(string: "\n", attributes: attrs))
                }
            }
            cursor = r.location + r.length
        }
        if cursor < ns.length {
            appendText(ns.substring(from: cursor), to: out, attributes: attrs)
        }
        return out
    }

    private func appendText(
        _ raw: String,
        to out: NSMutableAttributedString,
        attributes attrs: [NSAttributedString.Key: Any]
    ) {
        let ns = raw as NSString
        let re = try? NSRegularExpression(pattern: #"｜([^《》]+?)《([^》]+?)》"#)
        var cursor = 0
        for m in re?.matches(in: raw, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let r = m.range
            if r.location > cursor {
                out.append(NSAttributedString(
                    string: decodeEntities(ns.substring(with: NSRange(location: cursor, length: r.location - cursor))),
                    attributes: attrs
                ))
            }
            let base = decodeEntities(ns.substring(with: m.range(at: 1)))
            let ruby = decodeEntities(ns.substring(with: m.range(at: 2)))
            out.append(rubyText(base: base, ruby: ruby, attributes: attrs))
            cursor = r.location + r.length
        }
        if cursor < ns.length {
            out.append(NSAttributedString(
                string: decodeEntities(ns.substring(from: cursor)),
                attributes: attrs
            ))
        }
    }

    private func rubyAttributedString(
        inner: String,
        attributes attrs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let rtRe = try? NSRegularExpression(pattern: #"(?is)<rt[^>]*>(.*?)</rt>"#)
        let full = NSRange(location: 0, length: (inner as NSString).length)
        guard let match = rtRe?.firstMatch(in: inner, range: full),
              match.range(at: 1).location != NSNotFound else {
            return NSAttributedString(string: decodeEntities(stripTags(inner)), attributes: attrs)
        }

        let ns = inner as NSString
        let ruby = decodeEntities(stripTags(ns.substring(with: match.range(at: 1))))
        let baseSource = rtRe?.stringByReplacingMatches(
            in: inner,
            range: full,
            withTemplate: ""
        ) ?? inner
        let base = decodeEntities(stripTags(baseSource))
            .replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !base.isEmpty, !ruby.isEmpty else {
            return NSAttributedString(string: base.isEmpty ? ruby : base, attributes: attrs)
        }
        return rubyText(base: base, ruby: ruby, attributes: attrs)
    }

    private func rubyText(
        base: String,
        ruby: String,
        attributes attrs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let annotation = CTRubyAnnotationCreateWithAttributes(
            .auto,
            .auto,
            .before,
            ruby as CFString,
            [:] as CFDictionary
        )
        var rubyAttrs = attrs
        rubyAttrs[rubyKey] = annotation
        return NSAttributedString(string: base, attributes: rubyAttrs)
    }

    private func stripTags(_ input: String) -> String {
        let re = try? NSRegularExpression(pattern: #"(?is)<[^>]+>"#)
        let range = NSRange(location: 0, length: (input as NSString).length)
        return re?.stringByReplacingMatches(in: input, range: range, withTemplate: "") ?? input
    }

    private func decodeEntities(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func imageAttachment(src: String, maxWidth: CGFloat) -> NSAttributedString {
        let att = NSTextAttachment()
        let w = max(maxWidth, 80)
        let key = src as NSString

        if let cached = imageCache.object(forKey: key) {
            let h = w * cached.size.height / max(cached.size.width, 1)
            att.image = cached
            att.bounds = CGRect(x: 0, y: 0, width: w, height: min(max(h, 1), w * 3))
        } else {
            let cacheKey = src
            DispatchQueue.global(qos: .utility).async { [weak self, cacheKey] in
                guard let self,
                      let u = URL(string: src),
                      let scheme = u.scheme?.lowercased(),
                      ["http", "https"].contains(scheme),
                      let d = self.fetchImageData(from: u),
                      let img = UIImage(data: d) else { return }
                self.imageCache.setObject(img, forKey: cacheKey as NSString, cost: d.count)
            }
            att.bounds = CGRect(x: 0, y: 0, width: w, height: 120)
        }
        return NSAttributedString(attachment: att)
    }

    private func fetchImageData(from url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), data.count <= maxImageBytes else { return nil }
        return data
    }
}

private extension UIFont {
    static func serifPreferred(size: CGFloat) -> UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withDesign(.serif)
            ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        return UIFont(descriptor: descriptor, size: size)
    }
}

// MARK: - Download worker

private final class NovelCoreTaskQueue: @unchecked Sendable {
    static let shared = NovelCoreTaskQueue()
    private let queue = DispatchQueue(label: "NovelDL.NovelCoreTaskQueue", qos: .utility)

    func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

final class ActiveDownloadWorker: Sendable {
    private let downloadQueue = NovelCoreTaskQueue.shared
    private let tocQueue = NovelCoreTaskQueue()


    func createLibraryPlaceholder(tocUrl: String, outputDir: String) async throws -> String {
        try await tocQueue.run {
            try NovelCoreBridge.callCreateLibraryPlaceholder(url: tocUrl, outputDir: outputDir)
        }
    }

    func fetchTocOnly(tocUrl: String, outputDir: String) async throws -> String {
        try await tocQueue.run {
            try NovelCoreBridge.callFetchTocOnly(url: tocUrl, outputDir: outputDir)
        }
    }

    func fetchTocOnlyFromBrowserHTML(tocUrl: String, html: String, outputDir: String) async throws -> String {
        try await tocQueue.run {
            try NovelCoreBridge.callDownloadFirstNFromHtml(
                url: tocUrl,
                tocHtml: html,
                episodes: 0,
                outputDir: outputDir
            )
        }
    }


    func downloadFromBrowserChapters(tocUrl: String, chaptersJson: String, outputDir: String) async throws -> String {
        try await downloadQueue.run {
            try NovelCoreBridge.callDownloadFirstNFromHtml(
                url: tocUrl,
                tocHtml: "",
                chaptersJson: chaptersJson,
                episodes: UInt32.max,
                outputDir: outputDir
            )
        }
    }

    func downloadCached(tocUrl: String, fromChapter chapterID: String?, outputDir: String) async throws -> String {
        try await downloadQueue.run {
            try NovelCoreBridge.callDownloadCachedFromChapter(
                url: tocUrl,
                chapterIndex: chapterID ?? "",
                outputDir: outputDir
            )
        }
    }

    func downloadReaderCached(tocUrl: String, fromChapter chapterID: String?, outputDir: String) async throws -> String {
        try await downloadQueue.run {
            try NovelCoreBridge.callDownloadReaderCachedFromChapter(
                url: tocUrl,
                chapterIndex: chapterID ?? "",
                outputDir: outputDir
            )
        }
    }

    /// Downloads episodes. Rate limiting (5 s/episode) is enforced in Rust.
    func download(tocUrl: String, fromChapter chapterID: String?, outputDir: String) async throws -> String {
        try await downloadQueue.run {
            if let chapterID, !chapterID.isEmpty {
                return try NovelCoreBridge.callDownloadFromChapter(
                    url: tocUrl,
                    chapterIndex: chapterID,
                    outputDir: outputDir
                )
            }
            return try NovelCoreBridge.callDownloadFirstN(
                url: tocUrl,
                episodes: UInt32.max,
                outputDir: outputDir
            )
        }
    }

    func stop() throws {
        try NovelCoreBridge.callCancelDownload()
    }
}

// MARK: - SwiftUI wrappers

private struct ReaderPage: Identifiable {
    let id: Int
    let text: NSAttributedString
}

private final class ReaderDrawPageView: UIView {
    var attributed = NSAttributedString(string: "") { didSet { setNeedsDisplay() } }
    var pageBackground = UIColor.black { didSet { backgroundColor = pageBackground; setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
        backgroundColor = pageBackground
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = true
        isUserInteractionEnabled = false
        backgroundColor = pageBackground
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        pageBackground.setFill()
        ctx.fill(rect)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: bounds, transform: nil)
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(attributed),
            CFRangeMake(0, attributed.length),
            path,
            nil
        )
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}

private struct ReaderPageView: UIViewRepresentable {
    let attributed: NSAttributedString
    let bg: UIColor

    func makeUIView(context: Context) -> ReaderDrawPageView {
        let view = ReaderDrawPageView()
        view.pageBackground = bg
        return view
    }

    func updateUIView(_ uiView: ReaderDrawPageView, context: Context) {
        uiView.pageBackground = bg
        uiView.attributed = attributed
    }
}

struct ReaderPane: View {
    @ObservedObject var state: AppState
    @State private var currentPage = 0
    @State private var cachedSize: CGSize = .zero
    @State private var cachedLength = -1
    @State private var cachedFontSize: CGFloat = 0
    @State private var cachedLineSpacing: CGFloat = 0
    @State private var cachedRenderKey = ""
    @State private var pages: [ReaderPage] = []
    @State private var quickButtonAnchor: CGPoint = CGPoint(x: 196, y: 360)

    var body: some View {
        GeometryReader { proxy in
            let safeAreaInsets = effectiveSafeAreaInsets(proxy.safeAreaInsets)
            ZStack {
                state.bg.ignoresSafeArea()

                if state.readerCanRenderSelectedChapter {
                    readerLayout(in: proxy.size, safeAreaInsets: safeAreaInsets)
                } else {
                    emptyReaderState(in: proxy.size)
                }

                if state.isRenderingChapter {
                    renderingOverlay
                        .transition(.opacity)
                        .zIndex(3)
                }

                if state.readerQuickButtonsVisible {
                    readerQuickButtons
                        .position(quickButtonAnchor)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.08, anchor: .center)
                                .combined(with: .opacity)
                                .combined(with: .offset(y: 18)),
                            removal: .scale(scale: 0.72, anchor: .center)
                                .combined(with: .opacity)
                        ))
                        .zIndex(3)
                }

                if state.readerModalVisible {
                    readerModalDismissLayer
                        .zIndex(4)
                }

                if state.showReaderMenu {
                    ReaderMenuOverlay(state: state)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(5)
                }
                if state.showAppearanceMenu {
                    ReaderAppearanceOverlay(state: state)
                        .transition(.scale.combined(with: .opacity))
                        .zIndex(5)
                }
                if state.showChapterMenu {
                    ReaderChapterOverlay(state: state)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(5)
                }
            }
            .animation(.interpolatingSpring(stiffness: 280, damping: 20), value: state.readerQuickButtonsVisible)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.03), value: state.readerChromeVisible)
            .animation(.easeInOut(duration: 0.18), value: state.showReaderMenu)
            .animation(.easeInOut(duration: 0.18), value: state.showAppearanceMenu)
            .animation(.easeInOut(duration: 0.18), value: state.showChapterMenu)
        }
        .background(state.bg)
        .ignoresSafeArea(state.readerFullscreen ? .all : [], edges: .all)
        .toolbar(state.readerFullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(state.readerFullscreen ? .hidden : .visible, for: .tabBar)
    }


    private var readerModalDismissLayer: some View {
        Color.black.opacity(state.showAppearanceMenu || state.showChapterMenu ? 0.18 : 0.001)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { state.hideReaderChromeAndMenus() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in state.hideReaderChromeAndMenus() }
            )
            .accessibilityLabel("リーダーメニューを閉じる")
    }


    private var readerIsWaitingForDownload: Bool {
        state.readerPendingTocUrl != nil || state.selectedNovel != nil || state.isDownloading
    }

    private var emptyReaderTitle: String {
        readerIsWaitingForDownload ? "本文を準備中" : "話を選択してください"
    }

    private var emptyReaderDescription: String {
        readerIsWaitingForDownload
            ? "目次または本文を取得しています。ダウンロードが進むと表示されます。"
            : "本棚から読む話を選んでください"
    }

    private func emptyReaderState(in size: CGSize) -> some View {
        VStack(spacing: 14) {
            Image(systemName: readerIsWaitingForDownload ? "arrow.down.circle" : "text.book.closed")
                .font(.system(size: 34, weight: .light))
            Text(emptyReaderTitle)
                .font(.headline)
            Text(emptyReaderDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if readerIsWaitingForDownload {
                ProgressView(value: Double(state.progress.completedCount), total: Double(max(state.progress.total, 1)))
                    .tint(state.progress.hasFailures ? .orange : .blue)
                    .frame(width: 190)
                Text(state.downloadStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if state.isDownloading || state.isAddingTocToShelf {
                    Button(role: .destructive) { state.cancelActiveReaderWork() } label: {
                        Label("停止", systemImage: "stop.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .foregroundStyle(state.fg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(readerQuickButtonSwipe(in: size))
        .onTapGesture { state.toggleReaderChrome() }
    }

    private var pageEdgeDrag: some Gesture {
        DragGesture(minimumDistance: 32)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height), abs(value.translation.width) > 70 else { return }
                clampCurrentPage()
                if value.translation.width < 0, currentPage >= max(displayedPageCount - 1, 0) {
                    if state.selectNextChapter() { currentPage = 0 }
                } else if value.translation.width > 0, currentPage == 0 {
                    if state.selectPreviousChapter() { currentPage = max(displayedPageCount - 1, 0) }
                }
            }
    }

    private func readerQuickButtonSwipe(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard value.translation.height < -42, abs(value.translation.height) > abs(value.translation.width) else { return }
                quickButtonAnchor = CGPoint(
                    x: min(max(value.startLocation.x, 116), max(size.width - 116, 116)),
                    y: min(max(value.startLocation.y - 18, 160), max(size.height - 160, 160))
                )
                state.revealReaderQuickButtons()
            }
    }


    private var renderingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(readerChromePrimaryColor)
            Text("本文を整形中…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(readerChromePrimaryColor)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(readerChromeBackgroundColor.opacity(0.86), in: Capsule())
        .allowsHitTesting(false)
    }

    private var readerQuickButtons: some View {
        HStack(spacing: 44) {
            readerQuickButton(icon: "arrow.left", delay: 0, hiddenOffset: -96) { state.closeCurrent() }
            readerQuickButton(icon: "list.bullet", delay: 0.055, hiddenOffset: 96) {
                state.showChapterMenu = true
                state.readerQuickButtonsVisible = false
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(.black.opacity(0.001))
    }

    private func readerQuickButton(icon: String, delay: Double, hiddenOffset: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 74, height: 74)
                .symbolRenderingMode(.hierarchical)
        }
        .font(.system(size: 42, weight: .ultraLight))
        .foregroundStyle(.white.opacity(0.74))
        .background(.black.opacity(0.18), in: Circle())
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 6)
        .rotationEffect(state.readerQuickButtonsVisible ? .degrees(0) : .degrees(-720))
        .scaleEffect(state.readerQuickButtonsVisible ? 1 : 0.06)
        .offset(y: state.readerQuickButtonsVisible ? 0 : hiddenOffset)
        .opacity(state.readerQuickButtonsVisible ? 1 : 0)
        .animation(.interpolatingSpring(stiffness: 230, damping: 14).delay(delay), value: state.readerQuickButtonsVisible)
    }

    private func effectiveSafeAreaInsets(_ proxyInsets: EdgeInsets) -> EdgeInsets {
        let windowInsets = Self.currentWindowSafeAreaInsets
        return EdgeInsets(
            top: max(proxyInsets.top, windowInsets.top),
            leading: max(proxyInsets.leading, windowInsets.left),
            bottom: max(proxyInsets.bottom, windowInsets.bottom),
            trailing: max(proxyInsets.trailing, windowInsets.right)
        )
    }

    private static var currentWindowSafeAreaInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return window?.safeAreaInsets ?? .zero
    }

    private func readerLayout(in size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        ZStack {
            GeometryReader { contentProxy in
                readerPagedContent(in: contentProxy.size, safeAreaInsets: safeAreaInsets)
            }

            if state.readerChromeVisible {
                VStack(spacing: 0) {
                    readerTopChrome(availableWidth: size.width, safeAreaTop: safeAreaInsets.top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer(minLength: 0)
                    readerBottomChrome(availableWidth: size.width, safeAreaBottom: safeAreaInsets.bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(2)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    if value.translation.height < -44 {
                        state.hideReaderChromeAndMenus()
                    } else if value.translation.height > 54 {
                        state.readerChromeVisible = true
                    }
                }
        )
    }

    private func readerPagedContent(in size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        let pageSafeInsets = pageSafeAreaInsets(safeAreaInsets)
        let pageSize = pageContentSize(size, safeAreaInsets: pageSafeInsets)
        return TabView(selection: pageSelectionBinding) {
            ForEach(displayedPages) { page in
                ReaderPageView(attributed: page.text, bg: UIColor(state.bg))
                    .frame(width: pageSize.width, height: pageSize.height)
                    .padding(.horizontal, state.readerMargin)
                    .padding(.top, readerVerticalInset + pageSafeInsets.top)
                    .padding(.bottom, readerVerticalInset + pageSafeInsets.bottom)
                    .tag(page.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .environment(\.layoutDirection, state.rtl ? .rightToLeft : .leftToRight)
        .simultaneousGesture(pageEdgeDrag)
        .simultaneousGesture(readerQuickButtonSwipe(in: size))
        .onTapGesture { state.toggleReaderChrome() }
        .overlay(alignment: .bottom) { compactReadingProgress }
        .onAppear {
            currentPage = state.savedPageForSelectedChapter()
            rebuildPagesIfNeeded(pageSize: pageSize, force: true)
        }
        .onChange(of: size) { _, newSize in
            rebuildPagesIfNeeded(pageSize: pageContentSize(newSize, safeAreaInsets: pageSafeInsets), force: true)
        }
        .onChange(of: state.attributed) { _, _ in
            currentPage = state.savedPageForSelectedChapter()
            rebuildPagesIfNeeded(pageSize: pageSize, force: true)
        }
        .onChange(of: state.selected?.id) { _, _ in
            currentPage = state.savedPageForSelectedChapter()
            rebuildPagesIfNeeded(pageSize: pageSize, force: true)
        }
        .onChange(of: currentPage) { _, page in
            state.recordReaderPage(page)
        }
        .onChange(of: state.readerMargin) { _, _ in rebuildPagesIfNeeded(pageSize: pageSize, force: true) }
        .onChange(of: state.rtl) { _, _ in clampCurrentPage() }
        .onChange(of: displayedPageCount) { _, _ in clampCurrentPage() }
    }

    private func readerTopChrome(availableWidth: CGFloat, safeAreaTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    readerChromeButton("arrow.left") { state.closeCurrent() }
                    readerChromeButton("list.bullet") { state.showChapterMenu = true }
                    readerChromeButton(state.isBookmarked(state.selected) ? "bookmark.fill" : "bookmark") { state.toggleBookmarkForSelectedChapter() }
                    Spacer(minLength: 8)
                    readerChromeButton("textformat.size") { state.showAppearanceMenu = true }
                    readerChromeButton("magnifyingglass") { state.showChapterMenu = true }
                    readerChromeButton("sun.max") { state.toggleReaderTheme() }
                }

                LazyVGrid(columns: readerChromeColumns(count: 6), spacing: 4) {
                    readerChromeButton("arrow.left") { state.closeCurrent() }
                    readerChromeButton("list.bullet") { state.showChapterMenu = true }
                    readerChromeButton(state.isBookmarked(state.selected) ? "bookmark.fill" : "bookmark") { state.toggleBookmarkForSelectedChapter() }
                    readerChromeButton("textformat.size") { state.showAppearanceMenu = true }
                    readerChromeButton("magnifyingglass") { state.showChapterMenu = true }
                    readerChromeButton("sun.max") { state.toggleReaderTheme() }
                }
            }
            .foregroundStyle(readerChromePrimaryColor)
            .padding(.horizontal, max(8, min(18, availableWidth * 0.04)))
            .padding(.top, max(8, safeAreaTop + 8))
            .padding(.bottom, 2)

            Text(state.selected?.subtitle ?? "")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(readerChromeSecondaryColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider().overlay(readerChromeDividerColor)
        }
        .background(readerChromeBackgroundColor)
    }

    private func readerBottomChrome(availableWidth: CGFloat, safeAreaBottom: CGFloat) -> some View {
        VStack(spacing: 8) {
            Divider().overlay(readerChromeDividerColor)
            Text("ページ \(clampedCurrentPage + 1)/\(displayedPageCount) - 第\(state.currentChapterOrdinalText) ・ \(readingStatsText)")
                .font(.footnote)
                .foregroundStyle(readerChromeSecondaryColor)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    bottomChromeButtonsLeading
                    pageSlider
                        .frame(minWidth: 96)
                        .layoutPriority(1)
                    bottomChromeButtonsTrailing
                }

                VStack(spacing: 8) {
                    pageSlider
                    HStack(spacing: 0) {
                        readerChromeButton("arrow.up.left.and.arrow.down.right") { state.readerFullscreen.toggle() }
                        Spacer(minLength: 0)
                        readerChromeButton("backward") { goPreviousPageOrChapter() }
                        Spacer(minLength: 0)
                        readerChromeButton("play") { goNextPageOrChapter() }
                        Spacer(minLength: 0)
                        readerChromeButton("square.and.arrow.up") { state.toggleBookmarkForSelectedChapter() }
                    }
                }
            }
            .foregroundStyle(readerChromePrimaryColor)
        }
        .padding(.horizontal, max(8, min(16, availableWidth * 0.04)))
        .padding(.top, 8)
        .padding(.bottom, max(8, safeAreaBottom + 8))
        .background(readerChromeBackgroundColor)
    }

    private func goNextPageOrChapter() {
        clampCurrentPage()
        if currentPage < displayedPageCount - 1 {
            currentPage += 1
        } else if state.selectNextChapter() {
            currentPage = 0
        }
    }

    private func goPreviousPageOrChapter() {
        clampCurrentPage()
        if currentPage > 0 {
            currentPage -= 1
        } else if state.selectPreviousChapter() {
            currentPage = max(displayedPageCount - 1, 0)
        }
    }

    private func clampCurrentPage() {
        currentPage = clampedCurrentPage
    }

    private var readerChromeBackgroundColor: Color {
        state.readerDarkTheme ? .black.opacity(0.92) : .white.opacity(0.96)
    }

    private var readerChromePrimaryColor: Color {
        state.readerDarkTheme ? .white.opacity(0.68) : .black.opacity(0.62)
    }

    private var readerChromeSecondaryColor: Color {
        state.readerDarkTheme ? .white.opacity(0.52) : .black.opacity(0.70)
    }

    private var readerChromeDividerColor: Color {
        state.readerDarkTheme ? .white.opacity(0.18) : .black.opacity(0.14)
    }

    private var readerVerticalInset: CGFloat { 18 }

    private var compactReadingProgress: some View {
        VStack(spacing: 4) {
            ProgressView(value: Double(clampedCurrentPage + 1), total: Double(displayedPageCount))
                .progressViewStyle(.linear)
                .tint(readerChromePrimaryColor.opacity(0.58))
                .frame(maxWidth: 180)
            Text(readingStatsText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(readerChromeSecondaryColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(readerChromeBackgroundColor.opacity(state.readerChromeVisible ? 0 : 0.56), in: Capsule())
        .opacity(state.readerChromeVisible ? 0 : 1)
        .padding(.bottom, 10)
        .allowsHitTesting(false)
        .accessibilityHidden(state.readerChromeVisible)
    }

    private var readingStatsText: String {
        let totalCharacters = state.renderedCharacterCount
        guard totalCharacters > 0 else { return "0%" }
        let progress = Double(clampedCurrentPage + 1) / Double(displayedPageCount)
        let remainingCharacters = max(0, Int(Double(totalCharacters) * (1.0 - progress)))
        let remainingMinutes = remainingCharacters == 0 ? 0 : max(1, Int(ceil(Double(remainingCharacters) / 450.0)))
        return "\(Int((progress * 100).rounded()))%・残り約\(remainingMinutes)分・\(totalCharacters)字"
    }

    private var displayedPages: [ReaderPage] {
        let source = pages.isEmpty && state.attributed.length > 0
            ? [ReaderPage(id: 0, text: state.attributed)]
            : pages
        return source.isEmpty ? [ReaderPage(id: 0, text: NSAttributedString(string: ""))] : source
    }

    private var displayedPageCount: Int { max(displayedPages.count, 1) }

    private var clampedCurrentPage: Int {
        min(max(currentPage, 0), max(displayedPageCount - 1, 0))
    }

    private var pageSelectionBinding: Binding<Int> {
        Binding(
            get: { clampedCurrentPage },
            set: { currentPage = min(max($0, 0), max(displayedPageCount - 1, 0)) }
        )
    }

    @ViewBuilder
    private var pageSlider: some View {
        if displayedPageCount > 1 {
            Slider(
                value: Binding(
                    get: { Double(clampedCurrentPage) },
                    set: { currentPage = min(max(Int($0.rounded()), 0), max(displayedPageCount - 1, 0)) }
                ),
                in: 0...Double(displayedPageCount - 1),
                step: 1
            )
        } else {
            ProgressView(value: 1, total: 1)
                .progressViewStyle(.linear)
                .opacity(0.35)
                .accessibilityLabel("1ページ")
        }
    }

    private var bottomChromeButtonsLeading: some View {
        HStack(spacing: 4) {
            readerChromeButton("arrow.up.left.and.arrow.down.right") { state.readerFullscreen.toggle() }
            readerChromeButton("backward") { goPreviousPageOrChapter() }
        }
    }

    private var bottomChromeButtonsTrailing: some View {
        HStack(spacing: 4) {
            readerChromeButton("play") { goNextPageOrChapter() }
            readerChromeButton("square.and.arrow.up") { state.toggleBookmarkForSelectedChapter() }
        }
    }

    private func readerChromeColumns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 32, maximum: .infinity), spacing: 4), count: count)
    }

    private func readerChromeButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .frame(minWidth: 34, idealWidth: 40, maxWidth: 44, minHeight: 34, idealHeight: 40, maxHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(iconAccessibilityLabel(icon)))
    }

    private func iconAccessibilityLabel(_ icon: String) -> String {
        switch icon {
        case "arrow.left": return "リーダーを閉じる"
        case "list.bullet": return "目次を開く"
        case "bookmark", "bookmark.fill", "square.and.arrow.up": return "しおりを切り替える"
        case "textformat.size": return "表示設定を開く"
        case "magnifyingglass": return "話を検索する"
        case "sun.max": return "テーマを切り替える"
        case "arrow.up.left.and.arrow.down.right": return "全画面を切り替える"
        case "backward": return "前のページ"
        case "play": return "次のページ"
        default: return "操作"
        }
    }


    private func pageContentSize(_ size: CGSize, safeAreaInsets: EdgeInsets = EdgeInsets()) -> CGSize {
        CGSize(
            width: max(size.width - state.readerMargin * 2, 80),
            height: max(size.height - readerVerticalInset * 2 - safeAreaInsets.top - safeAreaInsets.bottom, 120)
        )
    }

    private func pageSafeAreaInsets(_ safeAreaInsets: EdgeInsets) -> EdgeInsets {
        guard state.readerFullscreen else { return EdgeInsets() }
        return EdgeInsets(
            top: max(0, safeAreaInsets.top + 6),
            leading: 0,
            bottom: max(0, safeAreaInsets.bottom + 8),
            trailing: 0
        )
    }

    private func rebuildPagesIfNeeded(pageSize: CGSize, force: Bool = false) {
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        let renderKey = [
            state.selected?.id ?? "",
            String(state.attributed.length),
            String(format: "%.2f", state.fontSize),
            String(format: "%.2f", state.lineSpacing),
            String(format: "%.2f", state.readerMargin),
            state.readerFontName,
            state.showImages ? "images" : "text",
            state.rtl ? "rtl" : "ltr"
        ].joined(separator: "|")
        let needs = force || cachedSize != pageSize || cachedLength != state.attributed.length || cachedFontSize != state.fontSize || cachedLineSpacing != state.lineSpacing || cachedRenderKey != renderKey
        guard needs else { return }
        cachedSize = pageSize
        cachedLength = state.attributed.length
        cachedFontSize = state.fontSize
        cachedLineSpacing = state.lineSpacing
        cachedRenderKey = renderKey
        let newPages = paginate(state.attributed, pageSize: pageSize)
        currentPage = min(max(currentPage, 0), max(newPages.count - 1, 0))
        pages = newPages
    }

    private func paginate(_ attr: NSAttributedString, pageSize: CGSize) -> [ReaderPage] {
        guard attr.length > 0 else { return [ReaderPage(id: 0, text: NSAttributedString(string: ""))] }
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
        var result: [ReaderPage] = []
        var location = 0
        while location < attr.length {
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(location, attr.length - location), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            let length = max(visible.length, 1)
            let range = NSRange(location: location, length: min(length, attr.length - location))
            result.append(ReaderPage(id: result.count, text: attr.attributedSubstring(from: range)))
            location += range.length
        }
        return result.isEmpty ? [ReaderPage(id: 0, text: NSAttributedString(string: ""))] : result
    }
}

private struct ReaderMenuOverlay: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(.secondary).frame(width: 52, height: 6).padding(.top, 8)
            Text(state.selectedNovel?.displayTitle ?? "小説")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.vertical, 18)
            Button("小説一覧に戻る") { state.closeCurrent() }
                .font(.headline)
                .padding(.bottom, 12)
            Button("閉じる") { state.showReaderMenu = false }
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }
}

private struct ReaderChapterOverlay: View {
    @ObservedObject var state: AppState
    @State private var chapterQuery = ""

    private var selectedID: String? { state.selected?.id }

    private var visibleChapters: [ChapterCard] {
        let trimmed = chapterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return state.chapters }
        return state.chapters.filter { chapter in
            chapter.subtitle.localizedCaseInsensitiveContains(trimmed) || chapter.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let safeInsets = effectiveSafeAreaInsets(proxy.safeAreaInsets)
            let horizontalPadding = max(10, min(18, proxy.size.width * 0.04))
            let topPadding = safeInsets.top + 10
            let bottomPadding = safeInsets.bottom + 12
            let availableSheetHeight = max(180, proxy.size.height - topPadding - bottomPadding)
            let preferredSheetHeight = max(320, proxy.size.height * 0.78)

            VStack(spacing: 0) {
                Capsule()
                    .fill(.secondary.opacity(0.55))
                    .frame(width: 46, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                chapterHeader

                chapterSearchField

                if !state.textExportStatus.isEmpty {
                    Text(state.textExportStatus)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                Divider().opacity(0.32)

                chapterList
            }
            .frame(maxWidth: .infinity)
            .frame(height: min(preferredSheetHeight, availableSheetHeight))
            .background(.ultraThinMaterial)
            .background(Color.black.opacity(0.90))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var chapterHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.selectedNovel?.displayTitle ?? "小説")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("全\(state.chapters.count)話 ・ \(state.currentChapterOrdinalText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { state.downloadAllChaptersForSelectedNovel() } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.secondary.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("全話ダウンロード")
            Button { state.exportTextZipForSelectedNovel() } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.secondary.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(state.isExportingTextZip)
            .accessibilityLabel("TXT ZIP書き出し")
            Button { state.showChapterMenu = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.secondary.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("話一覧を閉じる")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var chapterSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.55))
            TextField("話タイトル・番号を絞り込み / Returnで本文検索", text: $chapterQuery)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { runFullTextSearch() }
            Button { runFullTextSearch() } label: {
                Image(systemName: "text.magnifyingglass")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("本文検索")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var chapterList: some View {
        ScrollViewReader { scrollProxy in
            List(visibleChapters) { chapter in
                ReaderChapterRow(
                    chapter: chapter,
                    isSelected: selectedID == chapter.id,
                    isBookmarked: state.isBookmarked(chapter)
                ) {
                    state.selectChapter(chapter)
                    state.showChapterMenu = false
                }
                .id(chapter.id)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onAppear { scrollToSelected(with: scrollProxy) }
            .onChange(of: selectedID) { _, _ in scrollToSelected(with: scrollProxy) }
        }
    }

    private func scrollToSelected(with proxy: ScrollViewProxy) {
        guard let selectedID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.20)) {
                proxy.scrollTo(selectedID, anchor: .center)
            }
        }
    }

    private func runFullTextSearch() {
        state.query = chapterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        state.runSearch()
    }

    private func effectiveSafeAreaInsets(_ proxyInsets: EdgeInsets) -> EdgeInsets {
        let windowInsets = Self.currentWindowSafeAreaInsets
        return EdgeInsets(
            top: max(proxyInsets.top, windowInsets.top),
            leading: max(proxyInsets.leading, windowInsets.left),
            bottom: max(proxyInsets.bottom, windowInsets.bottom),
            trailing: max(proxyInsets.trailing, windowInsets.right)
        )
    }

    private static var currentWindowSafeAreaInsets: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        return window?.safeAreaInsets ?? .zero
    }
}

private struct ReaderChapterRow: View {
    let chapter: ChapterCard
    let isSelected: Bool
    let isBookmarked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.subtitle.isEmpty ? "無題" : chapter.subtitle)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .lineLimit(2)
                        .foregroundStyle(isSelected ? .blue : .white.opacity(0.92))
                    Text("#\(chapter.id)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                if isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("しおり")
                }
                if chapter.hasDownloadedBody {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green.opacity(0.85))
                        .accessibilityLabel("ダウンロード済み")
                } else {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundStyle(.white.opacity(0.55))
                        .accessibilityLabel("未ダウンロード")
                }
                if isSelected {
                    Image(systemName: "largecircle.fill.circle")
                        .foregroundStyle(.blue)
                        .accessibilityLabel("選択中")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var rowBackground: Color {
        isSelected ? Color.blue.opacity(0.16) : Color.white.opacity(0.055)
    }
}


private struct ReaderAppearanceOverlay: View {
    @ObservedObject var state: AppState
    private let palettes: [(name: String, bg: Color, fg: Color)] = [
        ("夜", .black, Color(red: 0.86, green: 0.86, blue: 0.86)),
        ("藍", Color(red: 0.08, green: 0.09, blue: 0.12), Color(red: 0.90, green: 0.93, blue: 0.98)),
        ("紙", Color(red: 0.94, green: 0.90, blue: 0.82), .black),
        ("緑", Color(red: 0.72, green: 0.77, blue: 0.66), .black),
        ("灰", Color(red: 0.33, green: 0.39, blue: 0.42), Color(red: 0.90, green: 0.93, blue: 0.98))
    ]

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.42))
                .frame(width: 46, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 12)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("表示設定")
                        .font(.headline.weight(.semibold))
                    Text("大きな章でも固まらないよう変更は少し待ってから反映します")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(2)
                }
                Spacer()
                Button { state.showAppearanceMenu = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("表示設定を閉じる")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    settingsCard(title: "文字") {
                        sliderRow("サイズ", value: $state.fontSize, range: 12...38, suffix: "pt")
                        sliderRow("行間", value: $state.lineSpacing, range: 0...28, suffix: "")
                        sliderRow("余白", value: $state.readerMargin, range: 16...56, suffix: "pt")
                    }

                    settingsCard(title: "色と明るさ") {
                        paletteRow
                        HStack(spacing: 10) {
                            Image(systemName: "sun.min")
                            Slider(value: Binding(
                                get: { state.readerBrightness },
                                set: { state.readerBrightness = $0; state.commitReaderAppearanceChange() }
                            ), in: 0.45...1.0)
                            Image(systemName: "sun.max")
                            Text("\(Int(state.readerBrightness * 100))%")
                                .font(.caption.monospacedDigit())
                                .frame(width: 42, alignment: .trailing)
                        }
                    }

                    settingsCard(title: "読み方") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            pillButton("フォント", value: state.readerFontLabel) {
                                state.cycleReaderFont()
                                state.commitReaderAppearanceChange(debounce: false)
                            }
                            pillButton("ページ", value: state.rtl ? "右→左" : "左→右") {
                                state.rtl.toggle()
                                state.commitReaderAppearanceChange(debounce: false)
                            }
                            pillButton("画像", value: state.showImages ? "表示" : "非表示") {
                                state.showImages.toggle()
                                state.commitReaderAppearanceChange(debounce: false)
                            }
                            pillButton("画面", value: state.readerFullscreen ? "全画面" : "通常") {
                                state.readerFullscreen.toggle()
                                state.commitReaderAppearanceChange(rebuild: false, debounce: false)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
            .frame(maxHeight: 430)
        }
        .foregroundStyle(.white.opacity(0.94))
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.38), radius: 24, x: 0, y: 16)
        .padding(.horizontal, 14)
    }

    private var paletteRow: some View {
        HStack(spacing: 12) {
            ForEach(Array(palettes.enumerated()), id: \.offset) { index, palette in
                Button {
                    state.bg = palette.bg
                    state.fg = palette.fg
                    state.readerDarkTheme = index < 2
                    state.commitReaderAppearanceChange(debounce: false)
                } label: {
                    VStack(spacing: 5) {
                        Circle()
                            .fill(palette.bg)
                            .frame(width: 38, height: 38)
                            .overlay(Circle().stroke(palette.fg.opacity(0.9), lineWidth: 2))
                            .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
                        Text(palette.name)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.68))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.58))
                .textCase(.uppercase)
            content()
        }
        .padding(14)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func sliderRow(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, suffix: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = $0; state.commitReaderAppearanceChange() }
            ), in: range)
            Text("\(Int(value.wrappedValue))\(suffix)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func pillButton(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.58))
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct ReaderSettingsPane: View {
    @ObservedObject var state: AppState
    var body: some View {
        NavigationStack {
            Form {
                Section("表示") {
                    Toggle("画像表示", isOn: $state.showImages)
                    Toggle("ページ送りを右→左", isOn: $state.rtl)
                    Toggle("フルスクリーン", isOn: $state.readerFullscreen)
                    Toggle("ヘッダー/フッター表示", isOn: $state.readerChromeVisible)
                }
                Section("文字") {
                    HStack {
                        Text("サイズ")
                        Slider(value: $state.fontSize, in: 12...38)
                        Text("\(Int(state.fontSize))").monospacedDigit()
                    }
                    HStack {
                        Text("行間")
                        Slider(value: $state.lineSpacing, in: 0...28)
                        Text("\(Int(state.lineSpacing))").monospacedDigit()
                    }
                    HStack {
                        Text("余白")
                        Slider(value: $state.readerMargin, in: 16...56)
                        Text("\(Int(state.readerMargin))").monospacedDigit()
                    }
                }
                Section("色") {
                    ColorPicker("背景", selection: $state.bg)
                    ColorPicker("文字", selection: $state.fg)
                }
            }
            .onChange(of: state.showImages)   { _, _ in state.commitReaderAppearanceChange() }
            .onChange(of: state.rtl)          { _, _ in state.commitReaderAppearanceChange() }
            .onChange(of: state.fontSize)     { _, _ in state.commitReaderAppearanceChange() }
            .onChange(of: state.lineSpacing)  { _, _ in state.commitReaderAppearanceChange() }
            .onChange(of: state.bg)           { _, _ in state.commitReaderAppearanceChange() }
            .onChange(of: state.fg)           { _, _ in state.commitReaderAppearanceChange() }
            .onChange(of: state.readerBrightness) { _, _ in state.commitReaderAppearanceChange() }
            .onChange(of: state.readerMargin) { _, _ in state.commitReaderAppearanceChange() }
            .onChange(of: state.readerFullscreen) { _, _ in state.commitReaderAppearanceChange(rebuild: false) }
            .onChange(of: state.readerChromeVisible) { _, _ in state.commitReaderAppearanceChange(rebuild: false) }
            .navigationTitle("リーダー設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { state.showReaderSettings = false }
                }
            }
        }
    }
}
