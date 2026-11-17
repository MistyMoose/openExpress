import Foundation

/// Something that speaks the engine protocol of docs/ENGINE.md: the real engine process
/// (`EngineClient`) or the in-memory `MockEngine` of previews and tests.
public protocol EngineConnection: AnyObject, Sendable {
    /// Starts the engine if it is not running.
    func start() async throws

    /// Sends a request and waits for its response. `progress` gets the `progress` events of
    /// this request. Cancelling the calling task sends `cancel` for it; the engine stops at
    /// the next safe point and the call throws `EngineError.cancelled` (or returns, when the
    /// engine finished first).
    func call(_ method: String, params: JSONValue?,
              progress: (@Sendable (EngineProgress) -> Void)?) async throws -> JSONValue

    /// A new stream of every event from now on; each subscriber gets its own.
    func events() async -> AsyncStream<EngineEvent>

    /// Asks the engine to exit and waits briefly for it.
    func shutdown() async
}

extension EngineConnection {
    public func call(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        try await call(method, params: params, progress: nil)
    }

    func call<T: Decodable>(_ method: String, params: JSONValue? = nil, as: T.Type,
                            progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> T {
        let value = try await call(method, params: params, progress: progress)
        do {
            return try value.decode(T.self)
        } catch {
            throw EngineError.unexpectedResult(method: method, detail: String(describing: error))
        }
    }
}

/// The methods of docs/ENGINE.md, typed.
extension EngineConnection {
    public func hello(client: String) async throws -> EngineHello {
        try await call("hello", params: ["client": .string(client)], as: EngineHello.self)
    }

    // MARK: Account

    public func accountStatus() async throws -> AccountStatus {
        try await call("account.status", as: AccountStatus.self)
    }

    public func accountSetup(installer: URL) async throws {
        _ = try await call("account.setup", params: ["installer": .string(installer.path)])
    }

    public func signInURL() async throws -> URL {
        let v = try await call("account.sign_in_url")
        guard let s = v["url"]?.stringValue, let url = URL(string: s) else {
            throw EngineError.unexpectedResult(method: "account.sign_in_url", detail: "no url")
        }
        return url
    }

    @discardableResult
    public func signIn(ticketURL: String) async throws -> String? {
        try await call("account.sign_in", params: ["ticket_url": .string(ticketURL)])["account"]?.stringValue
    }

    public func signOut() async throws {
        _ = try await call("account.sign_out")
    }

    // MARK: Devices

    public func devices() async throws -> [Device] {
        try await call("devices.list", as: DevicesList.self).devices
    }

    public func deviceInfo(_ unitID: String) async throws -> Device {
        try await call("device.info", params: ["device": .string(unitID)], as: Device.self)
    }

    public func backup(_ unitID: String, destination: URL? = nil, keep: Int? = nil, apply: Bool = true,
                       progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> BackupResult {
        var p: [String: JSONValue] = ["device": .string(unitID), "apply": .bool(apply)]
        if let destination { p["dest"] = .string(destination.path) }
        if let keep { p["keep"] = .number(Double(keep)) }
        return try await call("device.backup", params: .object(p), as: BackupResult.self, progress: progress)
    }

    public func sync(_ unitID: String, apply: Bool = true, types: [String]? = nil,
                     progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> SyncResult {
        var p: [String: JSONValue] = ["device": .string(unitID), "apply": .bool(apply)]
        if let types { p["types"] = .array(types.map { .string($0) }) }
        return SyncResult(raw: try await call("device.sync", params: .object(p), progress: progress))
    }

    // MARK: Updates and maps

    public func updates(_ unitID: String) async throws -> UpdatesList {
        try await call("updates.list", params: ["device": .string(unitID)], as: UpdatesList.self)
    }

    /// `parts`: nil installs all.
    public func installUpdates(_ unitID: String, parts: [String]?, apply: Bool = true,
                               progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> OperationResult {
        let partsValue: JSONValue = parts.map { .array($0.map { .string($0) }) } ?? .string("all")
        return OperationResult(raw: try await call(
            "updates.install",
            params: ["device": .string(unitID), "parts": partsValue, "apply": .bool(apply)],
            progress: progress))
    }

    public func maps(_ unitID: String, all: Bool = true) async throws -> MapsList {
        try await call("maps.list", params: ["device": .string(unitID), "all": .bool(all)], as: MapsList.self)
    }

    public func maps(_ action: MapAction, _ unitID: String, names: [String], apply: Bool = true,
                     progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> OperationResult {
        OperationResult(raw: try await call(
            "maps.\(action.rawValue)",
            params: ["device": .string(unitID), "maps": .array(names.map { .string($0) }), "apply": .bool(apply)],
            progress: progress))
    }

    // MARK: Apps, activities, backups

    public func apps(_ unitID: String) async throws -> [ConnectIQApp] {
        try await call("apps.list", params: ["device": .string(unitID)], as: AppsList.self).apps
    }

    public func activities(_ unitID: String?, limit: Int? = nil) async throws -> [Activity] {
        var p: [String: JSONValue] = [:]
        if let unitID { p["device"] = .string(unitID) }
        if let limit { p["limit"] = .number(Double(limit)) }
        return try await call("activities.list", params: .object(p), as: ActivitiesList.self).activities
    }

    /// Not in docs/ENGINE.md yet (see ActivityTrack).
    public func activityTrack(fitPath: String) async throws -> ActivityTrack {
        try await call("activities.track", params: ["fit": .string(fitPath)], as: ActivityTrack.self)
    }

    /// Not in docs/ENGINE.md yet: `backups.list {"device", "dest"?}` → `{"backups": [...]}`.
    /// `BackupFolder.snapshots` reads the folder itself while the engine lacks the method.
    public func backups(_ unitID: String, destination: URL?) async throws -> [BackupSnapshot] {
        var p: [String: JSONValue] = ["device": .string(unitID)]
        if let destination { p["dest"] = .string(destination.path) }
        return try await call("backups.list", params: .object(p), as: BackupsList.self).backups
    }

    // MARK: Settings, Strava

    public func setting(_ key: String) async throws -> JSONValue {
        let v = try await call("settings.get", params: ["key": .string(key)])
        return v["value"] ?? v
    }

    public func setSetting(_ key: String, _ value: JSONValue) async throws {
        _ = try await call("settings.set", params: ["key": .string(key), "value": value])
    }

    public func stravaStatus() async throws -> StravaStatus {
        try await call("strava.status", as: StravaStatus.self)
    }

    public func stravaConnect() async throws -> JSONValue { try await call("strava.connect") }

    public func stravaDisconnect() async throws {
        _ = try await call("strava.disconnect")
    }
}

public enum MapAction: String, Sendable { case install, update, remove }

struct DevicesList: Decodable { var devices: [Device] }
