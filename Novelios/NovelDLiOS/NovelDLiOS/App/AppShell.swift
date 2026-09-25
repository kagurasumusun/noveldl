import SwiftUI

/// シェル — 静かな下部タブ、行動色は控えめに。
struct AppShell: View {
    enum Tab: Hashable { case library, discover, activity, settings }

    @Environment(CoreClient.self) private var core: CoreClient
    @State private var tab: Tab = .library

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem {
                    Label("本棚", systemImage: "books.vertical")
                }
                .tag(Tab.library)

            DiscoverView()
                .tabItem {
                    Label("さがす", systemImage: "sparkle.magnifyingglass")
                }
                .tag(Tab.discover)

            QueueView()
                .tabItem {
                    Label("ダウンロード", systemImage: "arrow.down.circle")
                }
                .tag(Tab.activity)

            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
        .tint(AppPalette.ember)
    }
}
