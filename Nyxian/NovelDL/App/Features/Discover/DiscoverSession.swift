import SwiftUI

/// 検索の状態(語・結果・範囲)。タブを移動しても消えないようシェルが保持する。
final class DiscoverSession: ObservableObject {
    @Published var query: String = ""
    @Published var results: [SearchResultItem] = []
    @Published var scopeKey: String? = nil
}
