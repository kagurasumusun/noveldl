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
    /// 読書中は画面を消さない(既定オン。設定メニューから切れる)。
    @AppStorage("readerKeepAwake") private var keepAwake = true

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
    /// 自動めくり。
    @AppStorage("readerAutoSeconds") private var autoSeconds = 8.0
    @State private var autoPlaying = false
    /// 保存された旧版(改稿バージョン)。
    @State private var savedVersions = 0
    @State private var viewingOldVersion = false
    @State private var versionCursor = 0
    @State private var oldVersionDate = ""
    @State private var refetching = false
    @State private var backupHTML = ""
    @State private var backupIntro = ""
    @State private var backupPost = ""
    /// 目次の折りたたみ済み章。
    @State private var collapsedGroups: Set<String> = []
    /// 目次で描画済みの行数(段階読み込み)。
    @State private var renderedLimit = 150
    /// 軽い通知(数秒で消えるピル)。
    @State private var messagePillText: String?

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
    private var pageTurnIndex: Int {
        [PageTurn.curl, .fade, .slide, .none].firstIndex(of: turn) ?? 0
    }
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
                if chromeVisible && showFooter {
                    bottomBar
                        .transition(.opacity)
                }
            }

            // 常時表示の控えめなピル(話数/頁 + 取得中表示)。
            // バーの有無に関わらず読書位置をいつでも確認できる。
            VStack {
                Spacer()
                VStack(spacing: 5) {
                    if let msg = messagePillText {
                        Text(msg)
                            .font(AppFont.ui(12, weight: .medium))
                            .foregroundStyle(theme.ink)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, Spacing.m)
                            .padding(.vertical, 6)
                            .frame(maxWidth: 280)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(theme.background.opacity(0.92))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(theme.ink.opacity(0.12), lineWidth: 1)
                            )
                            .task {
                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                                withAnimation { messagePillText = nil }
                            }
                    } else if autoFetching {
                        fetchPill
                    } else if core.progress.running {
                        backgroundPill
                    }
                    if showFooter || !chromeVisible {
                        pagePill
                    }
                }
                .padding(.bottom, chromeVisible && showFooter ? 62 : 8)
            }
            .allowsHitTesting(false)

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
        // 紙・セピアは暗い時刻、夜は明るい時刻。アプリ全体のダーク指定を
        // 紙面に引き継ぐと、白い時刻がクリームの紙に乗って読めない。
        .preferredColorScheme(theme == .night ? .dark : .light)
        .task(id: chapterIndex) {
            await load()
            // 話移動の直後に一度だけ表示。消しタイマーは持たない(手動出没のみ)。
            withAnimation(.easeOut(duration: 0.3)) { chromeVisible = true }
        }
        // 作品の取得はリーダーが開いている間だけ。話を変えても中断しない
        // (話ごとの task にぶら下げると、めくるたびに取り直しが走る)。
        .task { await fillNovelInBackground() }
        .sheet(item: $sheet) { target in
            switch target {
            case .toc: tocSheet
            case .menu: menuSheet
            }
        }
        .onAppear {
            // 読書中は画面を自動ロックさせない(読書アプリの基本動作)。
            UIApplication.shared.isIdleTimerDisabled = keepAwake
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
        .onChange(of: keepAwake) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on || autoPlaying
        }
        .onDisappear {
            // 離脱時に自動めくりと自動ロックを戻す。
            autoPlaying = false
            UIApplication.shared.isIdleTimerDisabled = false
            // 取得はリーダーが開いている間だけ行う(閉じたら中止)。
            // 再開は次に読んだとき(取得済み話はスキップされる)。
            core.cancel()
        }
    }

    // MARK: 上下バー(中央タップで出没)

    private var topBar: some View {
        // 左右のボタン幅を揃えて、題名が画面中央に来るようにする。
        // (右にボタンが多いと、固定幅の題名が左に寄って見えていた)
        ZStack {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    chromeButton("chevron.left", "詳細へ戻る") { dismiss() }
                    chromeButton("list.bullet", "目次") { sheet = .toc }
                }
                .frame(width: 96, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    chromeButton(bookmarked ? "bookmark.fill" : "bookmark", "栞") {
                        bookmarked.toggle()
                        saveBookmark(on: bookmarked)
                        Haptics.tap()
                    }
                    chromeButton("square.and.arrow.up", "共有") { share() }
                    chromeButton("gearshape", "読書設定") { sheet = .menu }
                }
                .frame(width: 96, alignment: .trailing)
            }
            VStack(spacing: 1) {
                Text(title)
                    .font(AppFont.serif(14, weight: .semibold))
                    .lineLimit(1)
                Text(chapterTitle.isEmpty ? chapterLabel : chapterTitle)
                    .font(AppFont.ui(11))
                    .opacity(0.75)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 100)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(theme.background.opacity(0.92))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            chromeCaptioned(autoPlaying ? "pause.fill" : "play.fill",
                            autoPlaying ? "停止" : "自動",
                            hidesChrome: false, active: autoPlaying) {
                toggleAuto()
            }
            chromeCaptioned("chevron.left", "前話", enabled: canGoPrev) {
                goChapter(delta: -1)
            }
            chromeCaptioned("chevron.up", "前ページ") {
                _ = readerBox.pageUp()
            }
            chromeCaptioned("list.bullet", "目次", hidesChrome: false) {
                sheet = .toc
            }
            chromeCaptioned("chevron.down", "次ページ") {
                _ = readerBox.pageDown()
            }
            chromeCaptioned("chevron.right", "次話", enabled: canGoNext) {
                goChapter(delta: 1)
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(theme.background.opacity(0.92))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    private func chromeButton(_ system: String, _ accessibility: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: system)
                .font(AppFont.ui(14, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(haptic: false))
        .accessibilityLabel(accessibility)
    }

    private func chromeCaptioned(_ system: String, _ caption: String, enabled: Bool = true,
                                 hidesChrome: Bool = true, active: Bool = false,
                                 act: @escaping () -> Void) -> some View {
        Button {
            act()
            Haptics.tap()
            // ボタン操作でもバーは自動で引っ込む(シート/トグル系は除く)
            if hidesChrome, chromeVisible {
                withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: system)
                    .font(AppFont.ui(13, weight: .semibold))
                Text(caption)
                    .font(AppFont.ui(10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(
                !enabled ? theme.ink.opacity(0.3)
                : active ? AppPalette.ember
                : theme.ink
            )
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(haptic: false))
        .disabled(!enabled)
    }

    private var hintPill: some View {
        Text("中央タップでバー。左右でページを送る")
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
            Text(core.progress.running ? "別の取得が終わるまで待ちます" : "この話を取得しています")
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(Capsule().fill(theme.background.opacity(0.97)))
        .overlay(Capsule().strokeBorder(theme.ink.opacity(0.15), lineWidth: 1))
    }

    /// 背景でこの作品の続きを取得しているときの表示。
    private var backgroundPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text(core.progress.total > 0
                 ? "続きを取得中 \(core.progress.done + core.progress.skipped)/\(core.progress.total)"
                 : "続きを取得しています")
                .font(AppFont.ui(12, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, 6)
        .background(Capsule().fill(theme.background.opacity(0.9)))
        .overlay(Capsule().strokeBorder(theme.ink.opacity(0.12), lineWidth: 1))
    }

    /// 話数と頁の小さな常時ピル。
    private var pagePill: some View {
        HStack(spacing: 6) {
            Text(chapterLabel)
                .font(AppFont.ui(11, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.ink.opacity(0.8))
            Text("・")
                .font(AppFont.ui(11))
                .foregroundStyle(theme.ink.opacity(0.35))
            Text(pageCount > 1 ? "\(currentPage + 1)/\(pageCount)" : "1/1")
                .font(AppFont.ui(11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.ink.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.background.opacity(0.72)))
        .overlay(Capsule().strokeBorder(theme.ink.opacity(0.10), lineWidth: 1))
        .accessibilityLabel("\(currentPage + 1)ページ、全\(max(pageCount, 1))ページ")
    }

    // MARK: 読書メニュー(読書時専用)

    private var menuSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("読書の設定")
                        .font(AppFont.serif(22, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Text(chapterTitle.isEmpty ? chapterLabel : "\(chapterLabel)　\(chapterTitle)")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkSoft)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Spacing.s)

                menuCard("紙面") {
                    themePicker
                    menuField("書体") {
                        SegmentTabs(
                            titles: ["明朝", "ゴシック", "丸ゴシック"],
                            selection: Binding(
                                get: { fontDesign == "serif" ? 0 : (fontDesign == "rounded" ? 2 : 1) },
                                set: { i in
                                    fontDesign = i == 0 ? "serif" : (i == 2 ? "rounded" : "sans")
                                    applyStyle()
                                }
                            )
                        )
                    }
                    StepperRow(label: "文字の大きさ",
                               value: Binding(get: { fontSize }, set: { fontSize = $0; applyStyle() }),
                               range: 14...28)
                    StepperRow(label: "行間",
                               value: Binding(get: { lineSpacing }, set: { lineSpacing = $0; applyStyle() }),
                               range: 2...18)
                    StepperRow(label: "余白",
                               value: Binding(get: { margin }, set: { margin = $0; applyStyle() }),
                               range: 4...36, step: 2)
                    typePreview
                        .padding(.top, Spacing.s)
                }

                menuCard("表示") {
                    toggleRow("ルビ", showRuby) { showRuby.toggle(); applyStyle() }
                    RowDivider()
                    toggleRow("話の見出し", showChapterTitle) { showChapterTitle.toggle(); applyStyle() }
                    RowDivider()
                    toggleRow("前書き・後書き", showIntroPost) { showIntroPost.toggle(); applyStyle() }
                    RowDivider()
                    toggleRow("上のバー", showHeader) { showHeader.toggle() }
                    RowDivider()
                    toggleRow("下のバー", showFooter) { showFooter.toggle() }
                    Text("前書き・後書きを隠しても、挿絵は本文に残ります。")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }

                menuCard("めくり") {
                    menuField("アニメーション") {
                        SegmentTabs(
                            titles: PageTurn.all.map(\.label),
                            selection: Binding(
                                get: { pageTurnIndex },
                                set: { pageTurnRaw = PageTurn.all[$0].rawValue }
                            )
                        )
                    }
                    toggleRow("左右のスワイプで送る", swipePaging) { swipePaging.toggle() }
                    RowDivider()
                    toggleRow("自動でめくる", autoPlaying) { toggleAuto() }
                    if autoPlaying {
                        StepperRow(label: "めくる間隔", value: $autoSeconds, range: 3...30, suffix: "秒")
                    }
                    RowDivider()
                    toggleRow("画面を消さない", keepAwake) { keepAwake.toggle() }
                }

                menuCard("この話") {
                    if pageCount > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("ページ")
                                    .font(AppFont.ui(15))
                                    .foregroundStyle(AppPalette.ink)
                                Spacer()
                                Text("\(currentPage + 1) / \(pageCount)")
                                    .font(AppFont.ui(13, weight: .semibold))
                                    .foregroundStyle(AppPalette.inkSoft)
                                    .monospacedDigit()
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(currentPage) },
                                    set: { readerBox.jump(to: Int($0.rounded())) }
                                ),
                                in: 0...Double(pageCount - 1),
                                step: 1
                            )
                            .tint(AppPalette.ember)
                        }
                        .padding(.vertical, 8)
                        RowDivider()
                    }

                    HStack(spacing: Spacing.s) {
                        QuietButton(title: "古い版", systemImage: "clock.arrow.circlepath",
                                    disabled: viewingOldVersion && savedVersions > 0 && versionCursor + 1 >= savedVersions) {
                            Task { await stepVersion(older: true) }
                        }
                        if viewingOldVersion {
                            QuietButton(title: versionCursor > 0 ? "新しい版" : "最新に戻す",
                                        systemImage: "arrow.uturn.backward") {
                                Task { await stepVersion(older: false) }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    if viewingOldVersion {
                        Text(oldVersionDate.isEmpty ? "古い版を表示中" : "\(oldVersionDate) の版を表示中")
                            .font(AppFont.ui(12, weight: .semibold))
                            .foregroundStyle(AppPalette.gold)
                            .padding(.bottom, 4)
                    }
                    Text(savedVersions > 0
                         ? "改稿前の本文が \(savedVersions) 版残っています。最大8版。"
                         : "改稿すると、直前の本文を最大8版残します。")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    RowDivider()
                    menuLink(refetching ? "取り直しています…" : "この話を取り直す",
                             system: "arrow.clockwise", disabled: refetching) {
                        Task { await refetchCurrent() }
                    }
                    RowDivider()
                    menuLink("目次を開く", system: "list.bullet") { sheet = .toc }
                    RowDivider()
                    menuLink("前の話へ", system: "chevron.left", disabled: !canGoPrev) {
                        sheet = nil
                        goChapter(delta: -1)
                    }
                    RowDivider()
                    menuLink("次の話へ", system: "chevron.right", disabled: !canGoNext) {
                        sheet = nil
                        goChapter(delta: 1)
                    }
                }

                QuietButton(title: "表示を初期値に戻す", systemImage: "arrow.counterclockwise") {
                    resetReadingStyle()
                }
                QuietButton(title: "作品詳細へ戻る", systemImage: "chevron.left") {
                    sheet = nil
                    dismiss()
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(AppPalette.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        .presentationBackground(AppPalette.canvas)
        .preferredColorScheme(.dark)
    }

    private var themePicker: some View {
        HStack(spacing: Spacing.s) {
            ForEach(BookTheme.allCases, id: \.self) { item in
                let on = theme == item
                Button {
                    themeRaw = item.rawValue
                    applyStyle()
                    Haptics.tap()
                } label: {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(item.background)
                            .frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(item == .night ? Color.white.opacity(0.55) : item.hairline, lineWidth: 1))
                            .overlay {
                                if on {
                                    Circle()
                                        .strokeBorder(AppPalette.ember, lineWidth: 2)
                                        .padding(-4)
                                }
                            }
                        Text(item.label)
                            .font(AppFont.ui(12, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? AppPalette.ink : AppPalette.inkSoft)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(on ? AppPalette.surface : Color.clear)
                    )
                }
                .buttonStyle(PressableButtonStyle(haptic: false))
            }
        }
        .padding(.bottom, 4)
    }

    private var typePreview: some View {
        Text("吾輩は猫である。名前はまだ無い。")
            .font(.system(size: min(fontSize, 22),
                          design: fontDesign == "serif" ? .serif : (fontDesign == "rounded" ? .rounded : .default)))
            .foregroundStyle(theme.ink)
            .lineSpacing(max(2, lineSpacing * 0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 1)
            )
    }

    private func menuCard<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(AppFont.ui(15, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.m)
                .padding(.bottom, 6)
            content()
                .padding(.horizontal, Spacing.m)
                .padding(.bottom, Spacing.s)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperBackground())
    }

    private func menuField<Content: View>(_ title: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppFont.ui(13))
                .foregroundStyle(AppPalette.inkSoft)
            content()
        }
        .padding(.vertical, 8)
    }

    private func menuLink(_ title: String, system: String, disabled: Bool = false,
                          act: @escaping () -> Void) -> some View {
        Button(action: {
            guard !disabled else { return }
            Haptics.tap()
            act()
        }) {
            HStack(spacing: 10) {
                Image(systemName: system)
                    .font(AppFont.ui(14, weight: .semibold))
                    .foregroundStyle(disabled ? AppPalette.inkFaint : AppPalette.ember)
                    .frame(width: 22)
                Text(title)
                    .font(AppFont.ui(15))
                    .foregroundStyle(disabled ? AppPalette.inkFaint : AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(AppFont.ui(11, weight: .semibold))
                    .foregroundStyle(AppPalette.inkFaint)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(haptic: false))
        .disabled(disabled)
    }

    private var tocSheet: some View {
        // 開くたびに取得状況を取り直す(背景取得の結果を即時反映)。
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("目次")
                        .font(AppFont.serif(20, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Spacer()
                    if let d = detail {
                        Text("取得済み \(d.downloadedCount)/\(d.novel.episodeCount)")
                            .font(AppFont.ui(12).monospacedDigit())
                            .foregroundStyle(AppPalette.inkSoft)
                    }
                }
                .padding(Spacing.l)

                let all = detail?.chapters ?? []
                let groups = tocGroups(all)
                ForEach(groups, id: \.name) { group in
                    if let name = group.name {
                        Button {
                            Haptics.tap()
                            if collapsedGroups.contains(name) {
                                collapsedGroups.remove(name)
                            } else {
                                collapsedGroups.insert(name)
                            }
                        } label: {
                            HStack(spacing: Spacing.s) {
                                Image(systemName: collapsedGroups.contains(name)
                                      ? "chevron.right" : "chevron.down")
                                    .font(AppFont.ui(10, weight: .semibold))
                                    .foregroundStyle(AppPalette.inkFaint)
                                Text(name)
                                    .font(AppFont.ui(13, weight: .semibold))
                                    .foregroundStyle(AppPalette.ink)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                Text("\(group.chapters.count)話")
                                    .font(AppFont.ui(11).monospacedDigit())
                                    .foregroundStyle(AppPalette.inkFaint)
                                Spacer()
                                let done = group.chapters.filter { $0.bodyDownloaded == true }.count
                                Text("\(done)/\(group.chapters.count)")
                                    .font(AppFont.ui(11).monospacedDigit())
                                    .foregroundStyle(done == group.chapters.count ? AppPalette.gold : AppPalette.inkFaint)
                            }
                            .padding(.horizontal, Spacing.l)
                            .padding(.vertical, 10)
                            .background(AppPalette.canvas)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableButtonStyle(haptic: false))
                    }
                    if group.name == nil || !collapsedGroups.contains(group.name ?? "") {
                        ForEach(Array(group.chapters.prefix(renderedLimit)), id: \.index) { ch in
                            tocRow(ch)
                            RowDivider(leading: Spacing.l)
                        }
                    }
                }
                if tocRowsTotal > renderedLimit {
                    HStack(spacing: Spacing.s) {
                        ProgressView().scaleEffect(0.7)
                        Text("残り \(tocRowsTotal - renderedLimit) 話…")
                            .font(AppFont.ui(11))
                            .foregroundStyle(AppPalette.inkFaint)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 60_000_000)
                            renderedLimit += 150
                        }
                    }
                }
            }
        }
        .task {
            // 取得状況(✔)を開くたびに更新する
            if let fresh = try? await core.novelDetail(novelId) {
                detail = fresh
                // 長編では現在の章の章だけ開き、他は折りたたむ
                if collapsedGroups.isEmpty && (fresh.chapters.count > 120) {
                    for g in tocGroups(fresh.chapters) where g.name != nil {
                        let hasCurrent = g.chapters.contains { $0.index == chapterIndex }
                        if !hasCurrent { collapsedGroups.insert(g.name!) }
                    }
                }
            }
        }
        .onChange(of: core.progress.running) { _, running in
            // 背景取得などが終わったら ✔ を即時反映する
            if !running {
                Task {
                    if let fresh = try? await core.novelDetail(novelId) {
                        detail = fresh
                    }
                }
            }
        }
        .onChange(of: core.progress.done) { _, _ in
            guard sheet == .toc, core.progress.running else { return }
            Task {
                if let fresh = try? await core.novelDetail(novelId) {
                    detail = fresh
                }
            }
        }
        .background(AppPalette.canvas)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppPalette.canvas)
        .preferredColorScheme(.dark)
    }

    private struct TocGroup {
        let name: String?
        let chapters: [ChapterMeta]
    }

    /// chapter(章名)でグループ化。章が無い話は name = nil の一つの束に。
    private func tocGroups(_ chapters: [ChapterMeta]) -> [TocGroup] {
        var out: [TocGroup] = []
        var currentName: String? = nil
        var bucket: [ChapterMeta] = []
        func flush() {
            if !bucket.isEmpty {
                out.append(TocGroup(name: currentName, chapters: bucket))
                bucket = []
            }
        }
        for ch in chapters {
            let trimmed = (ch.chapter ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let nm: String? = trimmed.isEmpty ? nil : trimmed
            if out.isEmpty && bucket.isEmpty { currentName = nm }
            if nm != currentName {
                flush()
                currentName = nm
            }
            bucket.append(ch)
        }
        flush()
        return out
    }

    private var tocRowsTotal: Int {
        (detail?.chapters ?? []).count
    }

    /// 目次行(取得済み ✔ / 改稿マーク / 現在話)。
    private func tocRow(_ ch: ChapterMeta) -> some View {
        Button {
            sheet = nil
            if ch.index != chapterIndex {
                chapterIndex = ch.index
            }
        } label: {
            HStack(spacing: Spacing.m) {
                Text(ch.index)
                    .font(AppFont.ui(12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AppPalette.inkFaint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: 28, alignment: .trailing)
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
        Button(action: {
            act()
            Haptics.tap()
        }) {
            HStack(spacing: 12) {
                Text(label)
                    .font(AppFont.ui(15))
                    .foregroundStyle(AppPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                InkSwitch(isOn: isOn)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(haptic: false))
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "オン" : "オフ")
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
            ink: theme.uiInk,
            inkIsLight: theme.inkIsLight,
            maxWidth: UIScreen.main.bounds.width - max(margin, 12) * 2,
            design: fontDesign,
            showRuby: showRuby
        )
    }

    private func applyStyle() {
        rebuild()
    }

    /// 自動めくりのON/OFF。一定間隔で次頁、最終頁では次の話へ。
    private func toggleAuto() {
        if autoPlaying {
            autoPlaying = false
            UIApplication.shared.isIdleTimerDisabled = keepAwake
            return
        }
        autoPlaying = true
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            while autoPlaying {
                try? await Task.sleep(nanoseconds: UInt64(max(autoSeconds, 2) * 1_000_000_000))
                guard autoPlaying else { break }
                if !readerBox.pageDown() {
                    if canGoNext {
                        goChapter(delta: 1)
                    } else {
                        autoPlaying = false
                        UIApplication.shared.isIdleTimerDisabled = keepAwake
                    }
                }
            }
        }
    }

    /// 改稿で残した版を、新しい順に offset 0 から辿る。
    private func stepVersion(older: Bool) async {
        if !older {
            if versionCursor > 0 {
                await openVersion(offset: versionCursor - 1)
            } else {
                restoreCurrentVersion()
            }
            return
        }
        let next = viewingOldVersion ? versionCursor + 1 : 0
        if viewingOldVersion, savedVersions > 0, next >= savedVersions {
            messagePillText = "これ以上古い版はありません"
            return
        }
        await openVersion(offset: next)
    }

    private func openVersion(offset: Int) async {
        guard let ver = try? await core.sectionVersion(novelId: novelId, index: chapterIndex, offset: offset),
              !(ver.bodyXhtml ?? "").isEmpty else {
            messagePillText = offset == 0 ? "古い版はまだありません" : "これ以上古い版はありません"
            return
        }
        if !viewingOldVersion {
            backupHTML = lastHTML
            backupIntro = lastIntro
            backupPost = lastPost
        }
        lastHTML = ver.bodyXhtml ?? ""
        lastIntro = ver.introXhtml ?? ""
        lastPost = ver.postXhtml ?? ""
        oldVersionDate = String((ver.updatedAt ?? "").prefix(10))
        versionCursor = offset
        viewingOldVersion = true
        rebuild()
    }

    private func restoreCurrentVersion() {
        guard viewingOldVersion else { return }
        lastHTML = backupHTML
        lastIntro = backupIntro
        lastPost = backupPost
        viewingOldVersion = false
        versionCursor = 0
        rebuild()
    }

    /// この話だけ取り直す。リーダーを開いたまま、取得の完了を待つ。
    private func refetchCurrent() async {
        guard !refetching, !tocUrl.isEmpty,
              let rawDir = detail?.novel.outputDir, !rawDir.isEmpty else {
            messagePillText = "この話は取り直せません"
            return
        }
        refetching = true
        defer { refetching = false }
        sheet = nil
        messagePillText = "この話を取り直しています"
        if core.progress.running {
            core.cancel()
            for _ in 0..<40 where core.progress.running {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        do {
            _ = try await core.download(CoreClient.DownloadOptions(
                url: tocUrl,
                outputDir: CoreClient.effectiveOutputDir(rawDir),
                episodes: 1,
                fromIndex: chapterIndex,
                mode: "refresh"
            ))
            let sec = try await core.section(novelId: novelId, index: chapterIndex)
            lastHTML = sec.bodyXhtml ?? ""
            lastIntro = sec.introXhtml ?? ""
            lastPost = sec.postXhtml ?? ""
            savedVersions = sec.versions ?? savedVersions
            viewingOldVersion = false
            versionCursor = 0
            if lastHTML.isEmpty {
                messagePillText = "本文を取得できませんでした"
            } else {
                rebuild()
                messagePillText = "取り直しました"
            }
        } catch {
            messagePillText = "取り直せませんでした"
        }
    }

    private func resetReadingStyle() {
        themeRaw = BookTheme.paper.rawValue
        fontSize = 19
        lineSpacing = 8
        margin = 12
        fontDesign = "serif"
        showRuby = true
        showChapterTitle = true
        showIntroPost = false
        showHeader = true
        showFooter = true
        swipePaging = true
        pageTurnRaw = PageTurn.curl.rawValue
        keepAwake = true
        applyStyle()
        Haptics.tap()
        messagePillText = "表示を初期値に戻しました"
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
        // 旧バージョンで保存した本文には前書き/後書きが混入していることがある。
        // 混入済みなら二重表示を避けるため別ブロックの追加を省く。
        func normalized(_ t: String) -> String {
            t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "[\\s\\u3000]", with: "", options: .regularExpression)
        }
        let bodyPlain = normalized(lastHTML)
        var skipIntro = false
        var skipPost = false
        if showIntroPost {
            let introPlain = normalized(lastIntro)
            if !introPlain.isEmpty, bodyPlain.hasPrefix(String(introPlain.prefix(48))) {
                skipIntro = true
            }
            let postPlain = normalized(lastPost)
            if !postPlain.isEmpty, bodyPlain.hasSuffix(String(postPlain.suffix(48))) {
                skipPost = true
            }
        }
        if showIntroPost, !lastIntro.isEmpty, !skipIntro {
            let r = markup.parse(lastIntro, style: style)
            for im in r.images {
                refs.append(ImageRef(
                    range: NSRange(location: im.range.location + combined.length, length: im.range.length),
                    src: im.src))
            }
            combined.append(r.text)
            combined.append(ReaderMarkup.dividerBlock(style: style))
        } else if !showIntroPost {
            // 前書き非表示でも挿絵だけは表示する(なろう系は前書きに挿絵を置く作家が多い。
            // 非表示 = 文章を隠すだけ で、挿絵まで消えるのは読書体験として壊れている)。
            let imgs = ReaderMarkup.imageOnlyXhtml(lastIntro)
            if !imgs.isEmpty {
                let r = markup.parse(imgs, style: style)
                for im in r.images {
                    refs.append(ImageRef(
                        range: NSRange(location: im.range.location + combined.length, length: im.range.length),
                        src: im.src))
                }
                combined.append(r.text)
            }
        }
        let bodyBase = combined.length
        let body = markup.parse(lastHTML, style: style)
        for im in body.images {
            refs.append(ImageRef(
                range: NSRange(location: im.range.location + bodyBase, length: im.range.length),
                src: im.src))
        }
        combined.append(body.text)
        if showIntroPost, !lastPost.isEmpty, !skipPost {
            combined.append(ReaderMarkup.dividerBlock(style: style))
            let r = markup.parse(lastPost, style: style)
            for im in r.images {
                refs.append(ImageRef(
                    range: NSRange(location: im.range.location + combined.length, length: im.range.length),
                    src: im.src))
            }
            combined.append(r.text)
        } else if !showIntroPost {
            let imgs = ReaderMarkup.imageOnlyXhtml(lastPost)
            if !imgs.isEmpty {
                let r = markup.parse(imgs, style: style)
                for im in r.images {
                    refs.append(ImageRef(
                        range: NSRange(location: im.range.location + combined.length, length: im.range.length),
                        src: im.src))
                }
                combined.append(r.text)
            }
        }
        attributed = combined
        imageRefs = refs
        Task { await loadImages(refs) }
    }

    /// この小説の未取得の話を背景で取得する。
    /// 「リーダーが開いているときだけ取得する」モデル。既に取得済みの話は
    /// コア側で全てスキップされるため、続き・改稿だけが実際に通信する。
    /// 閉じたときは core.cancel() で止まり、続きは次回の読書で再開する。
    /// 開いている作品の未取得話を埋める。いまの話から末尾、その後に先頭側。
    /// 単話取得とぶつかったら待ってやり直す(コアは同時1本)。
    private func fillNovelInBackground() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled, !tocUrl.isEmpty else { return }
        if detail == nil { detail = try? await core.novelDetail(novelId) }
        guard let rawDir = detail?.novel.outputDir, !rawDir.isEmpty else { return }
        let out = CoreClient.effectiveOutputDir(rawDir)
        let start = chapterIndex
        for pass in [start, ""] {
            if Task.isCancelled { return }
            if pass.isEmpty && start.isEmpty { continue }
            var attempts = 0
            while attempts < 4 && !Task.isCancelled {
                attempts += 1
                while core.progress.running && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                if Task.isCancelled { return }
                do {
                    _ = try await core.download(
                        CoreClient.DownloadOptions(
                            url: tocUrl,
                            outputDir: out,
                            episodes: 0,
                            fromIndex: pass,
                            mode: "bulk"
                        )
                    )
                    break
                } catch {
                    let msg = error.localizedDescription
                    if msg.contains("進行中") || msg.contains("cancelled") || msg.contains("中止") {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        continue
                    }
                    break
                }
            }
            if let fresh = try? await core.novelDetail(novelId) { detail = fresh }
        }
        await core.reloadLibrary()
        if let fresh = try? await core.novelDetail(novelId) { detail = fresh }
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
                // 背景取得がこの話に届くのを少し待つ。届かなければ単話を優先する。
                // コアは同時に1本しか走らせないので、待つだけでなく必要なら中止してから取る。
                if core.progress.running {
                    for _ in 0..<8 {
                        if Task.isCancelled { return }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        let poll = try? await core.section(novelId: novelId, index: chapterIndex)
                        if !(poll?.bodyXhtml ?? "").isEmpty {
                            sec = poll
                            break
                        }
                        if !core.progress.running { break }
                    }
                    if (sec?.bodyXhtml ?? "").isEmpty, core.progress.running {
                        core.cancel()
                        for _ in 0..<40 {
                            if !core.progress.running { break }
                            try? await Task.sleep(nanoseconds: 200_000_000)
                        }
                    }
                }
                if (sec?.bodyXhtml ?? "").isEmpty, !core.progress.running, !Task.isCancelled {
                    _ = try await core.download(
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
                    if let fresh = try? await core.novelDetail(novelId) { detail = fresh }
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
            savedVersions = sec.versions ?? 0
            viewingOldVersion = false
            rebuild()
        } catch {
            loadError = "読めませんでした: \(error.localizedDescription)"
        }
    }

    /// 保存時の絶対パスがコンテナ変更で死んでいても、/novels/ 以降から現ライブラリを探す。
    private func relocateImagePath(_ src: String, baseDir: String?, libraryRoot: String, children: [String]) -> String {
        if !src.hasPrefix("/") || FileManager.default.fileExists(atPath: src) { return src }
        guard let r = src.range(of: "/novels/") else { return src }
        let suffix = String(src[r.lowerBound...])
        var candidates = [libraryRoot + suffix]
        if let baseDir { candidates.append(baseDir + suffix) }
        for kid in children where !kid.hasPrefix(".") {
            candidates.append(libraryRoot + "/" + kid + suffix)
        }
        for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
        return src
    }

    /// 挿絵を非同期に実画像へ差し替える(読書の応答性を落とさない)。
    private func loadImages(_ refs: [ImageRef]) async {
        let width = UIScreen.main.bounds.width - max(margin, 12) * 2
        let base = URL(string: tocUrl)
        // 保存時に埋め込まれた絶対パスは、アプリ再インストール等でコンテナUUIDが
        // 変わると死ぬ。/novels/ 以降の相対位置を現 outputDir 配下へ張り直す。
        var baseDir: String?
        if let rawDir = detail?.novel.outputDir, !rawDir.isEmpty {
            baseDir = CoreClient.effectiveOutputDir(rawDir)
        }
        let libraryRoot = CoreClient.libraryRoot().path
        let libraryChildren = (try? FileManager.default.contentsOfDirectory(atPath: libraryRoot)) ?? []
        for ref in refs {
            let src = relocateImagePath(ref.src, baseDir: baseDir, libraryRoot: libraryRoot, children: libraryChildren)
            guard let url = ReaderImageStore.resolve(src, base: base) else { continue }
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
            // トグルやスペーサー(極小)は挿絵として出さない。
            if img.size.width * img.size.height < 800 { return nil }
            let scaled = downscale(img, maxW: 1200)
            cache.setObject(scaled, forKey: url as NSURL)
            return scaled
        }
    }

    static func resolve(_ src: String, base: URL?) -> URL? {
        if src.hasPrefix("file://") { return URL(string: src) }
        if src.hasPrefix("/") { return URL(fileURLWithPath: src) }
        // プロトコル相対(//host/... — なろうのみてみん挿絵など)
        if src.hasPrefix("//") { return URL(string: "https:" + src) }
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return URL(string: src) }
        guard let base else { return nil }
        if let u = URL(string: src, relativeTo: base)?.absoluteURL { return u }
        // 日本語ファイル名等で URL(string:) が失敗する場合の percent-encode 再試行
        guard let enc = src.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: enc, relativeTo: base)?.absoluteURL
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
