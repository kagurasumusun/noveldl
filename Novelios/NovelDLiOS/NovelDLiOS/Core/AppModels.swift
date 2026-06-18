import Foundation

// MARK: - App-wide models

public enum AppMainTab: String, Hashable {
    case library
    case reader
    case browser
    case search
    case settings
}

public enum LibrarySortMode: String, CaseIterable, Identifiable {
    case updated
    case title
    case episodes

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .updated: return "更新順"
        case .title: return "タイトル順"
        case .episodes: return "話数順"
        }
    }
}

public enum ParserEngineChoice: String, CaseIterable, Identifiable {
    case domain
    case nokogiri
    case legacy

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .domain: return "ドメイン"
        case .nokogiri: return "Nokogiri"
        case .legacy: return "Legacy"
        }
    }
}
