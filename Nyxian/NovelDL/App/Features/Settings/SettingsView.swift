import SwiftUI
import UniformTypeIdentifiers

/// 設定 — 取得の間隔・対応サイト(分類表示)・情報。
/// サイトの追加/編集はフォーム式の YAML エディタ(項目を埋めるだけ)。
struct SettingsView: View {
    @Environment(CoreClient.self) private var core: CoreClient

    @AppStorage("downloadIntervalMs") private var intervalMs = 5000
    @State private var presets: [String] = []
    @State private var over18: Set<String> = []
    @State private var editTarget: String?
    @State private var showNewPreset = false
    @State private var showImporter = false
    @State private var importedDraft: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    SectionBanner(title: "設定")

                    sectionCard(
                        title: "取得の間隔",
                        footer: "話と話の間は必ず空けます。429 応答時は自動で待って再試行します。"
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
                    }

                    siteCatalog

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
            .navigationDestination(for: String.self) { domain in
                PresetFormView(domain: domain)
            }
            .sheet(isPresented: $showNewPreset) {
                PresetFormView(domain: nil)
            }
            .sheet(isPresented: Binding(
                get: { importedDraft != nil },
                set: { if !$0 { importedDraft = nil } }
            )) {
                PresetFormView(domain: nil, importedYAML: importedDraft)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "yml") ?? .plainText,
                    UTType(filenameExtension: "yaml") ?? .plainText,
                    .plainText,
                ],
                allowsMultipleSelection: false
            ) { result in
                Task { await importYAML(from: result) }
            }
            .onChange(of: showNewPreset) { shown in
                if !shown { Task { await refresh() } }
            }
            .onChange(of: importedDraft) { draft in
                if draft == nil { Task { await refresh() } }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        presets = (try? await core.listPresets()) ?? []
        var marks: Set<String> = []
        for domain in presets {
            if let yaml = try? await core.loadPreset(domain: domain) {
                let fields = PresetYAML.parse(yaml)
                if SiteCatalog.r18Kind(domain: domain, presetOver18: fields["confirm_over18"] == "true") > 0 {
                    marks.insert(domain)
                }
            }
        }
        over18 = marks
    }

    /// ファイルから YAML を読み込み、編集フォームを開く。
    private func importYAML(from result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return
        }
        importedDraft = text
    }

    // MARK: 対応サイト(分類)

    private var siteCatalog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("対応サイト")
                    .font(AppFont.serif(17, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                HStack(spacing: Spacing.l) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("YML読込", systemImage: "square.and.arrow.down")
                            .font(AppFont.ui(13, weight: .semibold))
                            .foregroundStyle(AppPalette.ember)
                    }
                    .buttonStyle(PressableButtonStyle(haptic: false))
                    Button {
                        showNewPreset = true
                    } label: {
                        Label("追加", systemImage: "plus")
                            .font(AppFont.ui(13, weight: .semibold))
                            .foregroundStyle(AppPalette.ember)
                    }
                    .buttonStyle(PressableButtonStyle(haptic: false))
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.l)
            .padding(.bottom, Spacing.s)

            ForEach(SiteCatalog.groups(of: presets), id: \.title) { group in
                Text(group.title)
                    .font(AppFont.ui(12, weight: .semibold))
                    .foregroundStyle(AppPalette.gold)
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.l)
                    .padding(.bottom, Spacing.xs)

                VStack(spacing: 0) {
                    ForEach(group.domains, id: \.self) { domain in
                        NavigationLink(value: domain) {
                            siteRow(domain)
                        }
                        .buttonStyle(PressableButtonStyle(haptic: false))
                        RowDivider(leading: Spacing.l)
                    }
                }
            }

            Text("新しいサイトの対応は「追加」からフォームで項目を埋めるだけです。全文を書く必要はありません。年齢区分はサイトの実態に合わせて表示します。")
                .font(AppFont.ui(12))
                .foregroundStyle(AppPalette.inkFaint)
                .lineSpacing(2)
                .padding(Spacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaperBackground())
    }

    private func siteRow(_ domain: String) -> some View {
        let kind = SiteCatalog.r18Kind(domain: domain, presetOver18: over18.contains(domain))
        return HStack(spacing: Spacing.m) {
            Text(SiteCatalog.monogram(domain))
                .font(AppFont.serif(15, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppPalette.canvas)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AppPalette.hairline, lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(SiteCatalog.name(for: domain))
                    .font(AppFont.ui(14, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(domain)
                    .font(AppFont.ui(11))
                    .foregroundStyle(AppPalette.inkFaint)
            }
            Spacer()
            Text(SiteCatalog.r18Label(kind))
                .font(AppFont.ui(10, weight: .bold))
                .foregroundStyle(kind == 0 ? AppPalette.inkFaint : AppPalette.ember)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(kind == 0 ? AppPalette.track : AppPalette.ember.opacity(0.15))
                )
            Image(systemName: "chevron.right")
                .font(AppFont.ui(10, weight: .semibold))
                .foregroundStyle(AppPalette.inkFaint)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func sectionCard<C: View>(
        title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> C
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

/// サイトの分類・名称・年齢区分(サイトの実態に合わせる)。
enum SiteCatalog {
    struct Group { let title: String; let domains: [String] }

    static let major = ["syosetu.com", "novel18.syosetu", "kakuyomu.jp", "syosetu.org", "alphapolis"]
    static let indie = ["akatsuki", "novelup", "daysneo", "estar", "neopage", "monogatary", "aozora"]
    static let label = ["novema", "berrys", "no-ichigo", "solispia", "suteki"]

    static func groups(of domains: [String]) -> [Group] {
        func match(_ d: String, _ keys: [String]) -> Bool {
            keys.contains { d.contains($0) }
        }
        let known = major + indie + label
        let majors = domains.filter { match($0, major) }
        let indies = domains.filter { match($0, indie) && !match($0, major) }
        let labels = domains.filter { match($0, label) && !match($0, major) && !match($0, indie) }
        let others = domains.filter { d in !known.contains { d.contains($0) } }
        var out: [Group] = []
        if !majors.isEmpty { out.append(Group(title: "大手", domains: majors)) }
        if !indies.isEmpty { out.append(Group(title: "創作・投稿", domains: indies)) }
        if !labels.isEmpty { out.append(Group(title: "レーベル・文芸", domains: labels)) }
        if !others.isEmpty { out.append(Group(title: "その他", domains: others)) }
        return out
    }

    private static let names: [(match: String, name: String)] = [
        ("novel18.syosetu", "小説家になろう(R-18)"),
        ("syosetu.com", "小説家になろう"),
        ("kakuyomu.jp", "カクヨム"),
        ("h.syosetu.org", "ハーメルン(R-18)"),
        ("syosetu.org", "ハーメルン"),
        ("akatsuki-novels", "暁"),
        ("novelup", "ノベルアップ＋"),
        ("daysneo", "DAYS NEO"),
        ("alphapolis", "アルファポリス"),
        ("estar", "エスタ"),
        ("aozora", "青空文庫"),
        ("novema", "ノベマ"),
        ("berrys", "ベリーズ"),
        ("no-ichigo", "ノイチゴ"),
        ("solispia", "ソリスピア"),
        ("suteki", "すてきなライブラリー"),
        ("neopage", "ネオページ"),
        ("monogatary", "モノガタリ"),
    ]

    static func name(for domain: String) -> String {
        for entry in names where domain.contains(entry.match) { return entry.name }
        return domain
    }

    static func monogram(_ domain: String) -> String {
        String(domain.prefix(2)).uppercased()
    }

    /// 0 = 全年齢 / 1 = R-18あり / 2 = R-18専。
    /// サイトの実態(既知の事実)を優先し、未知サイトのみプリセットの設定に従う。
    static func r18Kind(domain: String, presetOver18: Bool) -> Int {
        let d = domain.lowercased()
        if d.contains("novel18") { return 2 }
        // 既知の事実:これらのサイトに R-18 は存在しない/存在する
        if d.contains("kakuyomu") || d.contains("aozora") || d.contains("syosetu.com") { return 0 }
        if d.contains("syosetu.org") || d.contains("alphapolis") || d.contains("akatsuki") || d.contains("novelup") {
            return 1
        }
        return presetOver18 ? 1 : 0
    }

    static func r18Label(_ kind: Int) -> String {
        switch kind {
        case 2: return "R-18専"
        case 1: return "R-18あり"
        default: return "全年齢"
        }
    }
}
