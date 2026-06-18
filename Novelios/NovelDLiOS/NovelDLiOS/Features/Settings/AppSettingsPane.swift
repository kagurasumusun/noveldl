import SwiftUI

struct AppSettingsPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("解析エンジン", selection: $state.parserEngine) {
                    ForEach(ParserEngineChoice.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .pickerStyle(.segmented)

                Text(parserEngineDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("小説サイト解析")
            } footer: {
                Text("ドメインはサイトごとの既定パーサーを使います。Nokogiri / Legacy は互換性確認や一部サイトでの切り替えに使います。")
            }

            Section("プライベートブラウザ") {
                Toggle("広告ブロック", isOn: $state.browserAdBlockEnabled)
                Text("WebKitは非永続データストアで動作します。Cookieは端末の通常ブラウザストアに保存せず、ダウンロード連携用にアプリ内でのみ保持します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("YAMLプリセット") {
                NavigationLink {
                    YamlPresetManagerView()
                } label: {
                    Label("既存・新規 YAML を管理", systemImage: "doc.badge.gearshape")
                }
                Text("サイト YAML（統合）の確認、項目別編集、全文編集、保存前チェック、旧 WebNovel YAML の互換確認ができます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("リーダー表示") {
                Toggle("画像表示", isOn: $state.showImages)
                Toggle("ページ送りを右→左", isOn: $state.rtl)
                Toggle("フルスクリーン", isOn: $state.readerFullscreen)
                Toggle("ヘッダー/フッター表示", isOn: $state.readerChromeVisible)

                HStack {
                    Text("文字サイズ")
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
                Toggle("ダークテーマ", isOn: $state.readerDarkTheme)
                    .onChange(of: state.readerDarkTheme) { _, isDark in
                        if isDark {
                            state.bg = .black
                            state.fg = Color(red: 0.72, green: 0.72, blue: 0.72)
                        } else {
                            state.bg = Color(red: 0.94, green: 0.90, blue: 0.82)
                            state.fg = .black
                        }
                        state.refresh()
                        state.persistReaderSettings()
                    }
            }

            Section("本棚") {
                Button { state.refreshLibraryAndUpdateTocs() } label: {
                    Label("本棚と目次を再読み込み", systemImage: "arrow.clockwise")
                }
                if state.isRefreshingToc || !state.tocRefreshStatus.isEmpty {
                    Text(state.tocRefreshStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: state.browserAdBlockEnabled) { _, _ in state.persistBrowserSettings() }
        .onChange(of: state.showImages) { _, _ in state.refresh(); state.persistReaderSettings() }
        .onChange(of: state.rtl) { _, _ in state.refresh(); state.persistReaderSettings() }
        .onChange(of: state.readerFullscreen) { _, _ in state.persistReaderSettings() }
        .onChange(of: state.readerChromeVisible) { _, _ in state.persistReaderSettings() }
        .onChange(of: state.fontSize) { _, _ in state.refresh(); state.persistReaderSettings() }
        .onChange(of: state.lineSpacing) { _, _ in state.refresh(); state.persistReaderSettings() }
        .onChange(of: state.readerMargin) { _, _ in state.refresh(); state.persistReaderSettings() }
        .onChange(of: state.readerBrightness) { _, _ in state.refresh(); state.persistReaderSettings() }
        .onChange(of: state.bg) { _, _ in state.refresh(); state.persistReaderSettings() }
        .onChange(of: state.fg) { _, _ in state.refresh(); state.persistReaderSettings() }
    }

    private var parserEngineDescription: String {
        switch state.parserEngine {
        case .domain:
            return "サイトのドメインに合わせて最適なパーサーを自動選択します。通常はこちらを使ってください。"
        case .nokogiri:
            return "Nokogiri互換パーサーを優先します。ドメイン既定でうまく取得できない場合に試してください。"
        case .legacy:
            return "旧互換パーサーを優先します。古いサイト定義や互換性確認用です。"
        }
    }
}
