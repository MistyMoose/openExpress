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

    public func sync(_ unitID: String, apply: Bool = true, types: [String]? = nil, firstRun: FirstSync? = nil,
                     progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> SyncResult {
        var p: [String: JSONValue] = ["device": .string(unitID), "apply": .bool(apply)]
        if let types { p["types"] = .array(types.map { .string($0) }) }
        if let firstRun { p["first_run"] = .string(firstRun.rawValue) }
        return SyncResult(raw: try await call("device.sync", params: .object(p), progress: progress))
    }

    // MARK: Updates and maps

    public func updates(_ unitID: String,
                        progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> UpdatesList {
        try await call("updates.list", params: ["device": .string(unitID)], as: UpdatesList.self, progress: progress)
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

    public func maps(_ unitID: String, all: Bool = true,
                     progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> MapsList {
        try await call("maps.list", params: ["device": .string(unitID), "all": .bool(all)], as: MapsList.self,
                       progress: progress)
    }

    /// `maps.install` / `maps.remove`, one map after the other.
    public func maps(_ action: MapAction, _ unitID: String, names: [String], apply: Bool = true,
                     progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> OperationResult {
        OperationResult(raw: try await call(
            "maps.\(action.rawValue)",
            params: ["device": .string(unitID), "maps": .array(names.map { .string($0) }), "apply": .bool(apply)],
            progress: progress))
    }

    /// `maps.update`: every installed map that has an update.
    public func updateAllMaps(_ unitID: String, apply: Bool = true,
                              progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> OperationResult {
        OperationResult(raw: try await call(
            "maps.update", params: ["device": .string(unitID), "apply": .bool(apply)], progress: progress))
    }

    // MARK: Apps, activities, backups

    public func apps(_ unitID: String,
                     progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> AppsList {
        try await call("apps.list", params: ["device": .string(unitID)], as: AppsList.self, progress: progress)
    }

    /// The first read of a device takes a while (every FIT file over MTP); it reports
    /// `progress` with phase `reading_activities`, done/total in files.
    /// Every activity: the engine keeps their summaries on disk, so only the first read is slow.
    public static var allActivities: Int { 100_000 }

    public func activities(_ unitID: String?, limit: Int? = Self.allActivities,
                           progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws -> [Activity] {
        var p: [String: JSONValue] = [:]
        if let unitID { p["device"] = .string(unitID) }
        if let limit { p["limit"] = .number(Double(limit)) }
        return try await call("activities.list", params: .object(p), as: ActivitiesList.self, progress: progress).activities
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

    /// `settings.get` without a key: every setting.
    public func settings() async throws -> [String: JSONValue] {
        try await call("settings.get")["settings"]?.objectValue ?? [:]
    }

    public func stravaStatus() async throws -> StravaStatus {
        try await call("strava.status", as: StravaStatus.self)
    }

    /// Without `code`: the status and the `authorize_url` to open (client ID and secret saved
    /// first when given). With the `code` Strava's redirect brought: connects.
    public func stravaConnect(redirectURI: String, code: String? = nil, clientID: String? = nil,
                              clientSecret: String? = nil) async throws -> StravaStatus {
        var p: [String: JSONValue] = ["redirect_uri": .string(redirectURI)]
        if let code { p["code"] = .string(code) }
        if let clientID, !clientID.isEmpty { p["client_id"] = .string(clientID) }
        if let clientSecret, !clientSecret.isEmpty { p["client_secret"] = .string(clientSecret) }
        return try await call("strava.connect", params: .object(p), as: StravaStatus.self)
    }

    public func stravaDisconnect() async throws {
        _ = try await call("strava.disconnect")
    }

    /// `strava.upload`: `{"uploaded", "duplicates", "failed", "skipped", "rate_limited"}`.
    public func stravaUpload(files: [String], apply: Bool = true) async throws -> JSONValue {
        try await call("strava.upload", params: ["files": .array(files.map { .string($0) }), "apply": .bool(apply)])
    }
}

public enum MapAction: String, Sendable { case install, update, remove }

struct DevicesList: Decodable { var devices: [Device] }

/// The first sync of a device must say what to upload (`first_sync_choice` otherwise):
/// everything on it, or only what is new from now on.
public enum FirstSync: String, Sendable { case all, baseline }
