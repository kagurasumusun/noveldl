import SwiftUI

/// シェル — 画面と機能の階層を一本の「紙の帯」タブで整理する。
/// 標準の TabView 外装は使わず、書籍アプリらしい静かな帯に。
///
/// 階層:
///   本棚 ─ 作品詳細 ─ 読書(独立フルスクリーン)
///   さがす ─ 新しい作品の発見 → 本棚へ
///   取得 ─ ダウンロードの進捗と再実行
///   設定 ─ 取得の間隔 / 対応サイト ─ サイト編集 / 情報
struct AppShell: View {
    enum Tab: Hashable, CaseIterable {
        case library, discover, activity, settings

        var title: String {
            switch self {
            case .library: return "本棚"
            case .discover: return "さがす"
            case .activity: return "取得"
            case .settings: return "設定"
            }
        }

        var icon: String {
            switch self {
            case .library: return "books.vertical"
            case .discover: return "sparkle.magnifyingglass"
            case .activity: return "arrow.down.circle"
            case .settings: return "gearshape"
            }
        }
    }

    @Environment(CoreClient.self) private var core: CoreClient
    @State private var tab: Tab = .library
    /// 検索の状態はタブを跨いで保持する(タブ移動で検索が消えないように)。
    @StateObject private var discoverSession = DiscoverSession()

    var body: some View {
        ZStack {
            AppPalette.canvas.ignoresSafeArea()

            content
                .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        }
    }

    private var content: some View {
        Group {
            switch tab {
            case .library:
                LibraryView()
            case .discover:
                DiscoverView(session: discoverSession)
            case .activity:
                QueueView()
            case .settings:
                SettingsView()
            }
        }
        .transition(.opacity)
        .id(tab)
        // さがすタブではキーボードによる押し上げを止める(検索フィールドは
        // 固定ヘッダーの上部にあり、隠れないため動かす必要がない)。
        // 他タブ(フォーム入力など)では通常どおりキーボード回避する。
        .ignoresSafeArea(.keyboard, edges: tab == .discover ? .bottom : [])
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    guard tab != item else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { tab = item }
                    Haptics.tap()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(AppFont.ui(17, weight: .medium))
                        Text(item.title)
                            .font(AppFont.ui(10, weight: .semibold))
                    }
                    .foregroundStyle(tab == item ? AppPalette.ember : AppPalette.inkFaint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(haptic: false))
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .background(
            AppPalette.canvas
                .overlay(Rectangle().fill(AppPalette.hairline).frame(height: 1), alignment: .top)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
