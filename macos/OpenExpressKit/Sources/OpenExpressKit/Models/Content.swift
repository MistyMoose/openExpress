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

    public init(updates: [SoftwareUpdate], betaOffered: Bool = false) {
        self.updates = updates
        self.betaOffered = betaOffered
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updates = try c.decodeIfPresent([SoftwareUpdate].self, forKey: .updates) ?? []
        betaOffered = try c.decodeIfPresent(Bool.self, forKey: .betaOffered) ?? false
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

    public var id: String { name }

    public init(name: String, version: String?, size: Int64, installed: Bool, status: Status,
                region: String? = nil) {
        self.name = name
        self.version = version
        self.size = size
        self.installed = installed
        self.status = status
        self.region = region
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? (installed ? .upToDate : .available)
        region = try c.decodeIfPresent(String.self, forKey: .region)
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
        name = (try? c.decode(String.self, forKey: .name)) ?? (try? c.decode(String.self, forKey: .file)) ?? "?"
        size = try? c.decodeIfPresent(Int64.self, forKey: .size)
    }

    enum CodingKeys: String, CodingKey { case name, file, size }

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

    public init(maps: [DeviceMap], ownMaps: [OwnMap] = [], free: Int64? = nil) {
        self.maps = maps
        self.ownMaps = ownMaps
        self.free = free
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maps = try c.decodeIfPresent([DeviceMap].self, forKey: .maps) ?? []
        ownMaps = try c.decodeIfPresent([OwnMap].self, forKey: .ownMaps) ?? []
        free = try c.decodeIfPresent(Int64.self, forKey: .free)
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

public struct AppsList: Codable, Sendable, Hashable {
    public var apps: [ConnectIQApp]

    public init(apps: [ConnectIQApp]) { self.apps = apps }

    public init(from decoder: any Decoder) throws {
        // `{"apps": [...]}` or a bare list.
        if let list = try? decoder.singleValueContainer().decode([ConnectIQApp].self) {
            apps = list
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            apps = try c.decodeIfPresent([ConnectIQApp].self, forKey: .apps) ?? []
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

    public var id: String { fitPath ?? start.ISO8601Format() }

    enum CodingKeys: String, CodingKey {
        case start, sport, distance, duration, fitPath, fit, path, name, ascent, calories
        case averageHeartRate, avgHeartRate
    }

    public init(start: Date, sport: String, distance: Double? = nil, duration: Double? = nil,
                fitPath: String? = nil, name: String? = nil, ascent: Double? = nil,
                calories: Double? = nil, averageHeartRate: Double? = nil) {
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

    public init(activities: [Activity]) { self.activities = activities }
}

/// The track of an activity, for its map and charts. Not in docs/ENGINE.md yet: asked with
/// `activities.track {"fit": path}` once the engine lists that method in `hello`.
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
    }

    public var points: [Point]

    public init(points: [Point]) { self.points = points }
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

    public init(path: String, copied: Int, copiedBytes: Int64, linked: Int, linkedBytes: Int64,
                removed: [String] = []) {
        self.path = path
        self.copied = copied
        self.copiedBytes = copiedBytes
        self.linked = linked
        self.linkedBytes = linkedBytes
        self.removed = removed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        copied = try c.decodeIfPresent(Int.self, forKey: .copied) ?? 0
        copiedBytes = try c.decodeIfPresent(Int64.self, forKey: .copiedBytes) ?? 0
        linked = try c.decodeIfPresent(Int.self, forKey: .linked) ?? 0
        linkedBytes = try c.decodeIfPresent(Int64.self, forKey: .linkedBytes) ?? 0
        removed = try c.decodeIfPresent([String].self, forKey: .removed) ?? []
    }
}

/// `device.sync`: docs/ENGINE.md says "upload / download counts, drop-folder copies, Strava
/// uploads" without naming the keys, so the result is kept whole and read leniently.
public struct SyncResult: Sendable, Hashable {
    public var raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }

    private func count(_ keys: String...) -> Int {
        for k in keys {
            if let v = raw[k] {
                if let n = v.intValue { return n }
                if let a = v.arrayValue { return a.count }
            }
        }
        return 0
    }

    public var uploaded: Int { count("uploaded", "uploads", "upload") }
    public var downloaded: Int { count("downloaded", "downloads", "download") }
    public var dropFolderCopies: Int { count("drop_folder", "copied_to_drop_folder", "drop_folder_copies") }
    public var stravaUploads: Int { count("strava", "strava_uploads") }
}

/// What `updates.install` and the maps methods did, per item. Kept whole and read leniently.
public struct OperationResult: Sendable, Hashable {
    public var raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }

    /// Reasons the engine refused items, by item name.
    public var refused: [String: String] {
        var out: [String: String] = [:]
        for (k, v) in raw.objectValue ?? [:] {
            if let reason = v["refused"]?.stringValue ?? v["reason"]?.stringValue { out[k] = reason }
        }
        return out
    }
}
