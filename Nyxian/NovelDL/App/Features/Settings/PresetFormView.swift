import SwiftUI

/// フラットな `key: value` 形式のプリセット YAML を相互変換する(既知の共通キーのみ)。
enum PresetYAML {
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    static func serialize(_ fields: [String: String], order: [String]) -> String {
        var lines = [
            "# NovelDL 抽出ルール(site preset)",
            "# フォームで入力した内容がこの YAML として保存されます。",
            "",
        ]
        func append(_ key: String) {
            guard let value = fields[key], !value.isEmpty else { return }
            let needsQuote = value.contains(": ") || value.hasPrefix(" ")
            lines.append(needsQuote ? "\(key): \"\(value)\"" : "\(key): \(value)")
        }
        var seen = Set<String>()
        for key in order {
            seen.insert(key)
            append(key)
        }
        // インポート由来の未知キーも失わないよう残す。
        for key in fields.keys.sorted() where !seen.contains(key) {
            append(key)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 新規作成用の雛形(全文を書かずに済むよう最小限を初期投入)。
    static func template() -> [String: String] {
        [
            "site_name": "",
            "site_id": "",
            "scheme": "https",
            "fetch_url_template": "$0",
            "list_fetch": "href=\"(https?://[^\\\"]+/%NOVELID%/[^\\\"]*)\"",
            "list_title": "class=\"title\"[^>]*>([^<]+)",
            "list_subtitle": "class=\"subtitle\"[^>]*>([^<]+)",
            "section_title": "<h2[^>]*>([^<]+)</h2>",
            "body": "<div[^>]*class=\"[^\\\"]*novel_honbun[^\\\"]*\"[^>]*>([\\s\\S]*?)</div>",
            "throttle_ms": "3000",
            "browser_fallback": "false",
            "confirm_over18": "false",
        ]
    }
}

/// サイト編集 = フォームで項目を埋めるだけ。上級者向けに全文 YAML も併設。
struct PresetFormView: View {
    @Environment(CoreClient.self) private var core: CoreClient
    @Environment(\.dismiss) private var dismiss

    let domain: String?
    /// インポートした YAML(あればこれを下書きとして開く)。
    var importedYAML: String? = nil

    @State private var fields: [String: String] = [:]
    @State private var showRaw = false
    @State private var rawText = ""
    @State private var r18Mode = 0
    @State private var message: String?

    private static let order: [String] = [
        "site_name", "site_id", "scheme", "fetch_url_template",
        "list_fetch", "list_title", "list_subtitle", "list_latest", "skip",
        "section_title", "body", "subupdate", "exclude_list_sections",
        "throttle_ms", "browser_fallback", "confirm_over18", "over18_cookie",
    ]

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    section("基本") {
                        fieldRow("site_name", "サイト名", "例: 小説家になろう")
                        fieldRow("site_id", "識別子", "例: syosetu / kakuyomu")
                        fieldRow("scheme", "接続方式", "http または https")
                        r18Row
                    }

                    section("一覧ページの抽出") {
                        fieldRow("fetch_url_template", "作品URLの作り方", "既定 $0(そのまま使用)")
                        fieldRow("list_fetch", "作品リンク", "href の正規表現。%NOVELID% が使えます")
                        fieldRow("list_title", "タイトル", "正規表現(1つ目の () が取得値)")
                        fieldRow("list_subtitle", "作者名", "正規表現")
                        fieldRow("list_latest", "最新話", "任意。正規表現")
                        fieldRow("skip", "除外リンク", "任意。目次除外に使う正規表現")
                        fieldRow("exclude_list_sections", "除外区分", "任意。例: 装飾,漫画")
                    }

                    section("本文ページの抽出") {
                        fieldRow("section_title", "話タイトル", "<h2> などの正規表現")
                        fieldRow("body", "本文", "本文ブロックを包む正規表現([\\s\\S]*? で対応)")
                        fieldRow("subupdate", "改稿マーク", "任意。改稿表示の正規表現")
                    }

                    section("アクセスの節度") {
                        fieldRow("throttle_ms", "アクセス間隔(ミリ秒)", "例: 3000")
                        toggleRow("browser_fallback", "ブラウザ経由の許可(WAF対策)")
                        fieldRow("over18_cookie", "年齢確認クッキー", "サイト側の仕組みに合わせた値(任意)")
                    }

                    section("上級設定(全文 YAML)") {
                        Toggle(isOn: $showRaw) {
                            Text("全文を直接編集する")
                                .font(AppFont.ui(14))
                                .foregroundStyle(AppPalette.ink)
                        }
                        .tint(AppPalette.ember)
                        if showRaw {
                            TextEditor(text: $rawText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(AppPalette.ink)
                                .frame(minHeight: 180)
                                .padding(Spacing.s)
                                .background(AppPalette.canvas)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(AppPalette.hairline, lineWidth: 1)
                                )
                                .onChange(of: rawText) { fields = PresetYAML.parse(rawText) }
                            Text("保存時、フォームの内容と本文のどちらか新しい内容が使われます。普段はフォームだけで完結します。")
                                .font(AppFont.ui(11))
                                .foregroundStyle(AppPalette.inkFaint)
                        }
                    }

                    if let message {
                        Text(message)
                            .font(AppFont.ui(12, weight: .medium))
                            .foregroundStyle(AppPalette.gold)
                    }

                    QuietButton(title: "保存", systemImage: "checkmark") {
                        save()
                    }
                    .padding(.bottom, Spacing.xl)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, Spacing.l)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: Spacing.m) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(AppFont.ui(16, weight: .semibold))
                            .foregroundStyle(AppPalette.ink)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(PressableButtonStyle())
                    Text(domain == nil ? "新しいサイト" : "サイトを編集")
                        .font(AppFont.serif(18, weight: .semibold))
                        .foregroundStyle(AppPalette.ink)
                    Spacer()
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, Spacing.s)
                .background(AppPalette.canvas)
            }
            .task { await load() }
    }

    private var r18Row: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("年齢区分")
                .font(AppFont.ui(12, weight: .semibold))
                .foregroundStyle(AppPalette.inkSoft)
            SegmentTabs(
                titles: ["全年齢", "R-18あり", "R-18専"],
                selection: $r18Mode
            )
            .onChange(of: r18Mode) { mode in
                fields["confirm_over18"] = mode == 0 ? "false" : "true"
            }
        }
        .padding(.vertical, Spacing.s)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(AppFont.serif(17, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .padding(.bottom, Spacing.s)
            VStack(spacing: 0) {
                content()
            }
            .background(PaperBackground())
        }
    }

    private func fieldRow(_ key: String, _ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppFont.ui(13, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
            Text(hint)
                .font(AppFont.ui(11))
                .foregroundStyle(AppPalette.inkFaint)
            PaperField(placeholder: hint, text: Binding(
                get: { fields[key] ?? "" },
                set: { fields[key] = $0 }
            ))
        }
        .padding(Spacing.m)
    }

    private func toggleRow(_ key: String, _ title: String) -> some View {
        SettingRow(label: title) {
            Button {
                fields[key] = (fields[key] == "true") ? "false" : "true"
                Haptics.tap()
            } label: {
                Text(fields[key] == "true" ? "ON" : "OFF")
                    .font(AppFont.ui(13, weight: .semibold))
                    .foregroundStyle(fields[key] == "true" ? .white : AppPalette.inkSoft)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Capsule().fill(fields[key] == "true" ? AppPalette.ember : AppPalette.track))
            }
            .buttonStyle(PressableButtonStyle(haptic: false))
        }
    }

    private func load() async {
        if let imported = importedYAML {
            fields = PresetYAML.parse(imported)
            rawText = imported
            message = "読み込みました。内容を確認して保存してください"
        } else if let domain, let yaml = try? await core.loadPreset(domain: domain) {
            fields = PresetYAML.parse(yaml)
            rawText = yaml
        } else {
            fields = PresetYAML.template()
            rawText = PresetYAML.serialize(fields, order: Self.order)
        }
        r18Mode = {
            if (fields["site_id"] ?? "").contains("novel18") { return 2 }
            return fields["confirm_over18"] == "true" ? 1 : 0
        }()
    }

    private func save() {
        Task {
            var store = fields
            if r18Mode == 2 {
                store["confirm_over18"] = "true"
            }
            if showRaw, !rawText.isEmpty, PresetYAML.parse(rawText) != fields {
                store = PresetYAML.parse(rawText)
            }
            let target = (store["site_id"] ?? domain ?? "new-site")
                .replacingOccurrences(of: " ", with: "-")
                .lowercased()
            let yaml = PresetYAML.serialize(store, order: Self.order)
            do {
                try await core.savePreset(domain: target, yaml: yaml)
                message = "保存しました(適用にはアプリを再起動してください)"
                Haptics.success()
            } catch {
                message = "保存に失敗: \(error.localizedDescription)"
            }
        }
    }
}
