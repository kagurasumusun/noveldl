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
    let tocUrl: String

    @State private var chapterIndex: String
    @State private var chapterTitle = ""
    @State private var chapterLabel = ""
    @State private var chapterProgress: Double = 0
    @State private var attributed = NSAttributedString()
    @State private var imageRefs: [ImageRef] = []
    @State private var loadError: String?
    @State private var detail: LibraryNovelDetail?
    @State private var bookmarked = false
    @State private var hintVisible = false
    @State private var autoFetching = false

    @AppStorage("readerTheme") private var themeRaw = BookTheme.paper.rawValue
    @AppStorage("readerFontSize") private var fontSize = 19.0
    @AppStorage("readerLineSpacing") private var lineSpacing = 8.0
    @AppStorage("readerMargin") private var margin = 12.0
    @AppStorage("readerFontDesign") private var fontDesign = "serif"
    @AppStorage("readerSwipePaging") private var swipePaging = true
    @AppStorage("readerPageTurn") private var pageTurnRaw = PageTurn.curl.rawValue
    @AppStorage("readerShowRuby") private var showRuby = true
    @AppStorage("readerShowHeader") private var showHeader = true
    @AppStorage("readerShowFooter") private var showFooter = true
    /// 前書き/後書きの表示(既定 OFF — 余分なものは opt-in)。
    @AppStorage("readerShowIntroPost") private var showIntroPost = false
    /// 章タイトルの見出し表示。
    @AppStorage("readerShowChapterTitle") private var showChapterTitle = true

    @State private var chromeVisible = true
    @State private var lastHTML = ""
    @State private var readerBox = ScrollBox()

    /// 組み立て元の断片(トグル変更時に rebuild で再合成する)。
    @State private var lastIntro = ""
    @State private var lastPost = ""
    @State private var lastSubTitle = ""
    /// フッターの頁カウンタ。
    @State private var currentPage = 0
    @State private var pageCount = 1
    /// 目次シートの段階読み込み位置。
    @State private var tocLimit = 150

    /// 目次/メニューは 1 つの sheet(item:) で出し分ける。
    /// 同じビューに .sheet(isPresented:) を 2 つ付けると環境によって
    /// 片方しか提示されない(目次メニューが出ない原因)。
    private enum ReaderSheet: Int, Identifiable {
        case toc, menu
        var id: Int { rawValue }
    }
    @State private var sheet: ReaderSheet?

    private var theme: BookTheme { BookTheme(rawValue: themeRaw) ?? .paper }
    private var turn: PageTurn { PageTurn(rawValue: pageTurnRaw) ?? .curl }
    private var chapters: [ChapterMeta] { detail?.chapters ?? [] }
    private var total: Int { max(chapters.count, 1) }
    private var pos: Int { chapters.firstIndex { $0.index == chapterIndex } ?? 0 }
    private var canGoPrev: Bool { pos > 0 }
    private var canGoNext: Bool { pos + 1 < chapters.count }

    init(novelId: String, startAt: String, title: String, tocUrl: String) {
        self.novelId = novelId
        self.startAt = startAt
        self.title = title
        self.tocUrl = tocUrl
        _chapterIndex = State(initialValue: startAt)
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            GeometryReader { geo in
                ReaderTextView(
                    attributed: attributed,
                    theme: theme,
                    box: readerBox,
                    pageSize: geo.size,
                    turn: turn,
                    sideMargin: max(margin, 12),
                    swipePaging: swipePaging,
                    onCenterTap: {
                        withAnimation(.easeInOut(duration: 0.22)) { chromeVisible.toggle() }
                    },
                    onTurn: {
                        // スワイプ/めくりで自動的に隠れる
                        if chromeVisible {
                            withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
                        }
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
            }
            // 表示サイズは GeometryReader の確定値で固定する。UITextView に
            // 自己サイズリングさせると画面より大きくなり、左右が切れて
            // 行間も吹んで見えていた(スクリーンショットで確認済みの症状)。
            .ignoresSafeArea()
            .id(chapterIndex)

            VStack {
                if chromeVisible && showHeader {
                    topBar
                        .transition(.opacity)
                }
                Spacer()
                if autoFetching {
                    fetchPill
                        .transition(.opacity)
                }
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
        .task(id: chapterIndex) {
            await load()
            // 話移動の直後に一度だけ表示。消しタイマーは持たない(手動出没のみ)。
            withAnimation(.easeOut(duration: 0.3)) { chromeVisible = true }
        }
        .sheet(item: $sheet) { target in
            switch target {
            case .toc: tocSheet
            case .menu: menuSheet
            }
        }
        .onAppear {
            // 読書中は画面を自動ロックさせない(読書アプリの基本動作)。
            UIApplication.shared.isIdleTimerDisabled = true
            // 頁カウンタの更新はボックスからの通知で受ける。
            readerBox.onPage = { idx, cnt in
                currentPage = idx
                pageCount = cnt
            }
            if !UserDefaults.standard.bool(forKey: "readerHintShown") {
                hintVisible = true
                UserDefaults.standard.set(true, forKey: "readerHintShown")
                Task {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation(.easeOut(duration: 0.4)) { hintVisible = false }
                }
            }
        }
        .onDisappear {
            // 離脱時に自動ロックを戻す(つけっぱなしを避ける)。
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: 上下バー(中央タップで出没)

    private var topBar: some View {
        HStack(spacing: Spacing.s) {
            chromeButton("list.bullet", "一覧") { sheet = .toc }
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
            chromeButton("gearshape", "設定") { sheet = .menu }
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
                Text(pageCount > 1 ? "\(currentPage + 1)/\(pageCount)頁" : " ")
                    .font(AppFont.ui(9, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.ink.opacity(0.6))
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
            // ボタン操作でもバーは自動で引っ込む
            if chromeVisible {
                withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
            }
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
        Text("左右スワイプか左右タップで送り・中央タップでバー")
            .font(AppFont.ui(12, weight: .medium))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(Capsule().fill(theme.background))
            .overlay(Capsule().strokeBorder(theme.ink.opacity(0.15), lineWidth: 1))
    }

    /// 未取得の話を開いたときの自動取得インジケータ。
    /// 別の取得(全話)が走っているときはその旨を出し分ける。
    private var fetchPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text(core.progress.running ? "他の取得の完了を待っています…" : "この話を自動取得中…")
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(theme.ink)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(Capsule().fill(theme.background.opacity(0.97)))
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

                menuSectionHeader("表示", "DISPLAY")
                VStack(spacing: 0) {
                    HStack(spacing: Spacing.s) {
                        ForEach(BookTheme.allCases, id: \.self) { t in
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

                menuSectionHeader("表示項目", "ITEMS")
                VStack(spacing: 0) {
                    toggleRow("ルビ(振り仮名)", showRuby) { showRuby.toggle(); applyStyle() }
                    RowDivider()
                    toggleRow("章タイトル", showChapterTitle) { showChapterTitle.toggle(); applyStyle() }
                    RowDivider()
                    toggleRow("前書き・後書き", showIntroPost) { showIntroPost.toggle(); applyStyle() }
                    RowDivider()
                    toggleRow("ヘッダー(タイトル)", showHeader) { showHeader.toggle() }
                    RowDivider()
                    toggleRow("フッター(進捗)", showFooter) { showFooter.toggle() }
                }
                .padding(Spacing.m)
                .background(PaperBackground())

                menuSectionHeader("送り", "PAGING")
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

                menuSectionHeader("移動", "GO")
                HStack(spacing: Spacing.s) {
                    QuietButton(title: "目次", systemImage: "list.bullet") {
                        sheet = .toc
                    }
                    QuietButton(title: "前の話", systemImage: "chevron.left", disabled: !canGoPrev) {
                        sheet = nil
                        goChapter(delta: -1)
                    }
                    QuietButton(title: "次の話", systemImage: "chevron.right", disabled: !canGoNext) {
                        sheet = nil
                        goChapter(delta: 1)
                    }
                }
                QuietButton(title: "閉じて作品詳細へ", systemImage: "xmark") {
                    sheet = nil
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
        // 長編(数百〜千話)で全行を一気に構築するとシートが開くまで
        // 数秒固まるため、150話ずつ段階的に読み込む。
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("目次")
                    .font(AppFont.serif(20, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                    .padding(Spacing.l)
                ForEach(Array((detail?.chapters ?? []).prefix(tocLimit).enumerated()), id: \.element.index) { _, ch in
                    Button {
                        sheet = nil
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
                if let total = detail?.chapters.count, total > tocLimit {
                    HStack(spacing: Spacing.s) {
                        ProgressView().scaleEffect(0.7)
                        Text("残り \(total - tocLimit) 話…")
                            .font(AppFont.ui(11))
                            .foregroundStyle(AppPalette.inkFaint)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 60_000_000)
                            if tocLimit < total {
                                tocLimit += 150
                            }
                        }
                    }
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

    private func menuSectionHeader(_ title: String, _ en: String) -> some View {
        HStack(spacing: Spacing.s) {
            Text(en)
                .font(AppFont.ui(11.5, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .tracking(2)
            Text(title)
                .font(AppFont.ui(9.5))
                .foregroundStyle(AppPalette.inkFaint)
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
        let urlText = (tocUrl.isEmpty ? nil : tocUrl).map { "\($0) (\(title) \(chapterLabel))" } ?? title
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
        rebuild()
    }

    /// 見出し/前書き/本文/後書きを組み立てて表示テキストを作る。
    /// 挿絵のレンジは結合後のテキスト位置へ補正する。
    private func rebuild() {
        guard !lastHTML.isEmpty else { return }
        let style = currentStyle()
        let combined = NSMutableAttributedString()
        var refs: [ImageRef] = []
        if showChapterTitle {
            combined.append(ReaderMarkup.chapterHeading(title: lastSubTitle, style: style))
        }
        if showIntroPost, !lastIntro.isEmpty {
            let r = markup.parse(lastIntro, style: style)
            for im in r.images {
                refs.append(ImageRef(
                    range: NSRange(location: im.range.location + combined.length, length: im.range.length),
                    src: im.src))
            }
            combined.append(r.text)
            combined.append(ReaderMarkup.dividerBlock(style: style))
        }
        let bodyBase = combined.length
        let body = markup.parse(lastHTML, style: style)
        for im in body.images {
            refs.append(ImageRef(
                range: NSRange(location: im.range.location + bodyBase, length: im.range.length),
                src: im.src))
        }
        combined.append(body.text)
        if showIntroPost, !lastPost.isEmpty {
            combined.append(ReaderMarkup.dividerBlock(style: style))
            let r = markup.parse(lastPost, style: style)
            for im in r.images {
                refs.append(ImageRef(
                    range: NSRange(location: im.range.location + combined.length, length: im.range.length),
                    src: im.src))
            }
            combined.append(r.text)
        }
        attributed = combined
        imageRefs = refs
        Task { await loadImages(refs) }
    }

    private func load() async {
        loadError = nil
        if detail == nil {
            detail = try? await core.novelDetail(novelId)
        }
        loadBookmark()
        do {
            var sec = try? await core.section(novelId: novelId, index: chapterIndex)
            // 未取得の話は開いた時点で単話だけ自動取得する。
            // (リーダー内で完結させる — 「詳細から取得してください」の行き止まりをなくす。
            //  core 側は from_index + episodes:1 のスポット取得で、既存話には触れない。
            //  RateLimiter の初回は待ちなしなので体感は数秒以内)
            if (sec?.bodyXhtml ?? "").isEmpty, !tocUrl.isEmpty,
               let rawDir = detail?.novel.outputDir, !rawDir.isEmpty {
                autoFetching = true
                defer { autoFetching = false }
                // 全話取得など別ジョブが走っているときは競合させない。
                // 完了を待ちつつ、該当話が保存されたらそれを使う(最長5分)。
                if core.progress.running {
                    for _ in 0..<150 {
                        if !core.progress.running { break }
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        let poll = try? await core.section(novelId: novelId, index: chapterIndex)
                        if !(poll?.bodyXhtml ?? "").isEmpty {
                            sec = poll
                            break
                        }
                    }
                }
                if (sec?.bodyXhtml ?? "").isEmpty {
                    _ = try? await core.download(
                        CoreClient.DownloadOptions(
                            url: tocUrl,
                            outputDir: CoreClient.effectiveOutputDir(rawDir),
                            episodes: 1,
                            fromIndex: chapterIndex,
                            mode: "reader"
                        )
                    )
                    sec = try? await core.section(novelId: novelId, index: chapterIndex)
                    await core.reloadLibrary()
                }
            }
            guard let sec else {
                throw CoreError.message("この話のデータが見つかりません")
            }
            let meta = chapters.first { $0.index == chapterIndex }
            chapterTitle = meta?.subtitle ?? ""
            chapterLabel = "\(pos + 1)/\(total)話"
            chapterProgress = Double(pos + 1) / Double(total)
            let html = (sec.bodyXhtml ?? "").isEmpty ? "この話はまだ取得できませんでした。作品詳細から再取得してください。" : (sec.bodyXhtml ?? "")
            lastHTML = html
            lastSubTitle = meta?.subtitle ?? ""
            lastIntro = sec.introXhtml ?? ""
            lastPost = sec.postXhtml ?? ""
            rebuild()
        } catch {
            loadError = "読めませんでした: \(error.localizedDescription)"
        }
    }

    /// 挿絵を非同期に実画像へ差し替える(読書の応答性を落とさない)。
    private func loadImages(_ refs: [ImageRef]) async {
        let width = UIScreen.main.bounds.width - max(margin, 12) * 2
        let base = URL(string: tocUrl)
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
            var img: UIImage?
            if url.isFileURL {
                img = UIImage(contentsOfFile: url.path)
            } else if let (data, _) = try? await URLSession.shared.data(from: url) {
                img = UIImage(data: data)
            }
            guard let img else { return nil }
            let scaled = downscale(img, maxW: 1200)
            cache.setObject(scaled, forKey: url as NSURL)
            return scaled
        }
    }

    static func resolve(_ src: String, base: URL?) -> URL? {
        if src.hasPrefix("file://") { return URL(string: src) }
        if src.hasPrefix("/") { return URL(fileURLWithPath: src) }
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
