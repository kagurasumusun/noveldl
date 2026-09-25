import SwiftUI

/// 検索の状態(語・結果・範囲)。
/// タブ移動ではもちろん、アプリ再起動後も消えないように
/// UserDefaults に書き出し、起動時に復元する。
final class DiscoverSession: ObservableObject {
    private static let queryKey = "discover.query"
    private static let scopeKeyKey = "discover.scope"
    private static let resultsKey = "discover.results"

    @Published var query: String {
        didSet { UserDefaults.standard.set(query, forKey: Self.queryKey) }
    }
    @Published var scopeKey: String? {
        didSet {
            if let scopeKey {
                UserDefaults.standard.set(scopeKey, forKey: Self.scopeKeyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.scopeKeyKey)
            }
        }
    }
    @Published var results: [SearchResultItem] {
        didSet {
            if let data = try? JSONEncoder().encode(results) {
                UserDefaults.standard.set(data, forKey: Self.resultsKey)
            }
        }
    }

    init() {
        let d = UserDefaults.standard
        query = d.string(forKey: Self.queryKey) ?? ""
        scopeKey = d.string(forKey: Self.scopeKeyKey)
        results = d.data(forKey: Self.resultsKey).flatMap {
            try? JSONDecoder().decode([SearchResultItem].self, from: $0)
        } ?? []
    }

    /// 検索語・結果をまとめて空にする(クリアボタン用)。
    func clear() {
        query = ""
        results = []
    }
}
