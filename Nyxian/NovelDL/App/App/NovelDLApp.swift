import SwiftUI

@main
struct NovelDLApp: App {
    @State private var core = CoreClient.shared

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
