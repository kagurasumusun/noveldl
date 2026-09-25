import SwiftUI

/// 設定 — 取得とアクセス制限 / 対応サイト / クッキー / 読書初期値。
/// サイト管理は「サイト一覧 → 詳細(抽出ルール)」の書籍アプリらしい導線に。
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $intervalMs, in: 1000...30000, step: 500) {
                        LabeledContent("話と話の最小間隔") {
                            Text(intervalMs >= 1000 ? "\(intervalMs / 1000)秒 \(intervalMs % 1000)" : "\(intervalMs)ms")
                                .monospacedDigit()
                        }
                    }
                    .onChange(of: intervalMs) {
                        core.setDownloadInterval(ms: UInt32(intervalMs))
                    }
                    TextField("ブラウザ取得コマンド(対策ページ用)", text: $browserCommand)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(AppFont.ui(14, design: .monospaced))
                        .onChange(of: browserCommand) {
                            core.setBrowserFetch(command: browserCommand.isEmpty ? nil : browserCommand)
                        }
                } header: {
                    Text("取得とアクセス制限")
                } footer: {
                    Text("サイトに負荷をかけないよう、リクエスト間に必ず間隔を空けます(既定 5 秒)。429 応答時は 10 秒以上のバックオフで再試行します。大量に取得する場合も、この間隔が守られます。")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkSoft)
                        .lineSpacing(2)
                }

                Section {
                    ForEach(presets, id: \.self) { domain in
                        NavigationLink {
                            PresetEditorView(domain: domain, siteName: SiteNames.name(for: domain))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "book.closed")
                                    .font(AppFont.ui(15))
                                    .foregroundStyle(AppPalette.gold)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SiteNames.name(for: domain))
                                        .font(AppFont.ui(15, weight: .medium))
                                        .foregroundStyle(AppPalette.ink)
                                    Text(domain)
                                        .font(AppFont.ui(12, design: .monospaced))
                                        .foregroundStyle(AppPalette.inkFaint)
                                }
                                Spacer()
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
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("対応サイト")
                } footer: {
                    Text("抽出ルールはデータで管理 — 新しいサイトへの対応はルール追加だけで済みます。年齢確認のあるサイトには R-18 の印が付きます。")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkSoft)
                }

                Section {
                    TextField("ドメイン(例: syosetu.com)", text: $cookieDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(AppFont.ui(14, design: .monospaced))
                    TextField("name=value; name2=value2", text: $cookieValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(AppFont.ui(14, design: .monospaced))
                    Button("クッキーを保存") {
                        let d = cookieDomain.trimmingCharacters(in: .whitespaces)
                        let v = cookieValue.trimmingCharacters(in: .whitespaces)
                        guard !d.isEmpty, !v.isEmpty else { return }
                        core.setDomainCookie(domain: d, cookie: v)
                        statusText = "\(d) のクッキーを保存しました"
                    }
                } header: {
                    Text("クッキー")
                } footer: {
                    Text("年齢確認(R-18)サイトのログイン状態は、ブラウザで確認済みのクッキーを貼り付けて利用します。")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkSoft)
                }

                Section("読書の初期設定") {
                    Picker("テーマ", selection: $readerTheme) {
                        ForEach(BookTheme.allCases) { theme in
                            Text(theme.label).tag(theme.rawValue)
                        }
                    }
                    Stepper(value: $readerFontSize, in: 14...28) {
                        LabeledContent("文字サイズ") { Text("\(Int(readerFontSize))").monospacedDigit() }
                    }
                    Stepper(value: $readerLineSpacing, in: 0...16) {
                        LabeledContent("行間") { Text("\(Int(readerLineSpacing))").monospacedDigit() }
                    }
                }

                if let statusText {
                    Section {
                        Text(statusText)
                            .font(AppFont.ui(13))
                            .foregroundStyle(AppPalette.inkSoft)
                    }
                }

                Section {
                    LabeledContent("バージョン", value: "Bookmarks 2.0(C core)")
                } footer: {
                    Text("novel_core — データ駆動のマルチサイト取得エンジン。")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkSoft)
                }
            }
            .navigationTitle("設定")
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

/// サイトの抽出ルール(YAML)詳細 — 「データ駆動でサイト追加」の実体。
struct PresetEditorView: View {
    @Environment(CoreClient.self) private var core: CoreClient
    let domain: String
    var siteName: String = ""

    @State private var yaml = ""
    @State private var editorStatus: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(siteName.isEmpty ? domain : siteName)
                        .font(AppFont.serif(20, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    InfoChip(text: domain)
                    Text("このサイトの目次・本文の抽出ルールです。新しいサイトはこのルールを追加するだけで対応でき、アプリ本体の変更は不要です。")
                        .font(AppFont.ui(13))
                        .foregroundStyle(AppPalette.inkSoft)
                        .lineSpacing(3)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CardBackground())

                HStack {
                    Text("抽出ルール(YAML)")
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
                    .frame(minHeight: 380)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .fill(Color(hex: 0x1C1B19))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .strokeBorder(AppPalette.hairline, lineWidth: 1)
                    )
                    .colorScheme(.dark)

                if let editorStatus {
                    Text(editorStatus)
                        .font(AppFont.ui(13))
                        .foregroundStyle(AppPalette.inkSoft)
                }

                HStack(spacing: 10) {
                    QuietButton(title: "保存", systemImage: "square.and.arrow.down") {
                        Task {
                            do {
                                try await core.savePreset(domain: domain, yaml: yaml)
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
                                editorStatus = "削除しました"
                            } catch {
                                editorStatus = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .padding(16)
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
