import SwiftUI

/// 設定 — 「ユーザーに操作させるもの」を置かない。
/// 取得の節度・対応サイトの確認・情報のみ。パーサ・クッキー等はアプリ内部の仕事。
struct SettingsView: View {
    @Environment(CoreClient.self) private var core: CoreClient

    @AppStorage("downloadIntervalMs") private var intervalMs = 5000
    @State private var presets: [String] = []
    @State private var over18: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    SectionBanner(title: "設定")

                    sectionCard(
                        title: "取得の間隔",
                        footer: "サイトに負荷をかけないよう、話と話の間には必ず間隔を空けます。429 応答時は自動で待って再試行します。設定変更の必要はほとんどありません。"
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

                    sectionCard(
                        title: "対応サイト",
                        footer: "抽出ルールはアプリ内蔵のデータで管理され、新しいサイトへの対応はデータ更新だけで済みます。年齢確認のあるサイトには R-18 の印が付きます。"
                    ) {
                        ForEach(presets, id: \.self) { domain in
                            SettingRow(label: SiteNames.name(for: domain), detail: domain) {
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
                            RowDivider()
                        }
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
                guard presets.isEmpty else { return }
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
