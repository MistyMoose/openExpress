import Foundation

/// A Garmin device, connected or remembered (docs/ENGINE.md, "Objects").
public struct Device: Codable, Sendable, Hashable, Identifiable {
    public struct Storage: Codable, Sendable, Hashable {
        public var free: Int64
        public var capacity: Int64

        public init(free: Int64, capacity: Int64) {
            self.free = free
            self.capacity = capacity
        }

        public var used: Int64 { max(0, capacity - free) }
        public var usedFraction: Double { capacity > 0 ? Double(used) / Double(capacity) : 0 }
    }

    /// Unit IDs travel as strings: they exceed 2^31.
    public var unitID: String
    public var name: String
    public var partNumber: String?
    public var software: String?
    public var connected: Bool
    public var busyBy: String?
    public var storage: Storage?
    public var lastSync: Date?
    /// Not in docs/ENGINE.md yet: shown when the engine sends it.
    public var lastBackup: Date?
    /// Not in docs/ENGINE.md yet: battery level 0…100 when the engine sends it.
    public var battery: Int?

    public var id: String { unitID }

    enum CodingKeys: String, CodingKey {
        // With .convertFromSnakeCase "unit_id" arrives as "unitId".
        case unitID = "unitId"
        case name, partNumber, software, connected, busyBy, storage, lastSync, lastBackup, battery
    }

    public init(
        unitID: String, name: String, partNumber: String? = nil, software: String? = nil,
        connected: Bool, busyBy: String? = nil, storage: Storage? = nil, lastSync: Date? = nil,
        lastBackup: Date? = nil, battery: Int? = nil
    ) {
        self.unitID = unitID
        self.name = name
        self.partNumber = partNumber
        self.software = software
        self.connected = connected
        self.busyBy = busyBy
        self.storage = storage
        self.lastSync = lastSync
        self.lastBackup = lastBackup
        self.battery = battery
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Accept a number too, should the engine ever send one.
        if let s = try? c.decode(String.self, forKey: .unitID) {
            unitID = s
        } else {
            unitID = String(try c.decode(Int64.self, forKey: .unitID))
        }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        partNumber = try c.decodeIfPresent(String.self, forKey: .partNumber)
        software = try c.decodeIfPresent(String.self, forKey: .software)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        busyBy = try c.decodeIfPresent(String.self, forKey: .busyBy)
        storage = try c.decodeIfPresent(Storage.self, forKey: .storage)
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        lastBackup = try c.decodeIfPresent(Date.self, forKey: .lastBackup)
        battery = try c.decodeIfPresent(Int.self, forKey: .battery)
    }

    /// The kind of device, guessed from its product name, for its SF Symbol.
    public var kind: Kind { Kind(productName: name) }

    public enum Kind: String, Sendable, CaseIterable {
        case watch, bikeComputer, bikeLight, navigator, satelliteCommunicator, other

        public init(productName: String) {
            let n = productName.lowercased()
            if n.hasPrefix("edge") { self = .bikeComputer }
            else if n.hasPrefix("varia") { self = .bikeLight }
            else if n.hasPrefix("drive") || n.hasPrefix("zūmo") || n.hasPrefix("zumo")
                || n.hasPrefix("dēzl") || n.hasPrefix("camper") { self = .navigator }
            else if n.hasPrefix("inreach") || n.hasPrefix("gpsmap") || n.hasPrefix("etrex")
                || n.hasPrefix("montana") { self = .satelliteCommunicator }
            else if n.isEmpty { self = .other }
            else { self = .watch }
        }

        public var systemImage: String {
            switch self {
            case .watch: "watch.analog"
            case .bikeComputer: "bicycle"
            case .bikeLight: "light.beacon.max"
            case .navigator: "car.fill"
            case .satelliteCommunicator: "antenna.radiowaves.left.and.right"
            case .other: "externaldrive.connected.to.line.below"
            }
        }
    }
}

public struct AccountStatus: Codable, Sendable, Hashable {
    public var signedIn: Bool
    /// Masked, e.g. "j***@e***.com".
    public var account: String?
    public var setupDone: Bool

    public init(signedIn: Bool, account: String? = nil, setupDone: Bool) {
        self.signedIn = signedIn
        self.account = account
        self.setupDone = setupDone
    }
}

public struct EngineHello: Codable, Sendable, Hashable {
    public var engine: String
    public var platform: String
    public var methods: [String]

    public init(engine: String, platform: String, methods: [String]) {
        self.engine = engine
        self.platform = platform
        self.methods = methods
    }

    public func supports(_ method: String) -> Bool { methods.contains(method) }
}

/// `strava.status`: docs/ENGINE.md points at strava.py; the app reads only these fields.
public struct StravaStatus: Codable, Sendable, Hashable {
    public var connected: Bool
    public var athlete: String?

    public init(connected: Bool, athlete: String? = nil) {
        self.connected = connected
        self.athlete = athlete
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = (try? c.decode(Bool.self, forKey: .connected))
            ?? (try? c.decode(Bool.self, forKey: .signedIn)) ?? false
        athlete = try? c.decodeIfPresent(String.self, forKey: .athlete)
    }

    enum CodingKeys: String, CodingKey { case connected, signedIn, athlete }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connected, forKey: .connected)
        try c.encodeIfPresent(athlete, forKey: .athlete)
    }
}
