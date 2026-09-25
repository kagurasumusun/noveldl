import SwiftUI

/// 設定 — 既定の Form を廃止し、紙面カード + 独自行で構成。
struct SettingsView: View {
    @Environment(CoreClient.self) private var core: CoreClient

    @AppStorage("downloadIntervalMs") private var intervalMs = 5000
    @AppStorage("browserFetchCommand") private var browserCommand = ""
    @AppStorage("readerTheme") private var readerTheme = BookTheme.paper.rawValue
    @AppStorage("readerFontSize") private var readerFontSize = 19.0
    @AppStorage("readerLineSpacing") private var readerLineSpacing = 6.0

    @State private var presets: [String] = []
    @State private var over18: Set<String> = []
    @State private var cookieDomain = ""
    @State private var cookieValue = ""
    @State private var statusText: String?
    @State private var designIndex = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    SectionBanner(title: "設定")

                    sectionCard(
                        title: "取得とアクセス制限",
                        footer: "サイトに負荷をかけないよう、リクエスト間に必ず間隔を空けます(既定 5 秒)。429 応答時は 10 秒以上のバックオフで再試行します。"
                    ) {
                        StepperRow(
                            label: "話と話の最小間隔",
                            value: Binding(
                                get: { Double(intervalMs) / 1000 },
                                set: {
                                    intervalMs = Int($0) * 1000
                                    core.setDownloadInterval(ms: UInt32(intervalMs))
                                }
                            ),
                            range: 1...30,
                            step: 1,
                            suffix: "秒"
                        )
                        RowDivider()
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text("ブラウザ取得コマンド")
                                .font(AppFont.ui(15))
                                .foregroundStyle(AppPalette.ink)
                            Text("対策ページを通過できない場合に使うコマンドです(空欄 = 使わない)。")
                                .font(AppFont.ui(12))
                                .foregroundStyle(AppPalette.inkFaint)
                            PaperField(placeholder: "例: curl -A '…' '%@'", text: $browserCommand, mono: true)
                                .onChange(of: browserCommand) {
                                    core.setBrowserFetch(command: browserCommand.isEmpty ? nil : browserCommand)
                                }
                        }
                        .padding(.vertical, Spacing.s)
                    }

                    sectionCard(
                        title: "対応サイト",
                        footer: "抽出ルールはデータで管理 — 新しいサイトへの対応はルール追加だけで済みます。年齢確認のあるサイトには R-18 の印が付きます。"
                    ) {
                        ForEach(presets, id: \.self) { domain in
                            NavigationLink {
                                PresetEditorView(domain: domain, siteName: SiteNames.name(for: domain))
                            } label: {
                                SettingRow(label: SiteNames.name(for: domain), detail: domain) {
                                    HStack(spacing: Spacing.s) {
                                        if over18.contains(domain) {
                                            Text("R-18")
                                                .font(AppFont.ui(10, weight: .bold))
                                                .foregroundStyle(AppPalette.ember)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .strokeBorder(AppPalette.ember.opacity(0.5), lineWidth: 1)
                                                )
                                        }
                                        Image(systemName: "chevron.right")
                                            .font(AppFont.ui(11, weight: .semibold))
                                            .foregroundStyle(AppPalette.inkFaint)
                                    }
                                }
                            }
                            .buttonStyle(PressableButtonStyle())
                            RowDivider()
                        }
                    }

                    sectionCard(
                        title: "クッキー",
                        footer: "年齢確認(R-18)サイトのログイン状態は、ブラウザで確認済みのクッキーを貼り付けて利用します。"
                    ) {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            PaperField(placeholder: "ドメイン(例: syosetu.com)", text: $cookieDomain, mono: true)
                            PaperField(placeholder: "name=value; name2=value2", text: $cookieValue, mono: true)
                            EmberButton(title: "クッキーを保存") {
                                let d = cookieDomain.trimmingCharacters(in: .whitespaces)
                                let v = cookieValue.trimmingCharacters(in: .whitespaces)
                                guard !d.isEmpty, !v.isEmpty else { return }
                                core.setDomainCookie(domain: d, cookie: v)
                                Haptics.success()
                                statusText = "\(d) のクッキーを保存しました"
                            }
                        }
                        .padding(.vertical, Spacing.s)
                    }

                    sectionCard(title: "読書の初期設定") {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text("テーマ")
                                .font(AppFont.ui(15))
                                .foregroundStyle(AppPalette.ink)
                            SegmentTabs(
                                titles: BookTheme.allCases.map(\.label),
                                selection: Binding(
                                    get: { max(BookTheme.allCases.firstIndex(of: BookTheme(rawValue: readerTheme) ?? .paper) ?? 0, 0) },
                                    set: {
                                        readerTheme = BookTheme.allCases[$0].rawValue
                                    }
                                )
                            )
                        }
                        .padding(.vertical, Spacing.s)
                        RowDivider()
                        StepperRow(label: "文字サイズ", value: $readerFontSize, range: 14...28)
                        RowDivider()
                        StepperRow(label: "行間", value: $readerLineSpacing, range: 0...16)
                    }

                    if let statusText {
                        Text(statusText)
                            .font(AppFont.ui(13))
                            .foregroundStyle(AppPalette.inkSoft)
                            .padding(.horizontal, Spacing.xs)
                    }

                    HStack {
                        Text("Bookmarks 2.0(C core)")
                            .font(AppFont.ui(12))
                            .foregroundStyle(AppPalette.inkFaint)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.xs)
                    .padding(.bottom, Spacing.xl)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, Spacing.l)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task {
                presets = (try? await core.listPresets()) ?? []
                var marks: Set<String> = []
                for domain in presets {
                    if let yaml = try? await core.loadPreset(domain: domain),
                       yaml.contains("confirm_over18") && yaml.contains("true") {
                        marks.insert(domain)
                    }
                }
                over18 = marks
            }
        }
    }

    private func sectionCard(
        title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(AppFont.serif(17, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.s)
            content()
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.s)
            if let footer {
                Text(footer)
                    .font(AppFont.ui(12))
                    .foregroundStyle(AppPalette.inkFaint)
                    .lineSpacing(2)
                    .padding(.horizontal, Spacing.l)
                    .padding(.bottom, Spacing.l)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperBackground())
    }
}

/// サイト名の表示用マップ(未知のドメインはドメイン名のまま)。
enum SiteNames {
    private static let table: [(match: String, name: String)] = [
        ("novel18.syosetu", "小説家になろう(R-18)"),
        ("syosetu.com", "小説家になろう"),
        ("kakuyomu.jp", "カクヨム"),
        ("h.syosetu.org", "ハーメルン(R-18)"),
        ("syosetu.org", "ハーメルン"),
        ("akatsuki-novels.com", "暁"),
        ("novelup.plus", "ノベルアップ＋"),
        ("daysneo.com", "DAYS NEO"),
        ("alphapolis.co.jp", "アルファポリス"),
        ("estar.jp", "エスタ"),
        ("aozora.gr.jp", "青空文庫"),
        ("novema", "ノベマ"),
        ("berrys", "ベリーズ"),
        ("no-ichigo", "ノイチゴ"),
        ("solispia", "ソリスピア"),
        ("suteki", "すてきなライブラリー"),
        ("neopage", "ネオページ"),
        ("monogatary", "モノガタリ"),
    ]

    static func name(for domain: String) -> String {
        for entry in table where domain.contains(entry.match) {
            return entry.name
        }
        return domain
    }
}

/// サイトの抽出ルール(YAML)詳細。
struct PresetEditorView: View {
    @Environment(CoreClient.self) private var core: CoreClient
    let domain: String
    var siteName: String = ""

    @State private var yaml = ""
    @State private var editorStatus: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(siteName.isEmpty ? domain : siteName)
                        .font(AppFont.serif(20, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    InfoChip(text: domain)
                    Text("このサイトの目次・本文の抽出ルールです。新しいサイトはこのルールを追加するだけで対応でき、アプリ本体の変更は不要です。")
                        .font(AppFont.ui(13))
                        .foregroundStyle(AppPalette.inkSoft)
                        .lineSpacing(3)
                }
                .padding(Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PaperBackground())

                HStack {
                    Text("抽出ルール")
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(AppPalette.inkSoft)
                    Spacer()
                    Text("\(yaml.split(separator: "\n", omittingEmptySubsequences: false).count) 行")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkFaint)
                        .monospacedDigit()
                }

                TextEditor(text: $yaml)
                    .font(AppFont.ui(12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 360)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .fill(Color(hex: 0x1C1B19))
                    )
                    .colorScheme(.dark)

                if let editorStatus {
                    Text(editorStatus)
                        .font(AppFont.ui(13))
                        .foregroundStyle(AppPalette.inkSoft)
                }

                HStack(spacing: Spacing.m) {
                    QuietButton(title: "保存", systemImage: "square.and.arrow.down") {
                        Task {
                            do {
                                try await core.savePreset(domain: domain, yaml: yaml)
                                Haptics.success()
                                editorStatus = "保存しました"
                            } catch {
                                editorStatus = error.localizedDescription
                            }
                        }
                    }
                    QuietButton(title: "削除", systemImage: "trash", tint: AppPalette.emberDeep) {
                        Task {
                            do {
                                try await core.deletePreset(domain: domain)
                                Haptics.success()
                                editorStatus = "削除しました"
                            } catch {
                                editorStatus = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .padding(Spacing.l)
        }
        .background(AppPalette.canvas.ignoresSafeArea())
        .navigationTitle(siteName.isEmpty ? domain : siteName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            yaml = (try? await core.loadPreset(domain: domain)) ?? ""
        }
    }
}
