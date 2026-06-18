import BackgroundTasks
import SwiftUI

@main
struct NovelDLiOSApp: App {

    init() {
        BackgroundNovelMaintenance.register()
        BackgroundNovelMaintenance.requestNotificationAuthorization()
        PrivateBrowserPrewarmer.prewarm()
        BackgroundNovelMaintenance.scheduleNextRefresh()
        BackgroundNovelMaintenance.scheduleDownloadContinuation()
    }

    var body: some Scene {

        WindowGroup {

            NovelReaderRootView()
        }
    }
}