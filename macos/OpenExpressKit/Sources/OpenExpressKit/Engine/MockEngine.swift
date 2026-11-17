import Foundation

/// An engine in memory, speaking the same protocol as the real one: for SwiftUI previews,
/// tests and `OPENEXPRESS_ENGINE=mock`. It never touches a device or the network.
public actor MockEngine: EngineConnection {
    public enum Scenario: String, Sendable, CaseIterable {
        /// A fēnix 8 connected with updates, an Edge 1050 remembered; signed in.
        case standard
        /// The fēnix 8 is held by Garmin Express Service.
        case busy
        /// Setup not done, not signed in.
        case firstRun
        /// Set up, not signed in.
        case signedOut
        /// No devices.
        case empty
    }

    public let scenario: Scenario
    /// How long each simulated step of a long operation takes.
    public var stepDelay: Duration
    private let broadcaster = EventBroadcaster()
    private var nextID = 1
    private(set) public var calls: [EngineRequest] = []
    private var account: AccountStatus
    private var stravaConnected = false
    private var devices: [Device]
    private var updates: [String: [SoftwareUpdate]]
    private var maps: [String: [DeviceMap]]
    private var settings: [String: JSONValue] = ["copy_fit_to": "", "copy_fit_types": ""]
    private var backups: [String: [BackupSnapshot]] = [:]

    public static let fenixID = "3491967800"
    public static let edgeID = "3398172205"

    public init(scenario: Scenario = .standard, stepDelay: Duration = .milliseconds(350)) {
        self.scenario = scenario
        self.stepDelay = stepDelay
        let now = Date()
        account = switch scenario {
        case .firstRun: AccountStatus(signedIn: false, account: nil, setupDone: false)
        case .signedOut: AccountStatus(signedIn: false, account: nil, setupDone: true)
        default: AccountStatus(signedIn: true, account: "j***@b***.net", setupDone: true)
        }
        let fenix = Device(
            unitID: Self.fenixID, name: "fēnix 8 – 47 mm, AMOLED", partNumber: "006-B4536-00",
            software: "21.19", connected: true,
            busyBy: scenario == .busy ? "Garmin Express Service" : nil,
            storage: .init(free: 18_740_000_000, capacity: 31_200_000_000),
            lastSync: now.addingTimeInterval(-3600 * 26), lastBackup: now.addingTimeInterval(-3600 * 26),
            battery: 76)
        let edge = Device(
            unitID: Self.edgeID, name: "Edge 1050", partNumber: "006-B4440-00", software: "33.20",
            connected: false, storage: .init(free: 41_000_000_000, capacity: 59_600_000_000),
            lastSync: now.addingTimeInterval(-86400 * 9))
        devices = scenario == .empty ? [] : [fenix, edge]
        updates = [
            Self.fenixID: [
                SoftwareUpdate(part: "006-B4536-00", name: "System Software", version: "21.22",
                               installed: "21.19", size: 412_000_000),
                SoftwareUpdate(part: "006-B3290-00", name: "GPS Chipset", version: "8.10",
                               installed: "8.04", size: 2_400_000),
                SoftwareUpdate(part: "006-B4536-BETA", name: "System Software (Beta)", version: "22.05",
                               installed: "21.19", size: 418_000_000, beta: true),
            ],
            Self.edgeID: [
                SoftwareUpdate(part: "006-B4440-00", name: "System Software", version: "33.21",
                               installed: "33.20", size: 97_700_000, beta: true),
            ],
        ]
        maps = [
            Self.fenixID: [
                DeviceMap(name: "TopoActive Europe", version: "2025.20", size: 9_800_000_000, installed: true, status: .update, region: "Europe"),
                DeviceMap(name: "Ski Resorts", version: "2025.10", size: 120_000_000, installed: true, status: .upToDate),
                DeviceMap(name: "CourseView Golf", version: "2025.30", size: 1_300_000_000, installed: true, status: .upToDate),
                DeviceMap(name: "TopoActive North America", version: "2025.20", size: 11_200_000_000, installed: false, status: .available, region: "North America"),
                DeviceMap(name: "TopoActive Australia & New Zealand", version: "2025.20", size: 3_100_000_000, installed: false, status: .available, region: "Oceania"),
            ],
            Self.edgeID: [
                DeviceMap(name: "TopoActive Europe", version: "2025.20", size: 9_800_000_000, installed: true, status: .upToDate, region: "Europe"),
            ],
        ]
        for id in [Self.fenixID, Self.edgeID] {
            backups[id] = (0..<3).map { i in
                let date = now.addingTimeInterval(-86400 * Double(i * 7 + 1))
                return BackupSnapshot(path: "/Users/demo/Documents/Garmin/Backups/\(id)/\(Self.stamp(date))",
                                      created: date, size: 1_200_000_000 - Int64(i) * 40_000_000, files: 4210 - i * 50)
            }
        }
    }

    public func start() async throws {}

    public func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }

    public func shutdown() async { broadcaster.finish() }

    /// Simulates plugging in the remembered Edge (for previews and tests).
    public func simulateAttach(_ unitID: String = edgeID) {
        guard let i = devices.firstIndex(where: { $0.unitID == unitID }) else { return }
        devices[i].connected = true
        broadcaster.yield(.deviceAttached(devices[i]))
    }

    public func simulateDetach(_ unitID: String) {
        guard let i = devices.firstIndex(where: { $0.unitID == unitID }) else { return }
        devices[i].connected = false
        broadcaster.yield(.deviceDetached(devices[i]))
    }

    public func simulateBusy(_ unitID: String, program: String = "Garmin Express Service") {
        guard let i = devices.firstIndex(where: { $0.unitID == unitID }) else { return }
        devices[i].busyBy = program
        broadcaster.yield(.deviceBusy(DeviceBusy(device: unitID, program: program)))
    }

    public func call(_ method: String, params: JSONValue?,
                     progress: (@Sendable (EngineProgress) -> Void)?) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        calls.append(EngineRequest(id: id, method: method, params: params))
        let p = params ?? .object([:])
        let unit = p["device"]?.stringValue
        if let unit, let d = devices.first(where: { $0.unitID == unit }) {
            if let busy = d.busyBy, method != "device.info" {
                throw EngineError.remote(
                    code: "device_busy",
                    message: "\(busy) is using the device. Quit it, then try again.",
                    data: ["program": .string(busy)])
            }
            if !d.connected, ["device.backup", "device.sync", "updates.install", "maps.install",
                              "maps.update", "maps.remove", "apps.list"].contains(method) {
                throw EngineError.remote(code: "device_not_connected",
                                         message: "\(d.name) is not connected.", data: nil)
            }
        }
        switch method {
        case "hello":
            return try JSONValue(encoding: EngineHello(engine: "0.0-mock", platform: "darwin", methods: Self.methods))
        case "account.status":
            return try JSONValue(encoding: account)
        case "account.setup":
            account.setupDone = true
            return [:]
        case "account.sign_in_url":
            return ["url": "https://sso.garmin.com/sso/embed?mock=1"]
        case "account.sign_in":
            guard p["ticket_url"]?.stringValue?.contains("ticket=ST-") == true else {
                throw EngineError.remote(code: "bad_ticket", message: "That is not a sign-in ticket.", data: nil)
            }
            account.signedIn = true
            account.account = "j***@b***.net"
            return ["account": .string(account.account!)]
        case "account.sign_out":
            account.signedIn = false
            account.account = nil
            return [:]
        case "devices.list":
            return ["devices": .array(try devices.map { try JSONValue(encoding: $0) })]
        case "device.info":
            guard let d = devices.first(where: { $0.unitID == unit }) else { throw Self.noDevice }
            return try JSONValue(encoding: d)
        case "device.backup":
            try await simulate(id, phases: [("reading", 12)], item: "Activities", progress: progress)
            let now = Date()
            let path = "/Users/demo/Documents/Garmin/Backups/\(unit ?? "")/\(Self.stamp(now))"
            if p["apply"]?.boolValue == true, let unit {
                backups[unit, default: []].insert(BackupSnapshot(path: path, created: now, size: 1_210_000_000, files: 4260), at: 0)
                if let i = devices.firstIndex(where: { $0.unitID == unit }) { devices[i].lastBackup = now }
            }
            return try JSONValue(encoding: BackupResult(path: path, copied: 37, copiedBytes: 18_400_000,
                                                        linked: 4223, linkedBytes: 1_191_600_000))
        case "device.sync":
            try await simulate(id, phases: [("uploading", 6), ("downloading", 3)], item: nil, progress: progress)
            if p["apply"]?.boolValue == true, let i = devices.firstIndex(where: { $0.unitID == unit }) {
                devices[i].lastSync = Date()
            }
            return ["uploaded": 4, "downloaded": 1, "drop_folder": 2, "strava": stravaConnected ? 1 : 0]
        case "updates.list":
            return ["updates": .array(try (updates[unit ?? ""] ?? []).map { try JSONValue(encoding: $0) }),
                    "beta_offered": .bool(updates[unit ?? ""]?.contains(where: \.beta) == true)]
        case "updates.install":
            guard let unit else { throw Self.noDevice }
            let wanted: [String]? = p["parts"]?.arrayValue?.compactMap(\.stringValue)
            var done: [String: JSONValue] = [:]
            for (i, u) in (updates[unit] ?? []).enumerated() where wanted?.contains(u.part) ?? !u.beta {
                try await simulate(id, phases: [("downloading", 8), ("copying", 4)], item: u.name,
                                   total: u.size, progress: progress)
                updates[unit]?[i].waitingOnDevice = true
                done[u.part] = ["done": true]
            }
            return .object(done)
        case "maps.list":
            return ["maps": .array(try (maps[unit ?? ""] ?? []).map { try JSONValue(encoding: $0) }),
                    "own_maps": [["name": "Alps-Contours.img", "size": 245_000_000]],
                    "free": .number(Double(devices.first { $0.unitID == unit }?.storage?.free ?? 0))]
        case "maps.install", "maps.update", "maps.remove":
            guard let unit else { throw Self.noDevice }
            var done: [String: JSONValue] = [:]
            for name in p["maps"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                guard let i = maps[unit]?.firstIndex(where: { $0.name == name }) else {
                    done[name] = ["refused": "No such map."]
                    continue
                }
                if method == "maps.remove" {
                    maps[unit]?[i].installed = false
                    maps[unit]?[i].status = .available
                } else {
                    try await simulate(id, phases: [("downloading", 10), ("copying", 4)], item: name,
                                       total: maps[unit]?[i].size, progress: progress)
                    maps[unit]?[i].installed = true
                    maps[unit]?[i].status = .upToDate
                }
                done[name] = ["done": true]
            }
            return .object(done)
        case "apps.list":
            return ["apps": [
                ["name": "Strava Live Segments", "version": "2.4.1", "type": "datafield", "size": 180_000],
                ["name": "Spotify", "version": "3.0.0", "type": "audio-content-provider", "size": 2_100_000],
                ["name": "Klimat", "version": "1.2", "type": "widget", "size": 64_000],
                ["name": "Crystal Face", "version": "2.13", "type": "watchface", "size": 120_000, "update_available": true],
            ]]
        case "activities.list":
            return ["activities": .array(try Self.sampleActivities(unit: unit).map { try JSONValue(encoding: $0) })]
        case "activities.track":
            return try JSONValue(encoding: Self.sampleTrack())
        case "backups.list":
            return ["backups": .array(try (backups[unit ?? ""] ?? []).map { try JSONValue(encoding: $0) })]
        case "settings.get":
            let key = p["key"]?.stringValue ?? ""
            return ["key": .string(key), "value": settings[key] ?? .null]
        case "settings.set":
            let key = p["key"]?.stringValue ?? ""
            settings[key] = p["value"] ?? .null
            return ["key": .string(key), "value": settings[key] ?? .null]
        case "strava.status":
            return ["connected": .bool(stravaConnected), "athlete": stravaConnected ? "Demo Athlete" : .null]
        case "strava.connect":
            stravaConnected = true
            return ["connected": true]
        case "strava.disconnect":
            stravaConnected = false
            return [:]
        case "cancel", "shutdown":
            return [:]
        default:
            throw EngineError.remote(code: "unknown_method", message: "Unknown method \(method).", data: nil)
        }
    }

    public static let methods = [
        "hello", "account.status", "account.setup", "account.sign_in_url", "account.sign_in",
        "account.sign_out", "devices.list", "device.info", "device.backup", "device.sync",
        "updates.list", "updates.install", "maps.list", "maps.install", "maps.update", "maps.remove",
        "apps.list", "activities.list", "activities.track", "backups.list", "settings.get",
        "settings.set", "strava.status", "strava.connect", "strava.disconnect", "cancel", "shutdown",
    ]

    private static let noDevice = EngineError.remote(code: "no_device", message: "No such device.", data: nil)

    private func simulate(_ request: Int, phases: [(String, Int)], item: String?, total: Int64? = nil,
                          progress: (@Sendable (EngineProgress) -> Void)?) async throws {
        for (phase, steps) in phases {
            let total = total ?? Int64(steps)
            for step in 0...steps {
                try Task.checkCancellation()
                let ev = EngineProgress(request: request, phase: phase, done: total * Int64(step) / Int64(steps),
                                        total: total, item: item)
                progress?(ev)
                broadcaster.yield(.progress(ev))
                if step < steps { try await Task.sleep(for: stepDelay) }
            }
        }
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd (HH.mm.ss)"
        return f.string(from: date)
    }

    public static func sampleActivities(unit: String? = fenixID) -> [Activity] {
        let sports = ["running", "cycling", "hiking", "trail_running", "lap_swimming", "walking", "strength_training"]
        let now = Date()
        return (0..<24).map { i in
            let sport = sports[(i * 5 + 3) % sports.count]
            let duration = Double(1800 + (i * 977) % 5400)
            let speed: Double = switch sport {
            case "cycling": 8.1
            case "running", "trail_running": 3.1
            case "lap_swimming": 0.8
            case "strength_training": 0
            default: 1.4
            }
            return Activity(
                start: now.addingTimeInterval(-Double(i) * 86400 * 1.3 - 7200),
                sport: sport,
                distance: speed > 0 ? duration * speed : nil,
                duration: duration,
                fitPath: "/Users/demo/Documents/Garmin/Backups/\(unit ?? fenixID)/Activity/2026-\(i).fit",
                ascent: sport == "lap_swimming" || speed == 0 ? nil : Double(40 + (i * 37) % 600),
                calories: duration / 6,
                averageHeartRate: Double(118 + (i * 7) % 40))
        }
    }

    public static func sampleTrack() -> ActivityTrack {
        // A loop around the Utrechtse Heuvelrug.
        let n = 240
        return ActivityTrack(points: (0..<n).map { i in
            let t = Double(i) / Double(n) * 2 * .pi
            let lat = 52.06 + 0.018 * sin(t) + 0.004 * sin(3 * t)
            let lon = 5.30 + 0.03 * cos(t) + 0.005 * cos(5 * t)
            return .init(latitude: lat, longitude: lon, time: Double(i) * 15,
                         elevation: 20 + 18 * sin(2 * t) + 6 * sin(7 * t),
                         heartRate: 132 + 18 * sin(t * 1.5) + 4 * sin(t * 9),
                         speed: 3.0 + 0.4 * sin(4 * t))
        })
    }
}
