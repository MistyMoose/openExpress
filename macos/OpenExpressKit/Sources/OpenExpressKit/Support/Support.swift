import Foundation

/// The sign-in ticket Garmin's page hands back, as `account.sign_in` takes it.
public enum SignInTicket {
    public static let embedURL = "https://sso.garmin.com/sso/embed"

    /// A navigation to a URL that carries the ticket (`…?ticket=ST-…`).
    public static func fromURL(_ url: URL) -> String? {
        let s = url.absoluteString
        guard s.contains("ticket=ST-") else { return nil }
        return s
    }

    /// A page whose content is JSON with the ticket, as Garmin's embed page answered:
    /// `{serviceUrl: 'https://sso.garmin.com/sso/embed', serviceTicket: 'ST-…'}` (single or
    /// double quotes, keys quoted or not). The ticket URL is built on the embed URL.
    public static func fromPageText(_ text: String) -> String? {
        let pattern = #"["']?serviceTicket["']?\s*:\s*["'](ST-[A-Za-z0-9._\-]+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text)
        else { return nil }
        var c = URLComponents(string: embedURL)!
        c.queryItems = [URLQueryItem(name: "ticket", value: String(text[r]))]
        return c.url?.absoluteString
    }
}

/// Where backups go when the engine's `backup_dir` is not set (paths.default_backup_dir).
public enum BackupFolder {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Garmin/Backups")
    }
}

/// Formatting shared by the views and the notifications.
public enum Format {
    public static func bytes(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .file))
    }

    /// 3725 → "1:02:05", 605 → "10:05".
    public static func duration(_ seconds: Double) -> String {
        let d = Duration.seconds(seconds.rounded())
        return seconds >= 3600
            ? d.formatted(.time(pattern: .hourMinuteSecond))
            : d.formatted(.time(pattern: .minuteSecond))
    }

    /// Metres in the user's units: "12.4 km", "7.7 mi", "850 m".
    public static func distance(_ metres: Double) -> String {
        Measurement(value: metres, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road,
                                    numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    /// Elevation and ascent in the user's units: metres, or feet where roads are in miles.
    public static var elevationUnit: UnitLength {
        Locale.current.measurementSystem == .us ? .feet : .meters
    }

    public static func elevationValue(_ metres: Double) -> Double {
        Measurement(value: metres, unit: UnitLength.meters).converted(to: elevationUnit).value
    }

    /// "1,234 m".
    public static func elevation(_ metres: Double) -> String {
        Measurement(value: elevationValue(metres), unit: elevationUnit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    /// "142".
    public static func heartRate(_ bpm: Double) -> String {
        bpm.formatted(.number.precision(.fractionLength(0)))
    }

    public static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

/// The pages of a device.
public enum DevicePage: String, CaseIterable, Identifiable, Sendable, Codable {
    case overview, activities, updates, maps, apps, backups

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .activities: String(localized: "Activities")
        case .updates: String(localized: "Updates")
        case .maps: String(localized: "Maps")
        case .apps: String(localized: "Apps")
        case .backups: String(localized: "Backups")
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: "info.circle"
        case .activities: "figure.run"
        case .updates: "arrow.down.circle"
        case .maps: "map"
        case .apps: "square.grid.2x2"
        case .backups: "clock.arrow.circlepath"
        }
    }

    /// Pages that need the device connected.
    public var needsConnection: Bool {
        switch self {
        case .overview, .activities, .backups: false
        case .updates, .maps, .apps: true
        }
    }
}

public enum SidebarItem: Hashable, Sendable, Codable {
    case device(String)
    case account
}

/// Data types of a sync and the FIT drop folder, the common ones (names as in
/// openexpress/service.py).
public enum FITDataType: String, CaseIterable, Identifiable, Sendable {
    case activities = "FIT_TYPE_4"
    case weight = "FIT_TYPE_9"
    case dailyMonitoring = "FIT_TYPE_28"
    case monitoring = "FIT_TYPE_32"
    case sleep = "FIT_TYPE_49"
    case hrv = "FIT_TYPE_68"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .activities: String(localized: "Activities")
        case .weight: String(localized: "Weight")
        case .dailyMonitoring: String(localized: "Daily monitoring")
        case .monitoring: String(localized: "Monitoring")
        case .sleep: String(localized: "Sleep")
        case .hrv: String(localized: "HRV status")
        }
    }
}
