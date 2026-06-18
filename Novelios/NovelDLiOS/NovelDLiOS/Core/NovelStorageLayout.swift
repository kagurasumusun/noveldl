import Foundation

/// Mirrors the Rust storage layout: master metadata in `master.db` and chapter
/// shards in `novels/<site>/<novel>/0001.db`, `0002.db`, ...
enum NovelStorageLayout {
    static let masterDatabaseName = "master.db"
    static let novelsDirectoryName = "novels"

    static func isMasterDatabase(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent == masterDatabaseName
    }

    static func databaseRoot(for storagePath: String) -> URL {
        URL(fileURLWithPath: storagePath).standardizedFileURL.deletingLastPathComponent()
    }

    static func shardDirectory(for novel: NovelMeta) -> URL {
        databaseRoot(for: novel.storagePath)
            .appendingPathComponent(novelsDirectoryName, isDirectory: true)
            .appendingPathComponent(safePathComponent(novel.domain), isDirectory: true)
            .appendingPathComponent(safePathComponent(novel.id), isDirectory: true)
    }

    static func shardDatabasePaths(for novel: NovelMeta) -> [String] {
        guard isMasterDatabase(novel.storagePath) else { return [novel.storagePath] }
        let directory = shardDirectory(for: novel)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { $0.pathExtension == "db" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(\.path)
    }


    static func safePathComponent(_ input: String) -> String {
        guard !input.isEmpty else { return "novel-empty" }
        var output = ""
        for byte in input.utf8 {
            switch byte {
            case 0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x2E, 0x5F, 0x2D:
                output.unicodeScalars.append(UnicodeScalar(Int(byte))!)
            default:
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }
}
