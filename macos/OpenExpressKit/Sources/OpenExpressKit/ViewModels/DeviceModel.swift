import Foundation
import Observation

/// One device and what its pages show; runs its long operations one at a time.
@MainActor
@Observable
public final class DeviceModel: Identifiable {
    public enum OperationKind: String, Sendable {
        case sync, backup, installUpdates, mapsInstall, mapsUpdate, mapsRemove

        public var title: String {
            switch self {
            case .sync: String(localized: "Syncing")
            case .backup: String(localized: "Backing Up")
            case .installUpdates: String(localized: "Installing Updates")
            case .mapsInstall: String(localized: "Installing Maps")
            case .mapsUpdate: String(localized: "Updating Maps")
            case .mapsRemove: String(localized: "Removing Maps")
            }
        }
    }

    public struct Operation: Sendable, Equatable {
        public var kind: OperationKind
        public var progress: EngineProgress?
        public var cancelling = false

        /// "Downloading · TopoActive Europe".
        public var detail: String {
            guard let progress else { return String(localized: "Starting…") }
            let phase = progress.phase.prefix(1).uppercased() + progress.phase.dropFirst()
            return [phase, progress.item].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @ObservationIgnored private let engine: any EngineConnection
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let supports: @MainActor (String) -> Bool
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    public private(set) var device: Device
    public private(set) var updates: [SoftwareUpdate] = []
    public private(set) var betaOffered = false
    public private(set) var updatesChecked: Date?
    public private(set) var maps: MapsList?
    public private(set) var apps: [ConnectIQApp]?
    public private(set) var activities: [Activity]?
    public private(set) var backups: [BackupSnapshot]?
    public private(set) var operation: Operation?
    /// The outcome of the last operation, for the page's status line.
    public private(set) var lastOutcome: String?
    public var errorMessage: String?
    public private(set) var loading: Set<DevicePage> = []

    public nonisolated var id: String { unitID }
    private nonisolated let unitID: String

    public init(device: Device, engine: any EngineConnection, settings: AppSettings,
                supports: @escaping @MainActor (String) -> Bool = { _ in true }) {
        self.device = device
        self.unitID = device.unitID
        self.engine = engine
        self.settings = settings
        self.supports = supports
    }

    // MARK: State

    public var busyBy: String? { device.busyBy }
    public var isBusy: Bool { operation != nil }

    /// Updates not yet copied to the device.
    public var pendingUpdates: [SoftwareUpdate] { updates.filter { !$0.waitingOnDevice } }
    /// Copied: the device installs them once unplugged.
    public var waitingUpdates: [SoftwareUpdate] { updates.filter(\.waitingOnDevice) }
    /// What Install All installs: everything not yet copied, betas only when chosen one by one.
    public var installAllParts: [SoftwareUpdate] { pendingUpdates.filter { !$0.beta } }
    public var badgeCount: Int { pendingUpdates.filter { !$0.beta }.count + (maps?.updatable.count ?? 0) }

    func update(device new: Device) {
        // Keep what device.info knew (storage, software) when an event brings less.
        var merged = new
        if merged.storage == nil { merged.storage = device.storage }
        if merged.software == nil { merged.software = device.software }
        if merged.lastBackup == nil { merged.lastBackup = device.lastBackup }
        if merged.battery == nil, merged.connected { merged.battery = device.battery }
        device = merged
    }

    /// After the user quit the other program: ask again.
    public func retryAfterBusy() async {
        device.busyBy = nil
        await load(.overview)
    }

    func markBusy(_ program: String?) {
        device.busyBy = program
    }

    // MARK: Loading

    public func refresh() async {
        await load(.overview)
    }

    public func load(_ page: DevicePage) async {
        guard !loading.contains(page) else { return }
        loading.insert(page)
        defer { loading.remove(page) }
        do {
            switch page {
            case .overview:
                if device.connected { update(device: try await engine.deviceInfo(unitID)) }
                if device.connected, updatesChecked == nil { try await loadUpdates() }
            case .updates:
                try await loadUpdates()
            case .maps:
                maps = try await engine.maps(unitID, all: true)
            case .apps:
                apps = try await engine.apps(unitID)
            case .activities:
                activities = try await engine.activities(unitID)
            case .backups:
                if supports("backups.list") {
                    backups = try await engine.backups(unitID, destination: settings.backupFolder)
                } else {
                    backups = BackupFolder.snapshots(root: settings.backupFolder, unitID: unitID)
                }
            }
            // A request that went through: nobody holds the device (device.info says itself).
            if page != .backups, page != .overview || !device.connected { device.busyBy = nil }
        } catch {
            handle(error)
        }
    }

    private func loadUpdates() async throws {
        let list = try await engine.updates(unitID)
        updates = list.updates
        betaOffered = list.betaOffered
        updatesChecked = .now
    }

    public func track(for activity: Activity) async -> ActivityTrack? {
        guard let path = activity.fitPath, supports("activities.track") else { return nil }
        return try? await engine.activityTrack(fitPath: path)
    }

    // MARK: Operations

    public func sync() {
        run(.sync) { [engine, unitID] progress in
            let r = try await engine.sync(unitID, apply: true, progress: progress)
            return Self.summary(of: r)
        } then: { [weak self] in
            await self?.load(.overview)
        }
    }

    public func backUp() {
        run(.backup) { [engine, unitID, settings] progress in
            let r = try await engine.backup(unitID, destination: settings.backupFolder,
                                            keep: settings.keepBackups, apply: true, progress: progress)
            return Self.summary(of: r)
        } then: { [weak self] in
            self?.device.lastBackup = .now
            await self?.load(.backups)
        }
    }

    /// `parts`: nil installs all (as Install All: no betas).
    public func install(_ parts: [SoftwareUpdate]? = nil) {
        let chosen = (parts ?? installAllParts).map(\.part)
        guard !chosen.isEmpty else { return }
        run(.installUpdates) { [engine, unitID] progress in
            let r = try await engine.installUpdates(unitID, parts: chosen, apply: true, progress: progress)
            if let refused = r.refused.first { return refused.value }
            return String(localized: "Unplug the device to install the update.")
        } then: { [weak self] in
            await self?.load(.updates)
        }
    }

    public func maps(_ action: MapAction, _ names: [String]) {
        guard !names.isEmpty else { return }
        let kind: OperationKind = switch action {
        case .install: .mapsInstall
        case .update: .mapsUpdate
        case .remove: .mapsRemove
        }
        run(kind) { [engine, unitID] progress in
            let r = try await engine.maps(action, unitID, names: names, apply: true, progress: progress)
            return r.refused.first?.value
        } then: { [weak self] in
            await self?.load(.maps)
        }
    }

    public func cancelOperation() {
        guard operation != nil else { return }
        operation?.cancelling = true
        operationTask?.cancel()
    }

    /// Waits for the running operation, if any (tests, automatic mode).
    public func waitForOperation() async {
        await operationTask?.value
    }

    private func run(_ kind: OperationKind,
                     _ body: @escaping @MainActor (@escaping @Sendable (EngineProgress) -> Void) async throws -> String?,
                     then: @escaping @MainActor () async -> Void) {
        guard operation == nil else { return }
        operation = Operation(kind: kind)
        errorMessage = nil
        operationTask = Task {
            let progress: @Sendable (EngineProgress) -> Void = { p in
                Task { @MainActor in
                    if self.operation?.kind == kind { self.operation?.progress = p }
                }
            }
            do {
                let outcome = try await body(progress)
                lastOutcome = outcome
                device.busyBy = nil
            } catch EngineError.cancelled, is CancellationError {
                lastOutcome = String(localized: "Cancelled.")
            } catch {
                handle(error)
            }
            operation = nil
            await then()
        }
    }

    /// Runs the automatic backup and sync on connection: backup → sync → updates + maps.
    /// Never installs anything. Returns a one-line summary for the notification.
    public func automaticBackupAndSync() async -> String {
        var lines: [String] = []
        backUp()
        await waitForOperation()
        if let busy = device.busyBy {
            return String(localized: "\(busy) is using the device. Quit Garmin Express, then sync.")
        }
        if errorMessage == nil, let o = lastOutcome { lines.append(o) }
        sync()
        await waitForOperation()
        if errorMessage == nil, let o = lastOutcome { lines.append(o) }
        await load(.updates)
        await load(.maps)
        let n = installAllParts.count
        let m = maps?.updatable.count ?? 0
        if n > 0 { lines.append(String(localized: "\(n) software update(s) available.")) }
        if m > 0 { lines.append(String(localized: "\(m) map update(s) available.")) }
        if let errorMessage { lines.append(errorMessage) }
        return lines.joined(separator: " ")
    }

    private func handle(_ error: any Error) {
        if let engineError = error as? EngineError, let program = engineError.busyProgram {
            device.busyBy = program.isEmpty ? String(localized: "Another program") : program
            return
        }
        errorMessage = error.localizedDescription
    }

    // MARK: Summaries

    static func summary(of r: SyncResult) -> String {
        var parts = [String(localized: "Synced: \(r.uploaded) uploaded, \(r.downloaded) downloaded.")]
        if r.dropFolderCopies > 0 { parts.append(String(localized: "\(r.dropFolderCopies) copied to the FIT drop folder.")) }
        if r.stravaUploads > 0 { parts.append(String(localized: "\(r.stravaUploads) sent to Strava.")) }
        return parts.joined(separator: " ")
    }

    static func summary(of r: BackupResult) -> String {
        String(localized: "Backed up: \(r.copied) files read (\(Format.bytes(r.copiedBytes))), \(r.linked) unchanged.")
    }
}
