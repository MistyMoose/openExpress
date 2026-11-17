import Foundation
import Observation

/// The app's own settings, kept in UserDefaults. Settings the engine keeps (the FIT drop
/// folder) are read and written through `settings.get` / `settings.set` instead.
@MainActor
@Observable
public final class AppSettings {
    enum Key {
        static let autoSync = "automaticBackupAndSync"
        static let notifications = "notificationsEnabled"
        static let backupFolder = "backupFolder"
        static let keepBackups = "keepBackups"
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

    public var backupFolder: URL {
        didSet { defaults.set(backupFolder.path, forKey: Key.backupFolder) }
    }

    /// How many backups of each device are kept; 0 keeps all.
    public var keepBackups: Int {
        didSet { defaults.set(keepBackups, forKey: Key.keepBackups) }
    }

    /// Debug: the engine to run instead of the bundled one (a path, or "mock").
    public var engineOverride: String {
        didSet { defaults.set(engineOverride, forKey: Key.engineOverride) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticBackupAndSync = defaults.object(forKey: Key.autoSync) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Key.notifications) as? Bool ?? true
        backupFolder = (defaults.string(forKey: Key.backupFolder)).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? BackupFolder.defaultRoot
        keepBackups = defaults.object(forKey: Key.keepBackups) as? Int ?? 3
        engineOverride = defaults.string(forKey: Key.engineOverride) ?? ""
    }
}

/// Shows a notification (UNUserNotificationCenter in the app, a recorder in tests).
@MainActor
public protocol Notifier: AnyObject {
    func notify(title: String, body: String)
}
