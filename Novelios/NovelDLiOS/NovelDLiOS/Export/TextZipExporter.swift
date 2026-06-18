import Foundation
import GRDB

public enum TextZipExportError: Error, LocalizedError {
    case databaseUnavailable
    case noChapters
    case missingDownloadedBodies(Int)
    case invalidArchivePath

    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "小説データベースを開けません"
        case .noChapters:
            return "書き出す話がありません"
        case .missingDownloadedBodies(let count):
            return "未ダウンロードの話が\(count)件あります。先に全話ダウンロードしてください"
        case .invalidArchivePath:
            return "ZIPの保存先を作成できません"
        }
    }
}

private struct ExportChapterRow: FetchableRecord, Decodable {
    let id: String
    let subtitle: String
    let intro_xhtml_zstd: Data?
    let body_xhtml_zstd: Data?
    let post_xhtml_zstd: Data?
    let intro_zstd_dict: Data?
    let body_zstd_dict: Data?
    let post_zstd_dict: Data?
    let body_downloaded: Bool
}

enum NovelTextZipExporter {
    static func export(novel: NovelMeta) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try exportSync(novel: novel))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func exportSync(novel: NovelMeta) throws -> URL {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(30)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only=ON")
            try db.execute(sql: "PRAGMA busy_timeout=30000")
            try db.execute(sql: "PRAGMA mmap_size=268435456")
            try db.execute(sql: "PRAGMA cache_size=-32768")
        }
        let shardPaths = NovelStorageLayout.shardDatabasePaths(for: novel)
        guard !shardPaths.isEmpty else {
            throw TextZipExportError.databaseUnavailable
        }
        let chapters = try shardPaths.flatMap { shardPath in
            guard FileManager.default.fileExists(atPath: shardPath) else { return [ExportChapterRow]() }
            let db = try DatabaseQueue(path: shardPath, configuration: config)
            return try db.read { database in
                guard try database.tableExists("sections") else { return [] }
                let useDictionaries = hasZstdDictionaryColumns(in: database)
                let sql = useDictionaries ? """
                    SELECT
                        s.chapter_index AS id,
                        s.subtitle,
                        CASE WHEN s.body_downloaded != 0 THEN s.intro_xhtml_zstd ELSE NULL END AS intro_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN s.body_xhtml_zstd ELSE NULL END AS body_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN s.post_xhtml_zstd ELSE NULL END AS post_xhtml_zstd,
                        CASE WHEN s.body_downloaded != 0 THEN intro_dict.dictionary ELSE NULL END AS intro_zstd_dict,
                        CASE WHEN s.body_downloaded != 0 THEN body_dict.dictionary ELSE NULL END AS body_zstd_dict,
                        CASE WHEN s.body_downloaded != 0 THEN post_dict.dictionary ELSE NULL END AS post_zstd_dict,
                        s.body_downloaded
                    FROM sections s
                    LEFT JOIN zstd_dictionaries intro_dict
                      ON intro_dict.novel_id = s.novel_id AND intro_dict.dict_id = s.intro_zstd_dict_id
                    LEFT JOIN zstd_dictionaries body_dict
                      ON body_dict.novel_id = s.novel_id AND body_dict.dict_id = s.body_zstd_dict_id
                    LEFT JOIN zstd_dictionaries post_dict
                      ON post_dict.novel_id = s.novel_id AND post_dict.dict_id = s.post_zstd_dict_id
                    WHERE s.novel_id = ?
                    ORDER BY s.sort_key, s.chapter_index
                """ : """
                    SELECT
                        chapter_index AS id,
                        subtitle,
                        CASE WHEN body_downloaded != 0 THEN intro_xhtml_zstd ELSE NULL END AS intro_xhtml_zstd,
                        CASE WHEN body_downloaded != 0 THEN body_xhtml_zstd ELSE NULL END AS body_xhtml_zstd,
                        CASE WHEN body_downloaded != 0 THEN post_xhtml_zstd ELSE NULL END AS post_xhtml_zstd,
                        NULL AS intro_zstd_dict,
                        NULL AS body_zstd_dict,
                        NULL AS post_zstd_dict,
                        body_downloaded
                    FROM sections
                    WHERE novel_id = ?
                    ORDER BY sort_key, chapter_index
                """
                return try ExportChapterRow.fetchAll(database, sql: sql, arguments: [novel.id])
            }
        }
        guard !chapters.isEmpty else { throw TextZipExportError.noChapters }
        let missingCount = chapters.filter { !$0.body_downloaded || $0.body_xhtml_zstd == nil }.count
        guard missingCount == 0 else { throw TextZipExportError.missingDownloadedBodies(missingCount) }

        let archiveURL = try archiveURL(for: novel)
        var writer = ZipStoreWriter()
        let rootFolder = sanitizePathComponent(novel.displayTitle)
        writer.addDirectory(path: "\(rootFolder)/")

        for (offset, chapter) in chapters.enumerated() {
            let ordinal = offset + 1
            let folder = String(format: "%03d", ((ordinal - 1) / 1000) + 1)
            writer.addDirectory(path: "\(rootFolder)/\(folder)/")
            let filename = String(format: "%03d.txt", ordinal)
            let xhtml = [
                decompress(chapter.intro_xhtml_zstd, dictionary: chapter.intro_zstd_dict),
                decompress(chapter.body_xhtml_zstd, dictionary: chapter.body_zstd_dict),
                decompress(chapter.post_xhtml_zstd, dictionary: chapter.post_zstd_dict)
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
            let text = [chapter.subtitle, xhtmlToPlainText(xhtml)]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
                .appending("\n")
            writer.addFile(path: "\(rootFolder)/\(folder)/\(filename)", data: Data(text.utf8))
        }

        try writer.write(to: archiveURL)
        return archiveURL
    }

    private static func archiveURL(for novel: NovelMeta) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NovelDLTextExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(sanitizePathComponent(novel.displayTitle))_\(timestamp).zip"
        let url = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }

    private static func decompress(_ data: Data?, dictionary: Data? = nil) -> String? {
        NovelCoreBridge.tryDecompressZstdData(data, dictionary: dictionary)
    }

    private static func hasZstdDictionaryColumns(in db: Database) -> Bool {
        ((try? db.tableExists("zstd_dictionaries")) ?? false)
            && ((try? String.fetchAll(db, sql: "SELECT name FROM pragma_table_info(?)", arguments: ["sections"]).contains("body_zstd_dict_id")) ?? false)
    }

    private static func xhtmlToPlainText(_ xhtml: String) -> String {
        let ns = xhtml as NSString
        let pattern = #"(?is)<ruby\b[^>]*>(.*?)</ruby>|<br\s*/?>|</p>|<p[^>]*>|<[^>]+>"#
        let regex = try? NSRegularExpression(pattern: pattern)
        var cursor = 0
        var output = ""
        for match in regex?.matches(in: xhtml, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if match.range.location > cursor {
                output += decodeEntities(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            let matched = ns.substring(with: match.range).lowercased()
            if match.range(at: 1).location != NSNotFound {
                output += rubyText(inner: ns.substring(with: match.range(at: 1)))
            } else if matched.hasPrefix("<br") || matched.hasPrefix("</p") || matched.hasPrefix("<p") {
                output += "\n"
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            output += decodeEntities(ns.substring(from: cursor))
        }
        return normalizeNewlines(output)
    }

    private static func rubyText(inner: String) -> String {
        let ns = inner as NSString
        let full = NSRange(location: 0, length: ns.length)
        let rtRegex = try? NSRegularExpression(pattern: #"(?is)<rt[^>]*>(.*?)</rt>"#)
        guard let match = rtRegex?.firstMatch(in: inner, range: full), match.range(at: 1).location != NSNotFound else {
            return decodeEntities(stripTags(inner))
        }
        let ruby = decodeEntities(stripTags(ns.substring(with: match.range(at: 1))))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSource = rtRegex?.stringByReplacingMatches(in: inner, range: full, withTemplate: "") ?? inner
        let base = decodeEntities(stripTags(baseSource))
            .replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !ruby.isEmpty else { return base.isEmpty ? ruby : base }
        return "\(base)(\(ruby))"
    }

    private static func stripTags(_ input: String) -> String {
        let regex = try? NSRegularExpression(pattern: #"(?is)<[^>]+>"#)
        let range = NSRange(location: 0, length: (input as NSString).length)
        return regex?.stringByReplacingMatches(in: input, range: range, withTemplate: "") ?? input
    }

    private static func decodeEntities(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func normalizeNewlines(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizePathComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        return cleaned.isEmpty ? "novel" : cleaned
    }
}

private struct ZipStoreWriter {
    private struct Entry {
        let path: String
        let data: Data
        let crc: UInt32
        let localHeaderOffset: UInt32
        let isDirectory: Bool
    }

    private var entries: [Entry] = []
    private var body = Data()

    mutating func addDirectory(path: String) {
        let normalized = path.hasSuffix("/") ? path : path + "/"
        guard !entries.contains(where: { $0.path == normalized }) else { return }
        appendEntry(path: normalized, data: Data(), isDirectory: true)
    }

    mutating func addFile(path: String, data: Data) {
        appendEntry(path: path, data: data, isDirectory: false)
    }

    mutating func write(to url: URL) throws {
        var archive = body
        let centralDirectoryOffset = UInt32(archive.count)
        var centralDirectory = Data()
        for entry in entries {
            appendCentralDirectoryHeader(for: entry, to: &centralDirectory)
        }
        archive.append(centralDirectory)
        appendEndOfCentralDirectory(
            entryCount: UInt16(entries.count),
            centralDirectorySize: UInt32(centralDirectory.count),
            centralDirectoryOffset: centralDirectoryOffset,
            to: &archive
        )
        try archive.write(to: url, options: .atomic)
    }

    private mutating func appendEntry(path: String, data: Data, isDirectory: Bool) {
        let offset = UInt32(body.count)
        let crc = CRC32.checksum(data)
        appendLocalHeader(path: path, data: data, crc: crc, to: &body)
        body.append(data)
        entries.append(Entry(path: path, data: data, crc: crc, localHeaderOffset: offset, isDirectory: isDirectory))
    }

    private func appendLocalHeader(path: String, data: Data, crc: UInt32, to output: inout Data) {
        let pathData = Data(path.utf8)
        output.appendUInt32(0x04034b50)
        output.appendUInt16(20)
        output.appendUInt16(0x0800)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt32(crc)
        output.appendUInt32(UInt32(data.count))
        output.appendUInt32(UInt32(data.count))
        output.appendUInt16(UInt16(pathData.count))
        output.appendUInt16(0)
        output.append(pathData)
    }

    private func appendCentralDirectoryHeader(for entry: Entry, to output: inout Data) {
        let pathData = Data(entry.path.utf8)
        output.appendUInt32(0x02014b50)
        output.appendUInt16(20)
        output.appendUInt16(20)
        output.appendUInt16(0x0800)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt32(entry.crc)
        output.appendUInt32(UInt32(entry.data.count))
        output.appendUInt32(UInt32(entry.data.count))
        output.appendUInt16(UInt16(pathData.count))
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt32(entry.isDirectory ? 0x10 : 0)
        output.appendUInt32(entry.localHeaderOffset)
        output.append(pathData)
    }

    private func appendEndOfCentralDirectory(
        entryCount: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32,
        to output: inout Data
    ) {
        output.appendUInt32(0x06054b50)
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(entryCount)
        output.appendUInt16(entryCount)
        output.appendUInt32(centralDirectorySize)
        output.appendUInt32(centralDirectoryOffset)
        output.appendUInt16(0)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xedb88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
