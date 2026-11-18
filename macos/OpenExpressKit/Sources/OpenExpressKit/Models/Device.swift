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
    /// The newest backup in the backup folder.
    public var lastBackup: Date?

    public var id: String { unitID }

    enum CodingKeys: String, CodingKey {
        // With .convertFromSnakeCase "unit_id" arrives as "unitId".
        case unitID = "unitId"
        case name, partNumber, software, connected, busyBy, storage, lastSync, lastBackup
    }

    public init(
        unitID: String, name: String, partNumber: String? = nil, software: String? = nil,
        connected: Bool, busyBy: String? = nil, storage: Storage? = nil, lastSync: Date? = nil,
        lastBackup: Date? = nil
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
    }

    /// The name without its variant: "fēnix 8 – 47 mm, AMOLED" → "fēnix 8", for titles.
    public var shortName: String {
        var cut = name.endIndex
        for sep in [" – ", " — ", " - ", " (", ", "] {
            if let r = name.range(of: sep), r.lowerBound < cut { cut = r.lowerBound }
        }
        let short = name[..<cut].trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? name : short
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
    public var environment: String?

    public init(signedIn: Bool, account: String? = nil, setupDone: Bool, environment: String? = nil) {
        self.signedIn = signedIn
        self.account = account
        self.setupDone = setupDone
        self.environment = environment
    }
}

public struct EngineHello: Codable, Sendable, Hashable {
    public var engine: String
    public var protocolVersion: Int?
    public var platform: String
    public var methods: [String]

    enum CodingKeys: String, CodingKey {
        case engine, platform, methods
        case protocolVersion = "protocol"
    }

    public init(engine: String, protocolVersion: Int? = 1, platform: String, methods: [String]) {
        self.engine = engine
        self.protocolVersion = protocolVersion
        self.platform = platform
        self.methods = methods
    }

    public func supports(_ method: String) -> Bool { methods.contains(method) }
}

/// `strava.status`: `{"configured", "connected", "athlete_id", "athlete_name", "scope", "expires_at"}`.
public struct StravaStatus: Codable, Sendable, Hashable {
    /// A client ID and secret are saved.
    public var configured: Bool
    public var connected: Bool
    public var athleteName: String?
    /// What openExpress may do on Strava, e.g. "read,activity:write".
    public var scope: String?
    /// `strava.connect` without `code`: the page to open.
    public var authorizeURL: String?

    enum CodingKeys: String, CodingKey {
        case configured, connected, athleteName, scope
        case authorizeURL = "authorizeUrl"
    }

    public init(configured: Bool = true, connected: Bool, athleteName: String? = nil, authorizeURL: String? = nil) {
        self.configured = configured
        self.connected = connected
        self.athleteName = athleteName
        self.authorizeURL = authorizeURL
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connected = (try? c.decode(Bool.self, forKey: .connected)) ?? false
        configured = (try? c.decode(Bool.self, forKey: .configured)) ?? connected
        athleteName = try? c.decodeIfPresent(String.self, forKey: .athleteName)
        scope = try? c.decodeIfPresent(String.self, forKey: .scope)
        authorizeURL = try? c.decodeIfPresent(String.self, forKey: .authorizeURL)
    }
}
