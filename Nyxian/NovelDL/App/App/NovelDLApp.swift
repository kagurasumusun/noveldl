import SwiftUI

@main
struct NovelDLApp: App {
    private let core = CoreClient.shared

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(core)
                .task {
                    core.bootstrap()
                }
        }
    }
}
