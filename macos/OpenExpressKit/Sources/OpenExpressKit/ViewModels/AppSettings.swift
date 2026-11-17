import Foundation
import Observation

/// The app's own settings, kept in UserDefaults. Settings the engine keeps (the FIT drop
/// folder, the backup folder and how many backups to keep) live in the engine: see
/// `AppModel.engineSettings`.
@MainActor
@Observable
public final class AppSettings {
    enum Key {
        static let autoSync = "automaticBackupAndSync"
        static let notifications = "notificationsEnabled"
        static let engineOverride = "engineOverride"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Back up and sync when a device is connected (never installs updates). On by default.
    public var automaticBackupAndSync: Bool {
        didSet { defaults.set(automaticBackupAndSync, forKey: Key.autoSync) }
    }

    public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) }
    }

    /// Debug: the engine to run instead of the bundled one (a path, or "mock").
    public var engineOverride: String {
        didSet { defaults.set(engineOverride, forKey: Key.engineOverride) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticBackupAndSync = defaults.object(forKey: Key.autoSync) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Key.notifications) as? Bool ?? true
        engineOverride = defaults.string(forKey: Key.engineOverride) ?? ""
    }
}

/// Shows a notification (UNUserNotificationCenter in the app, a recorder in tests).
@MainActor
public protocol Notifier: AnyObject {
    func notify(title: String, body: String)
}
