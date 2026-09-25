import SwiftUI

/// Activity — the download lane (Kindle "downloading" strip made a page).
struct QueueView: View {
    @Environment(CoreClient.self) private var core

    private var ratio: Double {
        guard core.progress.total > 0 else { return 0 }
        return Double(core.progress.done + core.progress.skipped) / Double(core.progress.total)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SectionBanner(title: "Activity", subtitle: "Downloads & updates")

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(core.progress.running ? "Downloading" : "Idle")
                                    .font(AppFont.serif(18, weight: .semibold))
                                if !core.progress.current.isEmpty {
                                    Text(core.progress.current)
                                        .font(AppFont.ui(12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text("\(core.progress.done)/\(core.progress.total)")
                                .font(AppFont.ui(14, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ReadingRibbon(value: ratio)

                        HStack(spacing: 18) {
                            stat("Saved", core.progress.done, AppPalette.ember)
                            stat("Skipped", core.progress.skipped, AppPalette.gold)
                            stat("Failed", core.progress.failed, .red.opacity(0.7))
                        }

                        if core.progress.running {
                            QuietButton(title: "Cancel", systemImage: "xmark.circle") {
                                core.cancel()
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius)
                            .fill(.white)
                            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
                    )

                    Text("Tip — downloads skip episodes whose body is unchanged since the last pass.")
                        .font(AppFont.ui(11))
                        .foregroundStyle(.secondary)
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
            Text(label)
                .font(AppFont.ui(11))
                .foregroundStyle(.secondary)
        }
    }
}
