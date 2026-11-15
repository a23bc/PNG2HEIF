import SwiftUI
import BackgroundTasks
import UIKit

@main
struct PNG2HEIFApp: App {
    static let bgTaskID = "com.example.PNG2HEIF.autoconvert"

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskID, using: nil) { task in
            Self.scheduleAutoConvert()
            let service = PhotoLibraryService.shared
            let started = service.convertNewScreenshots(trigger: "BGTask")
            if started {
                service.onConversionFinished = { task.setTaskCompleted(success: true) }
                task.expirationHandler = {
                    service.stopConversion()
                    task.setTaskCompleted(success: false)
                }
            } else {
                task.setTaskCompleted(success: true)
            }
        }
    }

    /// 退到后台时预约下一次 opportunistic 唤醒（系统决定实际时机）。
    static func scheduleAutoConvert() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    guard url.scheme == "png2heif" else { return }
                    if url.host == "convert-new" || url.path.contains("convert-new") {
                        _ = PhotoLibraryService.shared.convertNewScreenshots(trigger: "快捷指令/URL")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didEnterBackgroundNotification)) { _ in
                    Self.scheduleAutoConvert()
                }
        }
    }
}