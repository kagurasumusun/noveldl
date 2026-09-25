import SwiftUI

/// Kobo-style shell: quiet chrome, one ember accent, four destinations.
struct AppShell: View {
    enum Tab: Hashable { case library, discover, activity, settings }

    @EnvironmentObject private var core
    @State private var tab: Tab = .library

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem {
                    Label("Shelf", systemImage: "books.vertical")
                }
                .tag(Tab.library)

            DiscoverView()
                .tabItem {
                    Label("Discover", systemImage: "sparkle.magnifyingglass")
                }
                .tag(Tab.discover)

            QueueView()
                .tabItem {
                    Label("Activity", systemImage: "arrow.down.circle")
                }
                .tag(Tab.activity)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
        .tint(AppPalette.ember)
    }
}
