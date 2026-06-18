import Combine
import Foundation

public enum YamlPresetKind: String, CaseIterable, Identifiable {
    case parser
    case webnovel

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .parser: return "サイト YAML（統合）"
        case .webnovel: return "旧 WebNovel YAML"
        }
    }

    var folderName: String {
        switch self {
        case .parser: return "parsers"
        case .webnovel: return "webnovel"
        }
    }
}

public struct YamlPresetSummary: Identifiable, Hashable {
    public let kind: YamlPresetKind
    public let domain: String
    public let hasBundledPreset: Bool
    public let hasUserPreset: Bool

    public var id: String { "\(kind.rawValue):\(domain)" }
    public var isUserOverride: Bool { hasUserPreset }
    public var sourceLabel: String {
        switch (hasBundledPreset, hasUserPreset) {
        case (true, true): return "ユーザー編集あり"
        case (true, false): return "内蔵"
        case (false, true): return "ユーザー追加"
        case (false, false): return "未保存"
        }
    }
}

public struct YamlPresetDraft: Identifiable, Equatable {
    public let id = UUID()
    public var kind: YamlPresetKind
    public var domain: String
    public var yaml: String
    public var existingSummary: YamlPresetSummary?

    public static func blank() -> YamlPresetDraft {
        YamlPresetDraft(
            kind: .parser,
            domain: "",
            yaml: "# 例: example.com.yaml\nname: 新規サイト\ndomain: example.com\nencoding: UTF-8\nwebnovels_site: custom\n\n# 取得用設定と横断検索メタ情報を同じサイト YAML にまとめます。\n",
            existingSummary: nil
        )
    }
}

@MainActor
public final class YamlPresetStore: ObservableObject {
    @Published public private(set) var presets: [YamlPresetSummary] = []
    @Published public private(set) var statusMessage = ""

    private let rootDir: String
    private let fileManager: FileManager

    public init(rootDir: String, fileManager: FileManager = .default) {
        self.rootDir = rootDir
        self.fileManager = fileManager
        reload()
    }

    public func reload() {
        var merged: [String: YamlPresetSummary] = [:]
        for kind in YamlPresetKind.allCases {
            let bundled = yamlDomains(in: bundledDirectory(for: kind))
            let user = yamlDomains(in: userDirectory(for: kind))
            for domain in bundled.union(user) {
                merged["\(kind.rawValue):\(domain)"] = YamlPresetSummary(
                    kind: kind,
                    domain: domain,
                    hasBundledPreset: bundled.contains(domain),
                    hasUserPreset: user.contains(domain)
                )
            }
        }
        presets = merged.values.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.domain.localizedStandardCompare(rhs.domain) == .orderedAscending
        }
        statusMessage = "\(presets.count) 件の YAML を検出しました"
    }

    public func draft(for summary: YamlPresetSummary) -> YamlPresetDraft {
        YamlPresetDraft(
            kind: summary.kind,
            domain: summary.domain,
            yaml: yamlText(for: summary),
            existingSummary: summary
        )
    }

    public func save(_ draft: YamlPresetDraft) throws -> String {
        let domain = try normalizedDomain(draft.domain)
        let yaml = draft.yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !yaml.isEmpty else {
            throw NovelCoreError.operationFailed("YAML が空です")
        }
        let message: String
        switch draft.kind {
        case .parser:
            message = try NovelCoreBridge.callSaveUserParserYaml(domain: domain, yaml: yaml)
        case .webnovel:
            message = try NovelCoreBridge.callSaveUserWebnovelYaml(domain: domain, yaml: yaml)
        }
        reload()
        statusMessage = "保存しました: \(domain)"
        return message
    }

    public func deleteUserPreset(_ summary: YamlPresetSummary) throws {
        let path = userDirectory(for: summary.kind).appendingPathComponent("\(summary.domain).yaml")
        guard fileManager.fileExists(atPath: path.path) else { return }
        try fileManager.removeItem(at: path)
        reload()
        statusMessage = "ユーザー定義を削除しました: \(summary.domain)"
    }

    private func yamlText(for summary: YamlPresetSummary) -> String {
        let userPath = userDirectory(for: summary.kind).appendingPathComponent("\(summary.domain).yaml")
        if let text = try? String(contentsOf: userPath, encoding: .utf8) {
            return text
        }
        if let bundledPath = bundledDirectory(for: summary.kind)?.appendingPathComponent("\(summary.domain).yaml"),
           let text = try? String(contentsOf: bundledPath, encoding: .utf8) {
            return text
        }
        return ""
    }

    private func normalizedDomain(_ rawDomain: String) throws -> String {
        let trimmed = rawDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".yaml", with: "")
        let invalidCharacters = CharacterSet(charactersIn: "/\\:")
        guard !trimmed.isEmpty else {
            throw NovelCoreError.operationFailed("ドメインを入力してください")
        }
        guard trimmed.rangeOfCharacter(from: invalidCharacters) == nil else {
            throw NovelCoreError.operationFailed("ドメインに / \\ : は使えません")
        }
        guard trimmed.contains(".") else {
            throw NovelCoreError.operationFailed("例: example.com の形式で入力してください")
        }
        return trimmed
    }

    private func yamlDomains(in directory: URL?) -> Set<String> {
        guard let directory,
              let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return Set(files.compactMap { url in
            guard url.pathExtension == "yaml" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        })
    }

    private func userDirectory(for kind: YamlPresetKind) -> URL {
        URL(fileURLWithPath: rootDir)
            .appendingPathComponent("presets", isDirectory: true)
            .appendingPathComponent(kind.folderName, isDirectory: true)
    }

    private func bundledDirectory(for kind: YamlPresetKind) -> URL? {
        Bundle.main.url(forResource: "presets", withExtension: nil)?
            .appendingPathComponent(kind.folderName, isDirectory: true)
    }
}
