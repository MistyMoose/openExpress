import Foundation

/// A software update the device can get (`updates.list`).
public struct SoftwareUpdate: Codable, Sendable, Hashable, Identifiable {
    public var part: String
    public var name: String
    public var version: String
    public var installed: String?
    public var size: Int64
    public var beta: Bool
    /// Copied to the device, which installs it once unplugged.
    public var waitingOnDevice: Bool

    public var id: String { part }

    public init(part: String, name: String, version: String, installed: String?, size: Int64,
                beta: Bool = false, waitingOnDevice: Bool = false) {
        self.part = part
        self.name = name
        self.version = version
        self.installed = installed
        self.size = size
        self.beta = beta
        self.waitingOnDevice = waitingOnDevice
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        part = try c.decode(String.self, forKey: .part)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? part
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        installed = try c.decodeIfPresent(String.self, forKey: .installed)
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        beta = try c.decodeIfPresent(Bool.self, forKey: .beta) ?? false
        waitingOnDevice = try c.decodeIfPresent(Bool.self, forKey: .waitingOnDevice) ?? false
    }
}

public struct UpdatesList: Codable, Sendable, Hashable {
    public var updates: [SoftwareUpdate]
    public var betaOffered: Bool
    /// "current", "available", "ready" (copied, unplug to install) or "not-installed".
    public var state: String?
    public var addOns: [SoftwareUpdate]

    public init(updates: [SoftwareUpdate], betaOffered: Bool = false, state: String? = nil,
                addOns: [SoftwareUpdate] = []) {
        self.updates = updates
        self.betaOffered = betaOffered
        self.state = state
        self.addOns = addOns
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updates = try c.decodeIfPresent([SoftwareUpdate].self, forKey: .updates) ?? []
        betaOffered = try c.decodeIfPresent(Bool.self, forKey: .betaOffered) ?? false
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        addOns = (try? c.decodeIfPresent([SoftwareUpdate].self, forKey: .addOns)) ?? []
    }
}

/// A map (`maps.list`). Named so as not to clash with MapKit's `Map`.
public struct DeviceMap: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case upToDate = "up to date"
        case update
        case available
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var name: String
    public var version: String?
    public var size: Int64
    public var installed: Bool
    public var status: Status
    public var region: String?
    /// The version on the device, for an update. Not in docs/ENGINE.md: asked of the engine.
    public var installedVersion: String?
    /// Translated, finer than `status`.
    public var statusText: String?
    public var canInstall: Bool?
    public var canRemove: Bool?

    public var id: String { name }

    public init(name: String, version: String?, size: Int64, installed: Bool, status: Status,
                region: String? = nil, installedVersion: String? = nil, statusText: String? = nil,
                canInstall: Bool? = nil, canRemove: Bool? = nil) {
        self.name = name
        self.version = version
        self.size = size
        self.installed = installed
        self.status = status
        self.region = region
        self.installedVersion = installedVersion
        self.statusText = statusText
        self.canInstall = canInstall
        self.canRemove = canRemove
    }

    /// "2025.10 → 2025.20" for an update, "new · 2025.20" for a map not installed.
    public var versionChange: String? {
        guard let version else { return installed ? nil : String(localized: "new") }
        if !installed { return String(localized: "new · \(version)") }
        if let installedVersion, installedVersion != version { return "\(installedVersion) → \(version)" }
        return version
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? (installed ? .upToDate : .available)
        region = try? c.decodeIfPresent(String.self, forKey: .region)
        installedVersion = try? c.decodeIfPresent(String.self, forKey: .installedVersion)
        statusText = try? c.decodeIfPresent(String.self, forKey: .statusText)
        canInstall = try? c.decodeIfPresent(Bool.self, forKey: .canInstall)
        canRemove = try? c.decodeIfPresent(Bool.self, forKey: .canRemove)
    }
}

/// A map of the user's own on the device. docs/ENGINE.md leaves its shape open ("[...]"):
/// a bare file name or an object with at least a name.
public struct OwnMap: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var size: Int64?

    public var id: String { name }

    public init(name: String, size: Int64? = nil) {
        self.name = name
        self.size = size
    }

    public init(from decoder: any Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            name = s
            size = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .title)) ?? (try? c.decode(String.self, forKey: .name))
            ?? (try? c.decode(String.self, forKey: .file)) ?? "?"
        size = try? c.decodeIfPresent(Int64.self, forKey: .size)
    }

    enum CodingKeys: String, CodingKey { case name, title, file, size }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(size, forKey: .size)
    }
}

public struct MapsList: Codable, Sendable, Hashable {
    public var maps: [DeviceMap]
    public var ownMaps: [OwnMap]
    public var free: Int64?
    /// Set when Garmin has no maps service for the device (`maps` is then empty).
    public var message: String?
    public var moreAvailable: Int?

    public init(maps: [DeviceMap], ownMaps: [OwnMap] = [], free: Int64? = nil, message: String? = nil) {
        self.maps = maps
        self.ownMaps = ownMaps
        self.free = free
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maps = try c.decodeIfPresent([DeviceMap].self, forKey: .maps) ?? []
        ownMaps = (try? c.decodeIfPresent([OwnMap].self, forKey: .ownMaps)) ?? []
        free = try? c.decodeIfPresent(Int64.self, forKey: .free)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        moreAvailable = try? c.decodeIfPresent(Int.self, forKey: .moreAvailable)
    }

    public var installed: [DeviceMap] { maps.filter(\.installed) }
    public var available: [DeviceMap] { maps.filter { !$0.installed } }
    public var updatable: [DeviceMap] { maps.filter { $0.installed && $0.status == .update } }
}

/// A Connect IQ app on the device. `apps.list` answers "as the CLI": the app reads only these
/// fields, all but the name optional.
public struct ConnectIQApp: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var version: String?
    public var type: String?
    public var size: Int64?
    public var enabled: Bool?
    public var updateAvailable: Bool?
    public var appID: String?

    public var id: String { appID ?? name }

    enum CodingKeys: String, CodingKey {
        case name, version, type, size, enabled, updateAvailable
        case appID = "id"
    }

    public init(name: String, version: String? = nil, type: String? = nil, size: Int64? = nil,
                enabled: Bool? = nil, updateAvailable: Bool? = nil, appID: String? = nil) {
        self.name = name
        self.version = version
        self.type = type
        self.size = size
        self.enabled = enabled
        self.updateAvailable = updateAvailable
        self.appID = appID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "?"
        version = (try? c.decodeIfPresent(String.self, forKey: .version))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .version)).map { String($0) }
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        size = try? c.decodeIfPresent(Int64.self, forKey: .size)
        enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
        updateAvailable = try? c.decodeIfPresent(Bool.self, forKey: .updateAvailable)
        appID = try? c.decodeIfPresent(String.self, forKey: .appID)
    }

    /// SF Symbol of the kind of app ("watch-app", "watchface", "datafield", "widget", …).
    public var systemImage: String {
        switch type?.lowercased() {
        case "watchface", "watch-face", "watch face": "clock"
        case "datafield", "data-field", "data field": "square.grid.2x2"
        case "widget", "glance": "rectangle.stack"
        case "music", "audio-content-provider": "music.note"
        default: "app"
        }
    }
}

/// `apps.list` runs `apps` as the command line: `{"exit_code", "lines"}`. A structured
/// `{"apps": [...]}` is read too, should the engine add one.
public struct AppsList: Codable, Sendable, Hashable {
    public var apps: [ConnectIQApp]?
    public var lines: [String]
    public var exitCode: Int?

    public init(apps: [ConnectIQApp]? = nil, lines: [String] = [], exitCode: Int? = 0) {
        self.apps = apps
        self.lines = lines
        self.exitCode = exitCode
    }

    public init(from decoder: any Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([ConnectIQApp].self) {
            apps = list
            lines = []
            exitCode = 0
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            apps = try? c.decodeIfPresent([ConnectIQApp].self, forKey: .apps)
            lines = (try? c.decodeIfPresent([String].self, forKey: .lines)) ?? []
            exitCode = try? c.decodeIfPresent(Int.self, forKey: .exitCode)
        }
    }
}

/// An activity on the device or in its backups (`activities.list`).
public struct Activity: Codable, Sendable, Hashable, Identifiable {
    public var start: Date
    public var sport: String
    /// Metres.
    public var distance: Double?
    /// Seconds.
    public var duration: Double?
    /// The FIT file on this computer or the device; nil when the engine sends none.
    public var fitPath: String?
    public var name: String?
    public var ascent: Double?
    public var calories: Double?
    public var averageHeartRate: Double?
    /// "device" or "backup".
    public var source: String?
    /// "complete", "still_being_written", "damaged" or "unreadable".
    public var state: String?
    public var size: Int64?

    public var id: String { (source ?? "") + ":" + (fitPath ?? start.ISO8601Format()) }

    /// The FIT file is a file on this Mac (a backup's copy), not one on the device.
    public var isOnThisMac: Bool { source == "backup" }

    enum CodingKeys: String, CodingKey {
        case start, sport, distance, duration, fitPath, fit, path, name, ascent, calories
        case averageHeartRate, avgHeartRate, source, state, size
    }

    public init(start: Date, sport: String, distance: Double? = nil, duration: Double? = nil,
                fitPath: String? = nil, name: String? = nil, ascent: Double? = nil,
                calories: Double? = nil, averageHeartRate: Double? = nil, source: String? = nil,
                state: String? = nil, size: Int64? = nil) {
        self.source = source
        self.state = state
        self.size = size
        self.start = start
        self.sport = sport
        self.distance = distance
        self.duration = duration
        self.fitPath = fitPath
        self.name = name
        self.ascent = ascent
        self.calories = calories
        self.averageHeartRate = averageHeartRate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Date.self, forKey: .start)
        sport = try c.decodeIfPresent(String.self, forKey: .sport) ?? "generic"
        distance = try? c.decodeIfPresent(Double.self, forKey: .distance)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        // "FIT path": accept the likely spellings.
        fitPath = (try? c.decodeIfPresent(String.self, forKey: .fitPath))
            ?? (try? c.decodeIfPresent(String.self, forKey: .fit))
            ?? (try? c.decodeIfPresent(String.self, forKey: .path))
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        ascent = try? c.decodeIfPresent(Double.self, forKey: .ascent)
        calories = try? c.decodeIfPresent(Double.self, forKey: .calories)
        averageHeartRate = (try? c.decodeIfPresent(Double.self, forKey: .averageHeartRate))
            ?? (try? c.decodeIfPresent(Double.self, forKey: .avgHeartRate))
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        size = try? c.decodeIfPresent(Int64.self, forKey: .size)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(sport, forKey: .sport)
        try c.encodeIfPresent(distance, forKey: .distance)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(fitPath, forKey: .fitPath)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(ascent, forKey: .ascent)
        try c.encodeIfPresent(calories, forKey: .calories)
        try c.encodeIfPresent(averageHeartRate, forKey: .averageHeartRate)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encodeIfPresent(size, forKey: .size)
    }

    /// Sport names as the FIT profile has them ("running", "cycling", "hiking", …).
    public var systemImage: String {
        switch sport.lowercased() {
        case "running", "trail_running", "treadmill_running": "figure.run"
        case "cycling", "road_cycling", "mountain_biking", "gravel_cycling", "e_biking": "figure.outdoor.cycle"
        case "hiking": "figure.hiking"
        case "walking": "figure.walk"
        case "swimming", "lap_swimming": "figure.pool.swim"
        case "open_water", "open_water_swimming": "figure.open.water.swim"
        case "training", "strength_training": "figure.strengthtraining.traditional"
        case "alpine_skiing", "skiing": "figure.skiing.downhill"
        case "mountaineering": "mountain.2"
        default: "figure.mixed.cardio"
        }
    }

    /// "trail_running" → "Trail Running".
    public var sportName: String {
        sport.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }
}

public struct ActivitiesList: Codable, Sendable, Hashable {
    public var activities: [Activity]
    public var total: Int?

    public init(activities: [Activity], total: Int? = nil) {
        self.activities = activities
        self.total = total
    }
}

/// The track of an activity, for its map and charts: `activities.track {"fit": path}` (once the
/// engine lists that method in `hello`). The engine sends each point as docs/ENGINE.md says:
/// `{"lat", "lon", "time" (ISO 8601), "hr"?, "alt"?, "speed"?}`.
public struct ActivityTrack: Codable, Sendable, Hashable {
    public struct Point: Codable, Sendable, Hashable {
        public var latitude: Double
        public var longitude: Double
        /// Seconds since the start.
        public var time: Double?
        public var elevation: Double?
        public var heartRate: Double?
        public var speed: Double?

        public init(latitude: Double, longitude: Double, time: Double? = nil,
                    elevation: Double? = nil, heartRate: Double? = nil, speed: Double? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.time = time
            self.elevation = elevation
            self.heartRate = heartRate
            self.speed = speed
        }

        // The engine's short names; the long ones are still read (older mocks, tests).
        private enum CodingKeys: String, CodingKey {
            case lat, lon, alt, hr, speed, time
            case latitude, longitude, elevation, heartRate
        }

        /// The point's moment as the engine sends it (ISO 8601); `time` is made from it by
        /// ActivityTrack, relative to the first point.
        fileprivate var date: Date?

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func number(_ keys: CodingKeys...) -> Double? {
                keys.lazy.compactMap { try? c.decodeIfPresent(Double.self, forKey: $0) }.first
            }
            guard let lat = number(.lat, .latitude), let lon = number(.lon, .longitude) else {
                throw DecodingError.dataCorruptedError(forKey: .lat, in: c,
                                                       debugDescription: "a point without a position")
            }
            latitude = lat
            longitude = lon
            elevation = number(.alt, .elevation)
            heartRate = number(.hr, .heartRate)
            speed = number(.speed)
            if let seconds = try? c.decodeIfPresent(Double.self, forKey: .time) {
                time = seconds
            } else if let text = try? c.decodeIfPresent(String.self, forKey: .time) {
                date = EngineCoding.parseDate(text)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(latitude, forKey: .lat)
            try c.encode(longitude, forKey: .lon)
            try c.encodeIfPresent(elevation, forKey: .alt)
            try c.encodeIfPresent(heartRate, forKey: .hr)
            try c.encodeIfPresent(speed, forKey: .speed)
            try c.encodeIfPresent(time, forKey: .time)
        }
    }

    public var points: [Point]

    public init(points: [Point]) { self.points = points }

    private enum CodingKeys: String, CodingKey { case points }

    public init(from decoder: any Decoder) throws {
        var points = try decoder.container(keyedBy: CodingKeys.self).decode([Point].self, forKey: .points)
        // Seconds since the first point, for the charts' axis.
        if let first = points.lazy.compactMap(\.date).first {
            for i in points.indices where points[i].time == nil {
                points[i].time = points[i].date.map { $0.timeIntervalSince(first) }
            }
        }
        self.points = points
    }
}

/// One backup of a device: a folder named "YYYY-MM-DD (HH.MM.SS)" under
/// `<backups>/<unit id>/` (openexpress/backup.py).
public struct BackupSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var created: Date
    public var size: Int64?
    public var files: Int?

    public var id: String { path }

    public init(path: String, created: Date, size: Int64? = nil, files: Int? = nil) {
        self.path = path
        self.created = created
        self.size = size
        self.files = files
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

public struct BackupsList: Codable, Sendable, Hashable {
    public var backups: [BackupSnapshot]

    public init(backups: [BackupSnapshot]) { self.backups = backups }
}

/// `device.backup`.
public struct BackupResult: Codable, Sendable, Hashable {
    public var path: String
    public var copied: Int
    public var copiedBytes: Int64
    public var linked: Int
    public var linkedBytes: Int64
    public var removed: [String]
    /// FIT files the device was still writing: left out.
    public var incomplete: Int

    public init(path: String, copied: Int, copiedBytes: Int64, linked: Int, linkedBytes: Int64,
                removed: [String] = [], incomplete: Int = 0) {
        self.path = path
        self.copied = copied
        self.copiedBytes = copiedBytes
        self.linked = linked
        self.linkedBytes = linkedBytes
        self.removed = removed
        self.incomplete = incomplete
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        copied = try c.decodeIfPresent(Int.self, forKey: .copied) ?? 0
        copiedBytes = try c.decodeIfPresent(Int64.self, forKey: .copiedBytes) ?? 0
        linked = try c.decodeIfPresent(Int.self, forKey: .linked) ?? 0
        linkedBytes = try c.decodeIfPresent(Int64.self, forKey: .linkedBytes) ?? 0
        removed = (try? c.decodeIfPresent([String].self, forKey: .removed)) ?? []
        incomplete = (try? c.decodeIfPresent(Int.self, forKey: .incomplete)) ?? 0
    }
}

/// `device.sync`, applied: `{"uploaded", "downloaded", "skipped_known", "rejected", "errors",
/// "not_confirmed", "steps", "sentence", "drop_folder": {...} or null, "strava": {...} or null}`.
/// Kept whole and read leniently (counts may be numbers or lists).
public struct SyncResult: Sendable, Hashable {
    public var raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }

    private static func count(_ v: JSONValue?) -> Int {
        guard let v else { return 0 }
        if let n = v.intValue { return n }
        if let a = v.arrayValue { return a.count }
        return 0
    }

    public var uploaded: Int { Self.count(raw["uploaded"]) }
    public var downloaded: Int { Self.count(raw["downloaded"]) }
    public var rejected: Int { Self.count(raw["rejected"]) }
    public var errors: Int { Self.count(raw["errors"]) }
    /// The engine's own one-sentence summary, translated.
    public var sentence: String? { raw["sentence"]?.stringValue }
    public var dropFolderCopies: Int { Self.count(raw["drop_folder"]?["copied"]) }
    public var stravaUploads: Int { Self.count(raw["strava"]?["uploaded"]) }
    public var stravaError: String? { raw["strava"]?["error"]?.stringValue }
}

/// Results "as the command line" (`{"exit_code", "lines"}`) and the per-map results of
/// `maps.install` / `maps.remove` (`{"maps": [{"name", "done", "code"?, "reason"?, "lines"?}]}`).
public struct OperationResult: Sendable, Hashable {
    public var raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }

    public var exitCode: Int? { raw["exit_code"]?.intValue }
    public var lines: [String] { raw["lines"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// What the engine refused, by item name, with its reason.
    public var refused: [String: String] {
        var out: [String: String] = [:]
        for item in raw["maps"]?.arrayValue ?? [] where item["done"]?.boolValue == false {
            let name = item["name"]?.stringValue ?? "?"
            out[name] = item["reason"]?.stringValue
                ?? item["lines"]?.arrayValue?.compactMap(\.stringValue).last
                ?? String(localized: "Not done.")
        }
        return out
    }

    /// A refusal to show: the command's last lines when it exited 1, or a map's reason.
    public var failureMessage: String? {
        if let code = exitCode, code != 0 {
            return lines.suffix(3).joined(separator: "\n").nilIfEmpty ?? String(localized: "Not done.")
        }
        return refused.first.map { "\($0.key): \($0.value)" }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
