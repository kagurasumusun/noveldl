import SwiftUI

struct YamlPresetManagerView: View {
    @StateObject private var store = YamlPresetStore(rootDir: AppState.docsDir)
    @State private var activeDraft: YamlPresetDraft?
    @State private var errorMessage = ""

    var body: some View {
        presetList
            .navigationTitle("YAML 管理")
            .toolbar { toolbarContent }
            .alert("YAML 管理エラー", isPresented: errorPresentedBinding) {
                Button("OK", role: .cancel) { errorMessage = "" }
            } message: {
                Text(errorMessage)
            }
            .sheet(item: $activeDraft) { draft in
                NavigationStack {
                    YamlPresetEditorView(
                        draft: draft,
                        onSave: saveDraft,
                        onDelete: deleteUserPreset,
                        onCancel: { activeDraft = nil }
                    )
                }
            }
    }

    private var presetList: some View {
        List {
            statusSection
            ForEach(YamlPresetKind.allCases) { kind in
                presetSection(for: kind)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if !store.statusMessage.isEmpty {
            Section {
                Text(store.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { activeDraft = .blank() } label: {
                Label("追加", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { store.reload() } label: {
                Label("再読み込み", systemImage: "arrow.clockwise")
            }
        }
    }

    private var errorPresentedBinding: Binding<Bool> {
        Binding(
            get: { !errorMessage.isEmpty },
            set: { if !$0 { errorMessage = "" } }
        )
    }

    private func presets(for kind: YamlPresetKind) -> [YamlPresetSummary] {
        store.presets.filter { $0.kind == kind }
    }

    @ViewBuilder
    private func presetSection(for kind: YamlPresetKind) -> some View {
        let items = presets(for: kind)
        Section {
            if items.isEmpty {
                Text("まだ YAML がありません")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { preset in
                    Button { activeDraft = store.draft(for: preset) } label: {
                        presetRow(preset)
                    }
                }
            }
        } header: {
            Text(kind.title)
        } footer: {
            if kind == .parser {
                Text("通常はこちらだけ編集します。取得設定と横断検索の所属サイト（webnovels_site）を同じ YAML にまとめます。")
            } else {
                Text("互換用の旧経路です。新規編集はサイト YAML（統合）へ移してください。")
            }
        }
    }

    private func presetRow(_ preset: YamlPresetSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(preset.hasUserPreset ? .orange : .blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.domain)
                    .font(.headline)
                Text(preset.sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func saveDraft(_ draft: YamlPresetDraft) {
        do {
            _ = try store.save(draft)
            activeDraft = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteUserPreset(_ summary: YamlPresetSummary) {
        do {
            try store.deleteUserPreset(summary)
            activeDraft = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct YamlPresetEditorView: View {
    @State private var draft: YamlPresetDraft
    @State private var structuredDraft: StructuredYamlDraft
    @State private var editMode: YamlEditMode = .guided
    @State private var testUrl = ""
    @State private var testResult: NovelCoreBridge.SiteTestResult?
    @State private var testError = ""
    @State private var isTesting = false
    let onSave: (YamlPresetDraft) -> Void
    let onDelete: (YamlPresetSummary) -> Void
    let onCancel: () -> Void

    init(
        draft: YamlPresetDraft,
        onSave: @escaping (YamlPresetDraft) -> Void,
        onDelete: @escaping (YamlPresetSummary) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        _structuredDraft = State(initialValue: StructuredYamlDraft(yaml: draft.yaml, kind: draft.kind))
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        editorForm
            .navigationTitle(draft.domain.isEmpty ? "新規 YAML" : draft.domain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
    }

    private var editorForm: some View {
        Form {
            destinationSection
            editingModeSection
            switch editMode {
            case .guided:
                basicInfoSection
                metadataSection
                connectionSection
                tocSection
                bodySection
                testSection
                yamlHealthSection
            case .raw:
                yamlQuickInsertSection
                yamlSection
                yamlHealthSection
            case .preview:
                yamlPreviewSection
                yamlHealthSection
            }
            deleteSection
        }
    }

    private var editingModeSection: some View {
        Section {
            Picker("入力方法", selection: $editMode) {
                ForEach(YamlEditMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("普段は項目別、複雑なキーだけ全文編集、保存前は要約で確認する構成にしました。スマホで長い YAML を直接編集し続けない設計です。")
        }
    }

    private var destinationSection: some View {
        Section {
            Picker("種類", selection: $draft.kind) {
                ForEach(YamlPresetKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            TextField("example.com", text: $draft.domain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                structuredDraft = StructuredYamlDraft.template(kind: draft.kind, domain: draft.domain)
                draft.yaml = structuredDraft.yaml(kind: draft.kind, domain: draft.domain)
            } label: {
                Label("項目別テンプレートを作成", systemImage: "list.bullet.rectangle")
            }
        } header: {
            Text("保存先")
        } footer: {
            Text("保存すると Documents/presets 配下のユーザー YAML として反映されます。内蔵 YAML は破壊せず、同名ドメインはユーザー定義で上書きします。")
        }
    }

    private var basicInfoSection: some View {
        Section {
            TextField("サイト名", text: structuredBinding(\.name))
            TextField("トップURL (https://example.com)", text: structuredBinding(\.topURL))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Text("継承 (extends)")
                Spacer()
                TextField("common/syosetu_2024", text: structuredBinding(\.extends))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            TextField("サイトグループ (webnovels_site)", text: structuredBinding(\.webnovelsSite))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("文字コード", text: structuredBinding(\.encoding))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("基本情報・継承")
        } footer: {
            Text("extends に共通定義を指定すると、その設定を引き継げます。なろう系なら common/syosetu_2024 など。")
        }
    }

    private var metadataSection: some View {
        Section {
            TextField("タイトル抽出 CSS / JSONPath", text: structuredBinding(\.titleSelector))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("作者抽出 CSS / JSONPath", text: structuredBinding(\.authorSelector))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("あらすじ抽出 CSS / JSONPath", text: structuredBinding(\.storySelector))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("目次URLパターン", text: structuredBinding(\.tocUrlPattern))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("作品情報URLパターン", text: structuredBinding(\.novelInfoUrlPattern))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("メタデータ・URLパターン")
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("アクセスプロファイル (profile)", text: structuredBinding(\.accessProfile))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Toggle("18歳以上確認 (confirm_over18)", isOn: structuredBinding(\.confirmOver18))

            NavigationLink {
                cookieEditor
            } label: {
                HStack {
                    Text("カスタムCookie")
                    Spacer()
                    Text("\(structuredDraft.cookies.count) 件").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("接続設定")
        }
    }

    private var cookieEditor: some View {
        Form {
            Section {
                ForEach(Array(structuredDraft.cookies.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key).font(.caption).bold()
                        Spacer()
                        TextField("値", text: cookieBinding(for: key))
                            .multilineTextAlignment(.trailing)
                        Button(role: .destructive) {
                            var cookies = structuredDraft.cookies
                            cookies.removeValue(forKey: key)
                            structuredDraft.cookies = cookies
                            draft.yaml = structuredDraft.yaml(kind: draft.kind, domain: draft.domain)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                    }
                }

                Button {
                    var cookies = structuredDraft.cookies
                    cookies["new_cookie_\(cookies.count + 1)"] = ""
                    structuredDraft.cookies = cookies
                } label: {
                    Label("Cookieを追加", systemImage: "plus")
                }
            } header: {
                Text("Cookie一覧")
            } footer: {
                Text("特定のサイトで必要な Cookie を個別に設定します。")
            }
        }
        .navigationTitle("Cookie編集")
    }

    private func cookieBinding(for key: String) -> Binding<String> {
        Binding(
            get: { structuredDraft.cookies[key] ?? "" },
            set: { newValue in
                structuredDraft.cookies[key] = newValue
                draft.yaml = structuredDraft.yaml(kind: draft.kind, domain: draft.domain)
            }
        )
    }

    private var tocSection: some View {
        Section {
            Picker("目次ソース", selection: structuredBinding(\.tocSourceKind)) {
                ForEach(StructuredYamlDraft.TocSourceKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            TextField("行/リンクセレクタ・script セレクタ・$", text: structuredBinding(\.tocSelector))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("サブタイトル CSS / JSONPath", text: structuredBinding(\.tocTitle))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("本文URL CSS / JSONPath", text: structuredBinding(\.tocHref))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("URL許可パターン", text: structuredBinding(\.tocHrefPattern))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("API配列 JSONPath", text: structuredBinding(\.tocListPath))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("目次")
        } footer: {
            Text("HTML は selector、埋め込み JSON は json、API レスポンス全体は selector に $ を指定します。")
        }
    }

    private var bodySection: some View {
        Section {
            Picker("本文抽出", selection: structuredBinding(\.bodySourceKind)) {
                ForEach(StructuredYamlDraft.BodySourceKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            TextField("本文 CSS / 正規表現 / JSONPath", text: structuredBinding(\.bodySelector))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("前書き CSS / JSONPath", text: structuredBinding(\.introductionSelector))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("後書き CSS / JSONPath", text: structuredBinding(\.postscriptSelector))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("本文")
        } footer: {
            Text("入力欄を編集すると下の詳細 YAML に反映されます。複雑な設定だけ詳細 YAML で直接調整してください。")
        }
    }

    private var testSection: some View {
        Section {
            TextField("テスト用URL", text: $testUrl)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                runTest()
            } label: {
                if isTesting {
                    ProgressView().padding(.trailing, 4)
                }
                Text("抽出テスト実行")
            }
            .disabled(isTesting || testUrl.isEmpty)

            if let result = testResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("タイトル: \(result.title)").font(.subheadline)
                    Text("作者: \(result.author)").font(.subheadline)
                    Text("エピソード数: \(result.episode_count)").font(.subheadline)
                    if let first = result.first_episode_title {
                        Text("第一話: \(first)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if !testError.isEmpty {
                Text(testError).foregroundStyle(.red).font(.caption)
            }
        } header: {
            Text("抽出テスト")
        } footer: {
            Text("現在の設定（未保存でもOK）を使って、指定したURLから情報を正しく取得できるか試せます。")
        }
    }

    private func runTest() {
        isTesting = true
        testError = ""
        testResult = nil

        let currentYaml = structuredDraft.yaml(kind: draft.kind, domain: draft.domain)
        let url = testUrl

        Task {
            do {
                let res = try await NovelCoreBridge.callTestSiteDefinition(url: url, yaml: currentYaml)
                await MainActor.run {
                    self.testResult = res
                    self.isTesting = false
                }
            } catch {
                await MainActor.run {
                    self.testError = error.localizedDescription
                    self.isTesting = false
                }
            }
        }
    }

    private var yamlSection: some View {
        Section {
            TextEditor(text: $draft.yaml)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .frame(minHeight: 360)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: draft.yaml) { _, newValue in
                    structuredDraft = StructuredYamlDraft(yaml: newValue, kind: draft.kind)
                }
        } header: {
            Text("全文 YAML")
        } footer: {
            Text("長文編集はこのタブだけに分離しました。行数: \(yamlLineCount)、文字数: \(draft.yaml.count)")
        }
    }

    private var yamlQuickInsertSection: some View {
        Section("クイック挿入") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    quickButton(" なろう系", value: "extends: common/syosetu_2024\nname: \"\"")
                    quickButton(" カクヨム", value: "extends: common/kakuyomu_jp\nname: \"\"")
                    quickButton(" 汎用(HTML)", value: "extends: common/access_browser_fallback\nname: \"\"")
                    quickButton(" JSON API", value: "toc_sources:\n  - source: json\n    selector: \"\"")
                }
            }
        }
    }

    private func quickButton(_ title: String, value: String) -> some View {
        Button(title) {
            draft.yaml = value + "\n" + draft.yaml
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var yamlPreviewSection: some View {
        Section("生成 YAML プレビュー") {
            Text(draft.yaml)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var yamlHealthSection: some View {
        Section("保存前チェック") {
            ForEach(yamlDiagnostics, id: \.self) { diagnostic in
                Label(diagnostic.message, systemImage: diagnostic.icon)
                    .foregroundStyle(diagnostic.isWarning ? .orange : .green)
            }
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        if let summary = draft.existingSummary, summary.hasUserPreset {
            Section {
                Button(role: .destructive) {
                    onDelete(summary)
                } label: {
                    Label("ユーザー定義を削除", systemImage: "trash")
                }
            } footer: {
                Text(deleteFooterText(for: summary))
            }
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("キャンセル") { onCancel() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("保存") { onSave(draft) }
        }
    }

    private func structuredBinding<Value>(_ keyPath: WritableKeyPath<StructuredYamlDraft, Value>) -> Binding<Value> {
        Binding(
            get: { structuredDraft[keyPath: keyPath] },
            set: { newValue in
                structuredDraft[keyPath: keyPath] = newValue
                draft.yaml = structuredDraft.yaml(kind: draft.kind, domain: draft.domain)
            }
        )
    }

    private var yamlLineCount: Int {
        max(1, draft.yaml.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private var yamlDiagnostics: [YamlDiagnostic] {
        var diagnostics: [YamlDiagnostic] = []
        diagnostics.append(YamlDiagnostic(message: "YAML は \(yamlLineCount) 行 / \(draft.yaml.count) 文字です", isWarning: false))
        if draft.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(YamlDiagnostic(message: "保存先ドメインが未入力です", isWarning: true))
        }
        if yamlScalarSummary("domain") == nil {
            diagnostics.append(YamlDiagnostic(message: "domain キーが見つかりません", isWarning: true))
        }
        if draft.kind == .parser, yamlScalarSummary("webnovels_site") == nil {
            diagnostics.append(YamlDiagnostic(message: "横断検索に使う webnovels_site が未設定です", isWarning: true))
        }
        if draft.yaml.contains("\t") {
            diagnostics.append(YamlDiagnostic(message: "タブ文字があります。YAML ではスペース推奨です", isWarning: true))
        }
        if diagnostics.count == 1 {
            diagnostics.append(YamlDiagnostic(message: "主要項目は入力済みです", isWarning: false))
        }
        return diagnostics
    }

    private func yamlScalarSummary(_ key: String) -> String? {
        StructuredYamlDraft.scalar(for: key, in: draft.yaml)
    }

    private func deleteFooterText(for summary: YamlPresetSummary) -> String {
        summary.hasBundledPreset
            ? "内蔵 YAML は残り、ユーザー編集だけを削除します。"
            : "ユーザー追加 YAML ファイルを削除します。"
    }
}


private enum YamlEditMode: String, CaseIterable, Identifiable {
    case guided
    case raw
    case preview

    var id: String { rawValue }
    var title: String {
        switch self {
        case .guided: return "項目別"
        case .raw: return "全文"
        case .preview: return "確認"
        }
    }
}

private struct YamlDiagnostic: Hashable {
    let message: String
    let isWarning: Bool

    var icon: String { isWarning ? "exclamationmark.triangle" : "checkmark.circle" }
}

private struct StructuredYamlDraft: Equatable {
    enum TocSourceKind: String, CaseIterable, Identifiable {
        case selector
        case json
        case regex

        var id: String { rawValue }
        var title: String {
            switch self {
            case .selector: return "HTML セレクタ"
            case .json: return "JSON / API"
            case .regex: return "正規表現"
            }
        }
    }

    enum BodySourceKind: String, CaseIterable, Identifiable {
        case selector
        case json
        case regex

        var id: String { rawValue }
        var title: String {
            switch self {
            case .selector: return "HTML セレクタ"
            case .json: return "JSONPath"
            case .regex: return "正規表現"
            }
        }
    }

    var name = ""
    var topURL = ""
    var encoding = "UTF-8"
    var extends = ""
    var webnovelsSite = ""
    var confirmOver18 = false
    var tocUrlPattern = ""
    var novelInfoUrlPattern = ""
    var accessProfile = ""
    var cookies: [String: String] = [:]

    var titleSelector = ""
    var authorSelector = ""
    var storySelector = ""
    var tocSourceKind: TocSourceKind = .selector
    var tocSelector = ""
    var tocTitle = ""
    var tocHref = ""
    var tocHrefPattern = ""
    var tocListPath = ""
    var bodySourceKind: BodySourceKind = .selector
    var bodySelector = ""
    var introductionSelector = ""
    var postscriptSelector = ""

    init() {}

    init(yaml: String, kind: YamlPresetKind) {
        self = .template(kind: kind, domain: Self.scalar(for: "domain", in: yaml) ?? "")
        name = Self.scalar(for: "name", in: yaml) ?? name
        topURL = Self.scalar(for: "top_url", in: yaml) ?? topURL
        encoding = Self.scalar(for: "encoding", in: yaml) ?? encoding
        extends = Self.scalar(for: "extends", in: yaml) ?? ""
        webnovelsSite = Self.scalar(for: "webnovels_site", in: yaml) ?? ""
        confirmOver18 = (Self.scalar(for: "confirm_over18", in: yaml) == "yes")
        tocUrlPattern = Self.scalar(for: "toc_url_pattern", in: yaml) ?? ""
        novelInfoUrlPattern = Self.scalar(for: "novel_info_url_pattern", in: yaml) ?? ""
        accessProfile = Self.nestedScalar(parent: "access", key: "profile", in: yaml) ?? ""
        cookies = Self.parseCookies(in: yaml)

        titleSelector = Self.nestedScalar(parent: "novel_info_selectors", key: "title", in: yaml) ?? titleSelector
        authorSelector = Self.nestedScalar(parent: "novel_info_selectors", key: "author", in: yaml) ?? authorSelector
        storySelector = Self.nestedScalar(parent: "novel_info_selectors", key: "story", in: yaml) ?? storySelector
        if yaml.contains("source: json") { tocSourceKind = .json }
        if yaml.contains("source: regex") { tocSourceKind = .regex }
        tocSelector = Self.scalarNear(key: "selector", after: "toc_sources:", in: yaml) ?? tocSelector
        tocTitle = Self.scalarNear(key: tocSourceKind == .json ? "title_path" : "subtitle", after: tocSourceKind == .json ? "toc_sources:" : "item_selectors:", in: yaml) ?? tocTitle
        tocHref = Self.scalarNear(key: tocSourceKind == .json ? "href_path" : "href", after: tocSourceKind == .json ? "toc_sources:" : "item_selectors:", in: yaml) ?? tocHref
        tocHrefPattern = Self.scalarNear(key: "href_pattern", after: "toc_sources:", in: yaml) ?? tocHrefPattern
        tocListPath = Self.scalarNear(key: "list_path", after: "toc_sources:", in: yaml) ?? tocListPath
        if yaml.contains("json_path:") { bodySourceKind = .json }
        if yaml.contains("pattern:") { bodySourceKind = .regex }
        bodySelector = Self.scalarNear(key: bodySourceKind == .json ? "json_path" : bodySourceKind == .regex ? "pattern" : "selector", after: "body_selectors:", in: yaml) ?? bodySelector
        introductionSelector = Self.scalarNear(key: "selector", after: "introduction_selectors:", in: yaml) ?? introductionSelector
        postscriptSelector = Self.scalarNear(key: "selector", after: "postscript_selectors:", in: yaml) ?? postscriptSelector
    }

    static func template(kind: YamlPresetKind, domain: String) -> StructuredYamlDraft {
        var draft = StructuredYamlDraft()
        draft.name = domain.isEmpty ? "新規サイト" : domain
        draft.topURL = domain.isEmpty ? "https://example.com" : "https://\(domain)"
        draft.tocSelector = "li.episode"
        draft.tocTitle = "a"
        draft.tocHref = "a::attr(href)"
        draft.tocHrefPattern = ".+"
        draft.bodySelector = "article.body"
        if kind == .webnovel {
            draft.tocSourceKind = .regex
            draft.bodySourceKind = .regex
            draft.bodySelector = #"(?s)<article[^>]*>(?<body>.+?)</article>"#
        }
        return draft
    }

    func yaml(kind: YamlPresetKind, domain: String) -> String {
        var lines: [String] = []
        appendScalar("extends", extends, to: &lines)
        appendScalar("name", name, to: &lines)
        appendScalar("domain", domain, to: &lines)
        appendScalar("encoding", encoding, to: &lines)
        appendScalar("top_url", topURL, to: &lines)
        appendScalar("webnovels_site", webnovelsSite, to: &lines)
        if confirmOver18 { lines.append("confirm_over18: yes") }
        appendScalar("toc_url_pattern", tocUrlPattern, to: &lines)
        appendScalar("novel_info_url_pattern", novelInfoUrlPattern, to: &lines)

        if !accessProfile.isEmpty || !cookies.isEmpty {
            lines.append("access:")
            if !accessProfile.isEmpty {
                appendScalar("  profile", accessProfile, to: &lines)
            }
            if !cookies.isEmpty {
                lines.append("  cookies:")
                for (key, value) in cookies.sorted(by: { $0.key < $1.key }) {
                    lines.append("    \(key): \(Self.quoted(value))")
                }
            }
        }
        lines.append("")
        if !titleSelector.isEmpty || !authorSelector.isEmpty || !storySelector.isEmpty {
            lines.append("novel_info_selectors:")
            appendScalar("  title", titleSelector, to: &lines)
            appendScalar("  author", authorSelector, to: &lines)
            appendScalar("  story", storySelector, to: &lines)
            lines.append("")
        }
        lines.append("toc_sources:")
        switch tocSourceKind {
        case .selector:
            lines.append("  - source: selector")
            appendScalar("    selector", tocSelector, to: &lines)
            appendScalar("    href_pattern", tocHrefPattern, to: &lines)
            lines.append("    item_selectors:")
            appendScalar("      subtitle", tocTitle.isEmpty ? "a" : tocTitle, to: &lines)
            appendScalar("      href", tocHref.isEmpty ? "a::attr(href)" : tocHref, to: &lines)
        case .json:
            lines.append("  - source: json")
            appendScalar("    selector", tocSelector.isEmpty ? "$" : tocSelector, to: &lines)
            appendScalar("    href_pattern", tocHrefPattern.isEmpty ? ".+" : tocHrefPattern, to: &lines)
            appendScalar("    list_path", tocListPath, to: &lines)
            appendScalar("    href_path", tocHref, to: &lines)
            appendScalar("    title_path", tocTitle, to: &lines)
            lines.append("    path_only: false")
        case .regex:
            lines.append("  - source: regex")
            appendScalar("    pattern", tocSelector, to: &lines)
            lines.append("    id_name: index")
            lines.append("    title_name: subtitle")
            appendScalar("    href_template", tocHref.isEmpty ? "{index}" : tocHref, to: &lines)
        }
        lines.append("")
        appendBodySection(name: "body_selectors", value: bodySelector, kind: bodySourceKind, lines: &lines)
        appendSelectorSection(name: "introduction_selectors", selector: introductionSelector, lines: &lines)
        appendSelectorSection(name: "postscript_selectors", selector: postscriptSelector, lines: &lines)
        if kind == .webnovel {
            lines.append("# 旧 webnovel 互換キーが必要な場合は、下の詳細 YAML に toc_url / subtitles / href 等を追記できます。")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func appendBodySection(name: String, value: String, kind: BodySourceKind, lines: inout [String]) {
        guard !value.isEmpty else { return }
        lines.append("\(name):")
        switch kind {
        case .selector:
            appendScalar("  - selector", value, to: &lines)
            lines.append("    extract: inner_html")
        case .json:
            appendScalar("  - json_path", value, to: &lines)
        case .regex:
            appendScalar("  - pattern", value, to: &lines)
            lines.append("    capture_name: body")
        }
        lines.append("")
    }

    private func appendSelectorSection(name: String, selector: String, lines: inout [String]) {
        guard !selector.isEmpty else { return }
        lines.append("\(name):")
        appendScalar("  - selector", selector, to: &lines)
        lines.append("    extract: inner_html")
        lines.append("")
    }

    private func appendScalar(_ key: String, _ value: String, to lines: inout [String]) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lines.append("\(key): \(Self.quoted(value))")
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func scalar(for key: String, in yaml: String) -> String? {
        scalarNear(key: key, after: nil, in: yaml)
    }

    private static func nestedScalar(parent: String, key: String, in yaml: String) -> String? {
        scalarNear(key: key, after: "\(parent):", in: yaml)
    }

    private static func scalarNear(key: String, after marker: String?, in yaml: String) -> String? {
        let source: String
        if let marker, let range = yaml.range(of: marker) {
            source = String(yaml[range.upperBound...])
        } else {
            source = yaml
        }
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"(?m)^\s*"# + escapedKey + #"\s*:\s*(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let valueRange = Range(match.range(at: 1), in: source) else {
            return nil
        }
        return unquote(String(source[valueRange]))
    }

    private static func unquote(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("\"") && result.hasSuffix("\"") || result.hasPrefix("'") && result.hasSuffix("'") {
            result.removeFirst()
            result.removeLast()
        }
        return result.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseCookies(in yaml: String) -> [String: String] {
        var cookies: [String: String] = [:]
        guard let range = yaml.range(of: "cookies:") else { return [:] }
        let tail = String(yaml[range.upperBound...])
        let lines = tail.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                cookies[parts[0]] = unquote(parts[1])
            } else if !line.hasPrefix(" ") && !line.isEmpty {
                break
            }
        }
        return cookies
    }
}
