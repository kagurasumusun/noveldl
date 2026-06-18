import BackgroundTasks
import Foundation
import UserNotifications

enum BackgroundNovelMaintenance {
    static let refreshIdentifier = "com.example.NovelDLiOS.toc-refresh"
    static let downloadIdentifier = "com.example.NovelDLiOS.download-continuation"
    private static let pendingDownloadURLKey = "NovelDL.pendingFullDownloadURL.v1"
    private static let minimumRefreshInterval: TimeInterval = 30 * 60

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            handleRefresh(task: task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: downloadIdentifier, using: nil) { task in
            handleDownloadContinuation(task: task)
        }
    }

    static func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func scheduleNextRefresh(after _: TimeInterval = minimumRefreshInterval) {
        // TOC refresh is intentionally foreground-triggered only: manual refresh,
        // add-to-shelf, app launch, and app foreground return.
    }

    static func recordPendingFullDownload(url: String) {
        UserDefaults.standard.set(url, forKey: pendingDownloadURLKey)
        scheduleDownloadContinuation()
    }

    static func clearPendingFullDownload(url: String? = nil) {
        if let url, UserDefaults.standard.string(forKey: pendingDownloadURLKey) != url { return }
        UserDefaults.standard.removeObject(forKey: pendingDownloadURLKey)
    }

    static func scheduleDownloadContinuation() {
        guard UserDefaults.standard.string(forKey: pendingDownloadURLKey) != nil else { return }
        let request = BGProcessingTaskRequest(identifier: downloadIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleRefresh(task: BGTask) {
        task.setTaskCompleted(success: true)
    }

    private static func handleDownloadContinuation(task: BGTask) {
        nonisolated(unsafe) let task = task
        guard let url = UserDefaults.standard.string(forKey: pendingDownloadURLKey) else {
            task.setTaskCompleted(success: true)
            return
        }
        let operation = FullDownloadOperation(url: url)
        task.expirationHandler = { operation.cancel() }
        operation.completionBlock = {
            let success = !operation.isCancelled && operation.error == nil
            task.setTaskCompleted(success: success)
            if success {
                clearPendingFullDownload(url: url)
                notify(title: "NovelDL ダウンロード", body: "全話ダウンロードが完了しました")
            } else {
                scheduleDownloadContinuation()
            }
        }
        OperationQueue().addOperation(operation)
    }

    static func refreshDownloadedTocsForShortcuts() throws -> String {
        try NovelCoreBridge.callSetRootDir(rootDir: AppState.docsDir)
        return try NovelCoreBridge.callRefreshDownloadedTocs(rootDir: AppState.libraryRootDir)
    }

    private static func notifyTocRefresh(refreshed: Int) {
        notify(title: "NovelDL 目次更新", body: "\(refreshed)作品の目次を更新しました")
    }

    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "noveldl-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

private final class FullDownloadOperation: Operation, @unchecked Sendable {
    let url: String
    var error: Error?

    init(url: String) {
        self.url = url
    }

    override func main() {
        guard !isCancelled else { return }
        do {
            try NovelCoreBridge.callSetRootDir(rootDir: AppState.docsDir)
            _ = try NovelCoreBridge.callDownloadCachedFromChapter(
                url: url,
                chapterIndex: "",
                outputDir: AppState.outputDir(for: url)
            )
        } catch {
            self.error = error
        }
    }
}

private final class TocRefreshOperation: Operation, @unchecked Sendable {
    var error: Error?
    var refreshedCount = 0

    override func main() {
        guard !isCancelled else { return }
        do {
            let result = try BackgroundNovelMaintenance.refreshDownloadedTocsForShortcuts()
            refreshedCount = Self.parseRefreshedCount(result)
        } catch {
            self.error = error
        }
    }

    private static func parseRefreshedCount(_ result: String) -> Int {
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        return object["refreshed"] as? Int ?? 0
    }
}
