import AppIntents
import Foundation

struct RefreshAllNovelTocsIntent: AppIntent {
    static let title: LocalizedStringResource = "小説の目次を更新"
    static let description = IntentDescription("本棚にある小説の目次をバックグラウンドで更新します。")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try BackgroundNovelMaintenance.refreshDownloadedTocsForShortcuts()
        return .result(dialog: "目次更新を実行しました: \(result)")
    }
}

struct DownloadNovelFromURLIntent: AppIntent {
    static let title: LocalizedStringResource = "小説URLを本棚に追加"
    static let description = IntentDescription("指定した目次URLを本棚に追加し、目次を取得します。")

    @Parameter(title: "目次URL") var url: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try NovelCoreBridge.callSetRootDir(rootDir: AppState.docsDir)
        let outputDir = AppState.outputDir(for: url)
        let result = try NovelCoreBridge.callFetchTocOnly(url: url, outputDir: outputDir)
        return .result(dialog: "本棚に追加しました: \(result)")
    }
}

struct DownloadAllNovelFromURLIntent: AppIntent {
    static let title: LocalizedStringResource = "小説URLを全話ダウンロード"
    static let description = IntentDescription("指定した目次URLの全話ダウンロードを開始します。")

    @Parameter(title: "目次URL") var url: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try NovelCoreBridge.callSetRootDir(rootDir: AppState.docsDir)
        BackgroundNovelMaintenance.recordPendingFullDownload(url: url)
        return .result(dialog: "全話ダウンロードをバックグラウンドに登録しました")
    }
}

struct NovelDLShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAllNovelTocsIntent(),
            phrases: ["\(.applicationName)で小説更新", "\(.applicationName)で目次更新"],
            shortTitle: "小説更新",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: DownloadNovelFromURLIntent(),
            phrases: ["\(.applicationName)で小説を本棚に追加"],
            shortTitle: "本棚に追加",
            systemImageName: "books.vertical"
        )
        AppShortcut(
            intent: DownloadAllNovelFromURLIntent(),
            phrases: ["\(.applicationName)で小説を全話ダウンロード"],
            shortTitle: "全話DL",
            systemImageName: "arrow.down.circle"
        )
    }
}
