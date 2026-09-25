import SwiftUI

/// ダウンロード — 進行状況がひと目で分かる「活動」ページ。
struct QueueView: View {
    @Environment(CoreClient.self) private var core: CoreClient

    private var ratio: Double {
        guard core.progress.total > 0 else { return 0 }
        return Double(core.progress.done + core.progress.skipped) / Double(core.progress.total)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SectionBanner(
                        title: "ダウンロード",
                        subtitle: core.progress.running ? "取得中" : "待機中"
                    )

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(core.progress.running ? "ダウンロード中" : "待機中")
                                    .font(AppFont.serif(18, weight: .semibold))
                                    .foregroundStyle(AppPalette.ink)
                                if !core.progress.current.isEmpty {
                                    Text(core.progress.current)
                                        .font(AppFont.ui(13))
                                        .foregroundStyle(AppPalette.inkSoft)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text("\(core.progress.done)/\(core.progress.total)")
                                .font(AppFont.ui(16, weight: .semibold).monospacedDigit())
                                .foregroundStyle(AppPalette.ember)
                        }
                        ReadingRibbon(value: ratio)

                        HStack(spacing: 18) {
                            stat("取得", core.progress.done, AppPalette.ember)
                            stat("スキップ", core.progress.skipped, AppPalette.gold)
                            stat("失敗", core.progress.failed, AppPalette.emberDeep)
                        }

                        if core.progress.running {
                            QuietButton(title: "中止", systemImage: "xmark.circle") {
                                core.cancel()
                            }
                        }
                    }
                    .padding(16)
                    .background(CardBackground())

                    Text("サイトへの負荷軽減のため、話と話の間は設定の間隔(既定 5 秒)を空けて取得します。失敗した話は後続に影響せず、再実行で続きから取得されます。")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkSoft)
                        .lineSpacing(3)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
        }
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(AppFont.serif(22, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(AppPalette.inkSoft)
        }
    }
}
