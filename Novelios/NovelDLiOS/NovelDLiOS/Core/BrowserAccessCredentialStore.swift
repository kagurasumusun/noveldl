import Foundation

private struct BrowserAccessCredential: Codable {
    let host: String
    let cookieHeader: String
    let updatedAt: Date
}

enum BrowserAccessCredentialStore {
    private static let key = "NovelDL.browserAccessCredentials.v1"
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private static let maxEntries = 24

    static func save(host: String, cookieHeader: String) {
        let normalizedHost = host.lowercased()
        let trimmed = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, !trimmed.isEmpty else { return }
        var all = loadFreshEntries()
        all[normalizedHost] = BrowserAccessCredential(
            host: normalizedHost,
            cookieHeader: trimmed,
            updatedAt: Date()
        )
        persist(limitEntries(all))
    }

    static func cookie(for host: String) -> String? {
        let host = host.lowercased()
        let candidates = loadFreshEntries().values.filter { credential in
            domainMatches(host: host, storedDomain: credential.host)
        }
        return candidates
            .sorted { $0.updatedAt > $1.updatedAt }
            .first?
            .cookieHeader
    }

    static func invalidate(host: String) {
        let host = host.lowercased()
        let filtered = loadFreshEntries().filter { key, _ in !domainMatches(host: host, storedDomain: key) }
        persist(filtered)
    }

    static func domainMatches(host: String, storedDomain: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let stored = storedDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !stored.isEmpty else { return false }
        if host == stored || host.hasSuffix("." + stored) { return true }
        if stored.hasPrefix("www."), host == String(stored.dropFirst(4)) { return true }
        if host.hasPrefix("www."), String(host.dropFirst(4)) == stored { return true }
        return false
    }

    private static func loadFreshEntries() -> [String: BrowserAccessCredential] {
        let now = Date()
        let all = loadAll()
        let fresh = all.filter { _, credential in
            now.timeIntervalSince(credential.updatedAt) <= maxAge
        }
        if fresh.count != all.count { persist(fresh) }
        return fresh
    }

    private static func limitEntries(_ entries: [String: BrowserAccessCredential]) -> [String: BrowserAccessCredential] {
        Dictionary(
            uniqueKeysWithValues: entries
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(maxEntries)
                .map { ($0.key, $0.value) }
        )
    }

    private static func persist(_ entries: [String: BrowserAccessCredential]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadAll() -> [String: BrowserAccessCredential] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: BrowserAccessCredential].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
