import SwiftUI

/// 設定 — 取得間隔(アクセス制限対策)・プリセット・クッキー・読書初期値。
struct SettingsView: View {
    @Environment(CoreClient.self) private var core: CoreClient

    @AppStorage("downloadIntervalMs") private var intervalMs = 5000
    @AppStorage("browserFetchCommand") private var browserCommand = ""
    @AppStorage("readerTheme") private var readerTheme = BookTheme.paper.rawValue
    @AppStorage("readerFontSize") private var readerFontSize = 19.0
    @AppStorage("readerLineSpacing") private var readerLineSpacing = 6.0

    @State private var presets: [String] = []
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

                Section("解析プリセット") {
                    Text("抽出ルールは YAML で管理 — 新しいサイトはデータ追加だけで対応できます。")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkSoft)
                    ForEach(presets, id: \.self) { domain in
                        NavigationLink {
                            PresetEditorView(domain: domain)
                        } label: {
                            HStack {
                                Text(domain)
                                    .font(AppFont.ui(14, design: .monospaced))
                                    .foregroundStyle(AppPalette.ink)
                                Spacer()
                            }
                        }
                    }
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
                    Text("novel_core — YAML 駆動のマルチサイト取得エンジン。")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkSoft)
                }
            }
            .navigationTitle("設定")
            .task {
                presets = (try? await core.listPresets()) ?? []
            }
        }
    }
}

/// プリセット(YAML)ビューア/エディタ。
struct PresetEditorView: View {
    @Environment(CoreClient.self) private var core: CoreClient
    let domain: String

    @State private var yaml = ""
    @State private var editorStatus: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $yaml)
                    .font(AppFont.ui(12, design: .monospaced))
                    .frame(minHeight: 420)
                    .padding(10)
                    .background(CardBackground())
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
            .padding(Metrics.gutter)
        }
        .background(AppPalette.canvas.ignoresSafeArea())
        .navigationTitle(domain)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            yaml = (try? await core.loadPreset(domain: domain)) ?? ""
        }
    }
}
