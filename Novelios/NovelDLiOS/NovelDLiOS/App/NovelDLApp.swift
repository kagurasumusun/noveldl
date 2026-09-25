import SwiftUI

@main
struct NovelDLApp: App {
    private let core = CoreClient.shared

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environment(core)
                // アプリは「温かいダーク」の紙面デザインで統一している。
                // 端末がライトモードでもシート・キーボード・アラートなど
                // システム提供面だけ白くなるのを防ぐ。
                .preferredColorScheme(.dark)
                // スピナ等の既定色を煉瓦に揃える(既定の青が混ざらないように)。
                .tint(AppPalette.ember)
                .task {
                    core.bootstrap()
                }
        }
    }
}
