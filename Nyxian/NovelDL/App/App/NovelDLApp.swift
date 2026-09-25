import SwiftUI

@main
struct NovelDLApp: App {
    private let core = CoreClient.shared

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environment(core)
                .task {
                    core.bootstrap()
                }
        }
    }
}
