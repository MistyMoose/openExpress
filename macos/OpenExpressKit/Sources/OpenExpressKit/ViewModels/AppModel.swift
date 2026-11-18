import Foundation
import Observation

/// The whole app: the engine, the account, the devices and the automatic mode.
@MainActor
@Observable
public final class AppModel {
    public enum EngineState: Equatable, Sendable {
        case starting
        case ready
        case failed(String)
    }

    public static let clientName = "openExpress-mac/0.1"

    @ObservationIgnored public let engine: any EngineConnection
    @ObservationIgnored public weak var notifier: (any Notifier)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public let settings: AppSettings
    public private(set) var engineState: EngineState = .starting
    public private(set) var hello: EngineHello?
    public private(set) var account: AccountStatus?
    public private(set) var strava: StravaStatus?
    public private(set) var devices: [Device] = []
    /// The engine's settings (`settings.get` without a key): `copy_fit_to`, `copy_fit_types`,
    /// `backup_dir`, `backup_keep`, …
    public private(set) var engineSettings: [String: JSONValue] = [:]
    /// A device held by another program before openExpress could tell which it is
    /// (`device.busy` with `device` null). Cleared when a device is attached.
    public private(set) var unassignedBusy: DeviceBusy?
    /// Devices whose automatic backup and sync is running.
    public private(set) var automaticRuns: Set<String> = []
    private var models: [String: DeviceModel] = [:]

    public var selection: SidebarItem?
    public var page: DevicePage = .overview
    public var isShowingSignIn = false
    public var isShowingSetup = false
    public var alertMessage: String?

    public init(engine: any EngineConnection, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
    }

    // MARK: Lifecycle

    public func start() async {
        guard !started else { return }
        started = true
        let events = await engine.events()
        eventTask = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        do {
            try await engine.start()
            await bootstrap()
        } catch {
            engineState = .failed(error.localizedDescription)
        }
    }

    public func stop() async {
        eventTask?.cancel()
        await engine.shutdown()
    }

    /// Restarts after the engine failed to start or stopped for good.
    public func retry() async {
        engineState = .starting
        do {
            try await engine.start()
            await bootstrap()
        } catch {
            engineState = .failed(error.localizedDescription)
        }
    }

    private func bootstrap() async {
        do {
            // `hello` first: it says which methods there are. The rest at once.
            hello = try await engine.hello(client: Self.clientName)
            let engine = self.engine
            async let accountStatus = engine.accountStatus()
            async let deviceList = engine.devices()
            async let stravaStatus = try? engine.stravaStatus()
            async let allSettings = try? engine.settings()
            account = try await accountStatus
            apply(devices: try await deviceList)
            engineState = .ready
            if account?.setupDone == false { isShowingSetup = true }
            if selection == nil {
                selection = connectedDevices.first.map { .device($0.unitID) }
                    ?? devices.first.map { .device($0.unitID) } ?? .account
            }
            // Nothing of a device's page needs Strava or the engine's settings.
            for d in connectedDevices { Task { await model(for: d.unitID)?.refresh() } }
            strava = await stravaStatus
            if let all = await allSettings { engineSettings = all }
        } catch {
            engineState = .failed(error.localizedDescription)
        }
    }

    public func reloadDevices() async throws {
        apply(devices: try await engine.devices())
    }

    private func apply(devices list: [Device]) {
        devices = list
        for d in list { ensureModel(d) }
    }

    public func supports(_ method: String) -> Bool { hello?.supports(method) ?? false }

    // MARK: Devices

    public var connectedDevices: [Device] { devices.filter(\.connected) }
    public var rememberedDevices: [Device] { devices.filter { !$0.connected } }

    /// The model of a device; pure lookup, so views may call it while they render.
    public func model(for unitID: String) -> DeviceModel? { models[unitID] }

    private func ensureModel(_ d: Device) {
        if let m = models[d.unitID] {
            m.update(device: d)
        } else {
            models[d.unitID] = DeviceModel(device: d, engine: engine, context: .init(
                supports: { [weak self] in self?.supports($0) ?? false },
                accountProblem: { [weak self] in self?.handleAccountProblem($0) ?? false }))
        }
    }

    /// `setup_needed` and `not_signed_in` open the sheet that fixes them.
    private func handleAccountProblem(_ error: EngineError) -> Bool {
        switch error.code {
        case "setup_needed":
            isShowingSetup = true
            return true
        case "not_signed_in", "unauthorized":
            isShowingSignIn = account?.setupDone != false
            isShowingSetup = account?.setupDone == false
            return true
        default:
            return false
        }
    }

    public var selectedModel: DeviceModel? {
        guard case .device(let id) = selection else { return nil }
        return model(for: id)
    }

    /// Updates waiting across connected devices, for the menu bar badge.
    public var pendingUpdatesCount: Int {
        connectedDevices.compactMap { models[$0.unitID] }.reduce(0) { $0 + $1.badgeCount }
    }

    private func upsert(_ device: Device) {
        if let i = devices.firstIndex(where: { $0.unitID == device.unitID }) {
            devices[i] = device
        } else {
            devices.append(device)
        }
        ensureModel(device)
    }

    // MARK: Events

    func handle(_ event: EngineEvent) {
        switch event {
        case .deviceAttached(let d):
            unassignedBusy = nil
            upsert(d)
            if selection == nil || selection == .account { selection = .device(d.unitID) }
            if settings.automaticBackupAndSync, account?.signedIn == true {
                Task { await runAutomatic(d.unitID) }
            } else {
                Task { await model(for: d.unitID)?.refresh() }
            }
        case .deviceDetached(let d):
            var d = d
            d.connected = false
            upsert(d)
        case .deviceBusy(let b):
            // `device` is null unless the USB serial names a remembered device: then match
            // the product name among the connected devices, else say so without a device.
            let unit = b.device
                ?? connectedDevices.first(where: { $0.name == b.name })?.unitID
                ?? (connectedDevices.count == 1 && b.name == nil ? connectedDevices.first?.unitID : nil)
            if let unit, let i = devices.firstIndex(where: { $0.unitID == unit }) {
                devices[i].busyBy = b.program
                model(for: unit)?.markBusy(b.program)
            } else {
                unassignedBusy = b
            }
        case .engineRestarted:
            Task { await bootstrap() }
        case .engineStopped(let why):
            engineState = .failed(why)
        case .progress, .log, .unknown:
            break
        }
    }

    /// The automatic mode: backup → sync → updates and maps checked → a notification.
    public func runAutomatic(_ unitID: String) async {
        guard !automaticRuns.contains(unitID), let m = model(for: unitID) else { return }
        automaticRuns.insert(unitID)
        defer { automaticRuns.remove(unitID) }
        let started = Date.now
        await m.refresh()
        let summary = await m.automaticBackupAndSync(checkedSince: started)
        if settings.notificationsEnabled, !summary.isEmpty {
            notifier?.notify(title: m.device.name, body: summary)
        }
    }

    // MARK: Account

    public func refreshAccount() async {
        account = try? await engine.accountStatus()
        strava = try? await engine.stravaStatus()
    }

    public func signInURL() async throws -> URL { try await engine.signInURL() }

    public func completeSignIn(ticketURL: String) async {
        do {
            try await engine.signIn(ticketURL: ticketURL)
            isShowingSignIn = false
            await refreshAccount()
            for d in connectedDevices { Task { await model(for: d.unitID)?.refresh() } }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    public func signOut() async {
        do {
            try await engine.signOut()
        } catch {
            alertMessage = error.localizedDescription
        }
        await refreshAccount()
    }

    public func setUp(installer: URL) async throws {
        try await engine.accountSetup(installer: installer)
        await refreshAccount()
    }

    /// Where Strava sends the browser back to; the sign-in sheet catches it, nothing listens.
    public static let stravaRedirectURI = "http://localhost/openexpress-strava"

    /// Step one: the page to authorise openExpress on Strava (client ID and secret saved first
    /// when given). The sheet showing it calls `finishStrava(code:)`.
    public func startStrava(clientID: String? = nil, clientSecret: String? = nil) async {
        do {
            let r = try await engine.stravaConnect(redirectURI: Self.stravaRedirectURI,
                                                   clientID: clientID, clientSecret: clientSecret)
            if let s = r.authorizeURL, let url = URL(string: s) { stravaAuthorizeURL = url }
            strava = r
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    public func finishStrava(code: String) async {
        stravaAuthorizeURL = nil
        do {
            strava = try await engine.stravaConnect(redirectURI: Self.stravaRedirectURI, code: code)
        } catch {
            alertMessage = error.localizedDescription
        }
        await refreshAccount()
    }

    /// The Strava page to authorise on, while connecting.
    public var stravaAuthorizeURL: URL?

    public func disconnectStrava() async {
        do { try await engine.stravaDisconnect() } catch { alertMessage = error.localizedDescription }
        await refreshAccount()
    }

    // MARK: Engine settings

    public func reloadEngineSettings() async {
        if let all = try? await engine.settings() { engineSettings = all }
    }

    public func engineSetting(_ key: String) async -> JSONValue? {
        try? await engine.setting(key)
    }

    public func setEngineSetting(_ key: String, _ value: JSONValue) async {
        do {
            try await engine.setSetting(key, value)
            engineSettings[key] = value
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// The engine's `backup_dir` (where `device.backup` writes when given no `dest`).
    public var backupFolder: URL {
        guard let path = engineSettings["backup_dir"]?.stringValue, !path.isEmpty else { return BackupFolder.defaultRoot }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The engine's `backup_keep`: how many backups of a device are kept; 0 keeps all.
    public var backupKeep: Int { engineSettings["backup_keep"]?.intValue ?? 3 }
}
