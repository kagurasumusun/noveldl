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
    /// 自動めくり。
    @AppStorage("readerAutoSeconds") private var autoSeconds = 8.0
    @State private var autoPlaying = false
    /// 保存された旧版(改稿バージョン)。
    @State private var savedVersions = 0
    @State private var viewingOldVersion = false
    @State private var oldVersionDate = ""
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
                            .font(AppFont.ui(11, weight: .medium))
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, Spacing.m)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(theme.background.opacity(0.92)))
                            .overlay(Capsule().strokeBorder(theme.ink.opacity(0.12), lineWidth: 1))
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
                .padding(.bottom, 8)
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
        .task(id: chapterIndex) {
            await load()
            // 話移動の直後に一度だけ表示。消しタイマーは持たない(手動出没のみ)。
            withAnimation(.easeOut(duration: 0.3)) { chromeVisible = true }
            // この作品の残りを背景で取得する(リーダーが開いている間だけ)。
            await startNovelDownload()
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
        HStack(spacing: Spacing.s) {
            chromeButton("chevron.left", "詳細へ戻る") { dismiss() }
            chromeButton("list.bullet", "目次") { sheet = .toc }
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
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(theme.background.opacity(0.92))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            chromeCaptioned(autoPlaying ? "pause.fill" : "play.fill",
                            autoPlaying ? "停止" : "自動", hidesChrome: false) {
                toggleAuto()
            }
            chromeCaptioned("chevron.left", "前話", enabled: canGoPrev) {
                goChapter(delta: -1)
            }
            chromeCaptioned("chevron.up", "前頁") {
                _ = readerBox.pageUp()
            }
            chromeCaptioned("list.bullet", "目次", hidesChrome: false) {
                sheet = .toc
            }
            chromeCaptioned("chevron.down", "次頁") {
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
                                 hidesChrome: Bool = true, act: @escaping () -> Void) -> some View {
        Button {
            act()
            Haptics.tap()
            // ボタン操作でもバーは自動で引っ込む(シート/トグル系は除く)
            if hidesChrome, chromeVisible {
                withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: system)
                    .font(AppFont.ui(12, weight: .semibold))
                Text(caption)
                    .font(AppFont.ui(8.5, weight: .medium))
            }
            .foregroundStyle(enabled ? theme.ink : theme.ink.opacity(0.3))
            .frame(width: 48, height: 34)
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

    /// 背景でこの作品の続きを取得しているときの表示。
    private var backgroundPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text(core.progress.total > 0
                 ? "背景で取得中 \(core.progress.done + core.progress.skipped)/\(core.progress.total)"
                 : "背景で取得中…")
                .font(AppFont.ui(11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.ink)
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
                .font(AppFont.ui(10, weight: .semibold).monospacedDigit())
                .foregroundStyle(theme.ink.opacity(0.75))
            Text("・")
                .font(AppFont.ui(10))
                .foregroundStyle(theme.ink.opacity(0.35))
            Text(pageCount > 1 ? "\(currentPage + 1)/\(pageCount)頁" : "1/1頁")
                .font(AppFont.ui(10, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.ink.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.background.opacity(0.72)))
        .overlay(Capsule().strokeBorder(theme.ink.opacity(0.10), lineWidth: 1))
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
                    RowDivider()
                    toggleRow("自動めくり", autoPlaying) {
                        toggleAuto()
                    }
                    if autoPlaying {
                        RowDivider()
                        StepperRow(label: "めくる間隔",
                                   value: Binding(get: { Int(autoSeconds) },
                                                  set: { autoSeconds = Double($0) }),
                                   range: 3...30, step: 1, suffix: "秒")
                    }
                }
                .background(PaperBackground())

                menuSectionHeader("移動", "GO")
                if savedVersions > 0 {
                    VStack(spacing: 0) {
                        SettingRow(label: viewingOldVersion
                                   ? "旧版を表示中\(oldVersionDate.isEmpty ? "" : "(\(oldVersionDate))")"
                                   : "この話の改稿前の本文") {
                            HStack(spacing: Spacing.s) {
                                if viewingOldVersion {
                                    QuietButton(title: "戻す", systemImage: "arrow.uturn.backward") {
                                        restoreCurrentVersion()
                                    }
                                } else {
                                    QuietButton(title: "旧版を見る", systemImage: "clock.arrow.circlepath") {
                                        Task { await showOldVersion() }
                                    }
                                }
                            }
                        }
                        RowDivider()
                        Text("改稿時に自動で保存した直前の本文です(最大8版)。")
                            .font(AppFont.ui(11))
                            .foregroundStyle(AppPalette.inkFaint)
                            .padding(.horizontal, Spacing.m)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(PaperBackground())
                }
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
        .presentationDetents([.medium, .large])
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
                Text("\(ch.index)")
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

    /// セクション見出し: 日本語を主体に、英語は小さく補助として添える。
    private func menuSectionHeader(_ title: String, _ en: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(title)
                .font(AppFont.serif(16, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text(en)
                .font(AppFont.ui(9.5, weight: .semibold))
                .foregroundStyle(AppPalette.inkFaint)
                .tracking(1.5)
            Rectangle()
                .fill(AppPalette.hairline)
                .frame(height: 1)
        }
        .padding(.top, Spacing.xs)
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

    /// 自動めくりのON/OFF。一定間隔で次頁、最終頁では次の話へ。
    private func toggleAuto() {
        if autoPlaying {
            autoPlaying = false
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
                        UIApplication.shared.isIdleTimerDisabled = false
                    }
                }
            }
        }
    }

    /// 改稿で保存された直前の版を表示する。
    private func showOldVersion() async {
        guard !viewingOldVersion else { return }
        guard let ver = try? await core.sectionVersion(novelId: novelId, index: chapterIndex, offset: 0),
              !(ver.bodyXhtml ?? "").isEmpty else {
            messagePillText = "旧版が見つかりませんでした"
            return
        }
        backupHTML = lastHTML
        backupIntro = lastIntro
        backupPost = lastPost
        lastHTML = ver.bodyXhtml ?? ""
        lastIntro = ver.introXhtml ?? ""
        lastPost = ver.postXhtml ?? ""
        oldVersionDate = String((ver.updatedAt ?? "").prefix(10))
        viewingOldVersion = true
        rebuild()
    }

    private func restoreCurrentVersion() {
        guard viewingOldVersion else { return }
        lastHTML = backupHTML
        lastIntro = backupIntro
        lastPost = backupPost
        viewingOldVersion = false
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
        }
        attributed = combined
        imageRefs = refs
        Task { await loadImages(refs) }
    }

    /// この小説の未取得の話を背景で取得する。
    /// 「リーダーが開いているときだけ取得する」モデル。既に取得済みの話は
    /// コア側で全てスキップされるため、続き・改稿だけが実際に通信する。
    /// 閉じたときは core.cancel() で止まり、続きは次回の読書で再開する。
    private func startNovelDownload() async {
        guard !tocUrl.isEmpty,
              let rawDir = detail?.novel.outputDir, !rawDir.isEmpty else { return }
        guard !core.progress.running else { return }  // 単話取得などが走っていれば委ねる
        // 今読んでいる話の続きから順に(先頭からだと読書位置に届くまで待つ)。
        _ = try? await core.download(
            CoreClient.DownloadOptions(
                url: tocUrl,
                outputDir: CoreClient.effectiveOutputDir(rawDir),
                episodes: 0,
                fromIndex: chapterIndex,
                mode: "bulk"
            )
        )
        await core.reloadLibrary()
        // 取得済み✔などが目次・操作面に即時反映されるように取り直す。
        if let fresh = try? await core.novelDetail(novelId) {
            detail = fresh
        }
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
            savedVersions = sec.versions ?? 0
            viewingOldVersion = false
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
