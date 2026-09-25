import SwiftUI

/// ダウンロード — 進行がひと目で分かる「活動」面。
struct QueueView: View {
    @Environment(CoreClient.self) private var core: CoreClient

    private var ratio: Double {
        guard core.progress.total > 0 else { return 0 }
        return Double(core.progress.done + core.progress.skipped) / Double(core.progress.total)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    SectionBanner(
                        title: "FETCH",
                        subtitle: "取得キュー")

                    VStack(alignment: .leading, spacing: Spacing.l) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(core.progress.done)")
                                .font(AppFont.serif(38, weight: .semibold).monospacedDigit())
                                .foregroundStyle(AppPalette.ink)
                            Text("/ \(core.progress.total) 話")
                                .font(AppFont.ui(15))
                                .foregroundStyle(AppPalette.inkSoft)
                                .monospacedDigit()
                            Spacer()
                            Text("\(Int(ratio * 100))%")
                                .font(AppFont.ui(16, weight: .semibold).monospacedDigit())
                                .foregroundStyle(AppPalette.ember)
                        }

                        ReadingRibbon(value: ratio)

                        if !core.progress.current.isEmpty {
                            Text(core.progress.current)
                                .font(AppFont.ui(13))
                                .foregroundStyle(AppPalette.inkSoft)
                                .lineLimit(1)
                        }

                        RowDivider()
                        HStack(spacing: Spacing.xl) {
                            stat("取得", core.progress.done, AppPalette.ember)
                            stat("スキップ", core.progress.skipped, AppPalette.gold)
                            stat("失敗", core.progress.failed, AppPalette.emberDeep)
                            Spacer()
                        }
                        if core.progress.running {
                            QuietButton(title: "中止", systemImage: "xmark.circle") {
                                core.cancel()
                            }
                        }
                    }
                    .padding(Spacing.l)
                    .background(PaperBackground())

                    Text("サイトへの負荷軽減のため、話と話の間は設定の間隔(既定 5 秒)を空けて取得します。失敗した話は後続に影響せず、再実行で続きから取得されます。")
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkFaint)
                        .lineSpacing(3)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, Spacing.l)
                .padding(.bottom, 72)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(AppFont.serif(22, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(AppFont.ui(12, weight: .medium))
                .foregroundStyle(AppPalette.inkFaint)
        }
    }
}
