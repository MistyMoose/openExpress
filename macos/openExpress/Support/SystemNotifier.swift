import OpenExpressKit
import ServiceManagement
import UserNotifications

/// Notifications through the Notification Center; asks for permission the first time.
final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()

    private var authorized: Bool?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func notify(title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // Also while the app is in front: the summary of an automatic sync is worth seeing.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Open at Login, through SMAppService.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
