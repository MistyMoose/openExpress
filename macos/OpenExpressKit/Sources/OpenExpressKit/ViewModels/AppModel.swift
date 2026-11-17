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
    public private(set) var log: [EngineLogLine] = []
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
            hello = try await engine.hello(client: Self.clientName)
            account = try await engine.accountStatus()
            try await reloadDevices()
            engineState = .ready
            if account?.setupDone == false { isShowingSetup = true }
            if selection == nil {
                selection = connectedDevices.first.map { .device($0.unitID) }
                    ?? devices.first.map { .device($0.unitID) } ?? .account
            }
            if hello?.supports("strava.status") == true { strava = try? await engine.stravaStatus() }
            for d in connectedDevices { Task { await model(for: d.unitID)?.refresh() } }
        } catch {
            engineState = .failed(error.localizedDescription)
        }
    }

    public func reloadDevices() async throws {
        let list = try await engine.devices()
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
            models[d.unitID] = DeviceModel(device: d, engine: engine, settings: settings,
                                           supports: { [weak self] in self?.supports($0) ?? false })
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
            model(for: b.device)?.markBusy(b.program)
            if let i = devices.firstIndex(where: { $0.unitID == b.device }) { devices[i].busyBy = b.program }
        case .log(let line):
            log.append(line)
            if log.count > 500 { log.removeFirst(log.count - 500) }
        case .engineRestarted:
            Task { await bootstrap() }
        case .engineStopped(let why):
            engineState = .failed(why)
        case .progress, .unknown:
            break
        }
    }

    /// The automatic mode: backup → sync → updates and maps checked → a notification.
    public func runAutomatic(_ unitID: String) async {
        guard !automaticRuns.contains(unitID), let m = model(for: unitID) else { return }
        automaticRuns.insert(unitID)
        defer { automaticRuns.remove(unitID) }
        await m.refresh()
        let summary = await m.automaticBackupAndSync()
        if settings.notificationsEnabled, !summary.isEmpty {
            notifier?.notify(title: m.device.name, body: summary)
        }
    }

    // MARK: Account

    public func refreshAccount() async {
        account = try? await engine.accountStatus()
        if supports("strava.status") { strava = try? await engine.stravaStatus() }
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

    public func connectStrava() async {
        do {
            let r = try await engine.stravaConnect()
            // The engine may answer with a page to open to authorise.
            if let s = r["url"]?.stringValue, let url = URL(string: s) { pendingStravaURL = url }
        } catch {
            alertMessage = error.localizedDescription
        }
        await refreshAccount()
    }

    /// A page the user must open to finish connecting Strava, if the engine gave one.
    public var pendingStravaURL: URL?

    public func disconnectStrava() async {
        do { try await engine.stravaDisconnect() } catch { alertMessage = error.localizedDescription }
        await refreshAccount()
    }

    // MARK: Engine settings

    public func engineSetting(_ key: String) async -> JSONValue? {
        try? await engine.setting(key)
    }

    public func setEngineSetting(_ key: String, _ value: JSONValue) async {
        do { try await engine.setSetting(key, value) } catch { alertMessage = error.localizedDescription }
    }
}
