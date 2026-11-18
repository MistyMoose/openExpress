import Foundation
import Observation

/// What an install will do, shown for confirmation before anything is downloaded.
public struct InstallPlan: Identifiable, Sendable, Hashable {
    public struct Item: Identifiable, Sendable, Hashable {
        public enum Kind: Sendable, Hashable { case software, map }
        public var id: String
        public var kind: Kind
        public var name: String
        /// "21.19 → 21.22", "new · 2025.20".
        public var change: String?
        public var size: Int64
    }

    public enum Action: Sendable, Hashable {
        /// Install All: these software parts, then every map update.
        case installAll(parts: [String], updateMaps: Bool)
        /// One map not yet on the device.
        case installMap(String)
    }

    public var id: String { items.map(\.id).joined(separator: "|") }
    public var items: [Item]
    public var action: Action
    /// Free space on the device now, when known.
    public var freeNow: Int64?

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    public var freeAfter: Int64? { freeNow.map { $0 - totalBytes } }
    public var fits: Bool { (freeAfter ?? 0) >= 0 }
    public var hasSoftware: Bool { items.contains { $0.kind == .software } }

    /// Maps from this size on are confirmed before they are installed.
    public static let largeMap: Int64 = 1_000_000_000
}

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
            progress?.detail ?? String(localized: "Starting…")
        }
    }

    /// What the device model needs from the app.
    public struct Context {
        public var supports: @MainActor (String) -> Bool
        /// Errors about the account (`setup_needed`, `not_signed_in`); true when handled.
        public var accountProblem: @MainActor (EngineError) -> Bool

        public init(supports: @escaping @MainActor (String) -> Bool = { _ in true },
                    accountProblem: @escaping @MainActor (EngineError) -> Bool = { _ in false }) {
            self.supports = supports
            self.accountProblem = accountProblem
        }
    }

    @ObservationIgnored private let engine: any EngineConnection
    @ObservationIgnored private let context: Context
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    public private(set) var device: Device
    public private(set) var updates: [SoftwareUpdate] = []
    public private(set) var betaOffered = false
    public private(set) var updatesChecked: Date?
    public private(set) var maps: MapsList?
    /// When `maps.list` last answered.
    @ObservationIgnored private var mapsChecked: Date?
    /// Free space on the device, as `maps.list` last said it, else as `device.info` did.
    public var freeSpace: Int64? { maps?.free ?? device.storage?.free }
    public private(set) var apps: AppsList?
    public private(set) var activities: [Activity]?
    public private(set) var backups: [BackupSnapshot]?
    public private(set) var operation: Operation?
    /// The outcome of the last operation, for the page's status line.
    public private(set) var lastOutcome: String?
    public var errorMessage: String?
    /// Pages whose load is in flight.
    public private(set) var loading: Set<DevicePage> = []
    /// Progress of a page load that reports it (`activities.list`: `reading_activities`).
    public private(set) var loadProgress: [DevicePage: EngineProgress] = [:]
    /// The Activities page's filters and sort, kept for the session.
    public var activityFilter = ActivityFilter()
    public var activitySort = [KeyPathComparator(\Activity.start, order: .reverse)]
    /// Pages loaded at least once (a visit then shows them without reading the device again).
    public private(set) var loaded: Set<DevicePage> = []
    /// The page loads, owned here and not by the views: switching pages never cancels one,
    /// and coming back joins the load in flight.
    @ObservationIgnored private var loadTasks: [DevicePage: Task<Void, Never>] = [:]
    /// When each load in flight started, to tell which wait behind another.
    @ObservationIgnored private var loadStarted: [DevicePage: ContinuousClock.Instant] = [:]
    /// Tracks read for the Activities inspector, by activity id, the most recent last: each
    /// read is a whole FIT file over MTP, so going back to an activity reads nothing.
    @ObservationIgnored private var tracks: [String: ActivityTrack] = [:]
    @ObservationIgnored private var trackOrder: [String] = []
    /// Tracks kept (the engine sends at most a few thousand points each).
    public static let trackCacheLimit = 50
    /// An install waiting for the user's confirmation.
    public var pendingPlan: InstallPlan?
    /// The first sync of this device waits for the choice: everything, or new data only.
    public var needsFirstSyncChoice = false

    public nonisolated var id: String { unitID }
    private nonisolated let unitID: String

    public init(device: Device, engine: any EngineConnection, context: Context = Context()) {
        self.device = device
        self.unitID = device.unitID
        self.engine = engine
        self.context = context
    }

    // MARK: State

    public var busyBy: String? { device.busyBy }
    public var isBusy: Bool { operation != nil }

    /// Updates not yet copied to the device.
    public var pendingUpdates: [SoftwareUpdate] { updates.filter { !$0.waitingOnDevice } }
    /// Copied: the device installs them once unplugged.
    public var waitingUpdates: [SoftwareUpdate] { updates.filter(\.waitingOnDevice) }
    /// The software Install All installs: not yet copied, no betas (those one by one).
    public var installAllParts: [SoftwareUpdate] { pendingUpdates.filter { !$0.beta } }
    /// Installed maps with an update.
    public var mapUpdates: [DeviceMap] { maps?.updatable ?? [] }

    /// The one count of what waits for this device: software (no betas) and map updates.
    /// The sidebar badge, the menu bar and Install All all use it.
    public var badgeCount: Int { installAllParts.count + mapUpdates.count }

    func update(device new: Device) {
        // Keep what device.info knew (storage, software) when an event brings less.
        var merged = new
        if merged.storage == nil { merged.storage = device.storage }
        if merged.software == nil { merged.software = device.software }
        if merged.lastBackup == nil { merged.lastBackup = device.lastBackup }
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

    /// Device info, then what waits for it (updates and maps), so every count agrees.
    public func refresh() async {
        await load(.overview)
    }

    /// Loads a page the first time it is shown; later visits show what was read (Refresh
    /// reads again).
    public func loadIfNeeded(_ page: DevicePage) async {
        // The Overview reads updates and maps too: a first visit to those pages while it
        // runs waits for it instead of asking the Garmin server a second time.
        if page == .updates || page == .maps, let overview = loadTasks[.overview] {
            await overview.value
        }
        if loaded.contains(page), loadTasks[page] == nil { return }
        await load(page)
    }

    /// Reads a page from the engine, or joins the read already in flight. The read runs in a
    /// task of its own: cancelling the caller (a view going away) leaves it running.
    public func load(_ page: DevicePage) async {
        if let running = loadTasks[page] {
            await running.value
            return
        }
        let task = Task { await self.performLoad(page) }
        loadTasks[page] = task
        await task.value
    }

    /// The engine runs one request per device at a time: a page whose load started after
    /// another page's (or during an operation) and reports nothing yet is waiting its turn.
    public func isWaiting(_ page: DevicePage) -> Bool {
        guard loading.contains(page), loadProgress[page] == nil, let mine = loadStarted[page] else { return false }
        if operation != nil { return true }
        return loadStarted.contains { $0.key != page && $0.value < mine }
    }

    private func performLoad(_ page: DevicePage) async {
        loading.insert(page)
        loadStarted[page] = .now
        loadProgress[page] = nil
        defer {
            loading.remove(page)
            loadStarted[page] = nil
            loadProgress[page] = nil
            loadTasks[page] = nil
        }
        let progress: @Sendable (EngineProgress) -> Void = { p in
            Task { @MainActor in
                if self.loading.contains(page) { self.loadProgress[page] = p }
            }
        }
        do {
            switch page {
            case .overview:
                if device.connected {
                    update(device: try await engine.deviceInfo(unitID))
                    if device.busyBy == nil {
                        if updatesChecked == nil { try await loadUpdates(progress) }
                        if maps == nil { try await loadMaps(progress) }
                        // What the Updates and Maps pages show is read now: their first
                        // visit shows it (their Refresh reads again).
                        if updatesChecked != nil, maps != nil { loaded.insert(.updates) }
                        if maps != nil { loaded.insert(.maps) }
                    }
                }
            case .updates:
                try await loadUpdates(progress)
                try await loadMaps(progress)
            case .maps:
                try await loadMaps(progress)
            case .apps:
                apps = try await engine.apps(unitID, progress: progress)
            case .activities:
                activities = try await engine.activities(unitID, progress: progress)
            case .backups:
                backups = try await engine.backups(unitID)
            }
            loaded.insert(page)
            // A request that went through: nobody holds the device (device.info says itself).
            if page != .backups, page != .overview || !device.connected { device.busyBy = nil }
        } catch EngineError.cancelled, is CancellationError {
            // A page load is never an error the user caused or needs to see.
        } catch {
            handle(error)
        }
    }

    private func loadUpdates(_ progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws {
        let list = try await engine.updates(unitID, progress: progress)
        updates = list.updates
        betaOffered = list.betaOffered
        updatesChecked = .now
    }

    private func loadMaps(_ progress: (@Sendable (EngineProgress) -> Void)? = nil) async throws {
        maps = try await engine.maps(unitID, progress: progress)
        mapsChecked = .now
    }

    /// The track already read for an activity, without asking the engine.
    public func cachedTrack(for activity: Activity) -> ActivityTrack? {
        guard let t = tracks[activity.id] else { return nil }
        if trackOrder.last != activity.id {
            trackOrder.removeAll { $0 == activity.id }
            trackOrder.append(activity.id)
        }
        return t
    }

    public func track(for activity: Activity) async -> ActivityTrack? {
        if let t = cachedTrack(for: activity) { return t }
        guard let path = activity.fitPath, context.supports("activities.track") else { return nil }
        guard let t = try? await engine.activityTrack(fitPath: path, unitID: unitID) else { return nil }
        // A file still being written gives more later: read again next time.
        if activity.state == nil || activity.state == "complete" {
            tracks[activity.id] = t
            trackOrder.removeAll { $0 == activity.id }
            trackOrder.append(activity.id)
            while trackOrder.count > Self.trackCacheLimit { tracks[trackOrder.removeFirst()] = nil }
        }
        return t
    }

    // MARK: Operations

    public func sync(firstRun: FirstSync? = nil) {
        needsFirstSyncChoice = false
        run(.sync) { [engine, unitID] progress in
            let r = try await engine.sync(unitID, firstRun: firstRun, progress: progress)
            return Self.summary(of: r)
        } then: { [weak self] in
            await self?.load(.overview)
        }
    }

    public func backUp() {
        // Folder and number kept: the engine's `backup_dir` and `backup_keep`.
        run(.backup) { [engine, unitID] progress in
            let r = try await engine.backup(unitID, progress: progress)
            return Self.summary(of: r)
        } then: { [weak self] in
            self?.device.lastBackup = .now
            await self?.load(.backups)
        }
    }

    /// Asks for confirmation of Install All (software without betas, and every map update).
    public func requestInstallAll() {
        let software = installAllParts
        let mapsToUpdate = mapUpdates
        guard !software.isEmpty || !mapsToUpdate.isEmpty else { return }
        let items = software.map {
            InstallPlan.Item(id: "sw:" + $0.part, kind: .software, name: $0.name,
                             change: $0.installed.map { [version = $0.version] in "\($0) → \(version)" } ?? $0.version,
                             size: $0.size)
        } + mapsToUpdate.map {
            InstallPlan.Item(id: "map:" + $0.name, kind: .map, name: $0.name, change: $0.versionChange, size: $0.size)
        }
        pendingPlan = InstallPlan(items: items,
                                  action: .installAll(parts: software.map(\.part), updateMaps: !mapsToUpdate.isEmpty),
                                  freeNow: freeSpace)
    }

    /// Installs a map not yet on the device; a large one is confirmed first.
    public func requestInstall(map: DeviceMap) {
        let plan = InstallPlan(
            items: [.init(id: "map:" + map.name, kind: .map, name: map.name, change: map.versionChange, size: map.size)],
            action: .installMap(map.name), freeNow: freeSpace)
        if map.size >= InstallPlan.largeMap {
            pendingPlan = plan
        } else {
            perform(plan)
        }
    }

    /// Runs a confirmed plan.
    public func perform(_ plan: InstallPlan) {
        pendingPlan = nil
        switch plan.action {
        case .installAll(let parts, let updateMaps):
            run(.installUpdates) { [engine, unitID] progress in
                var problems: [String] = []
                if !parts.isEmpty {
                    let r = try await engine.installUpdates(unitID, parts: parts, progress: progress)
                    if let m = r.failureMessage { problems.append(m) }
                }
                if updateMaps {
                    let r = try await engine.updateAllMaps(unitID, progress: progress)
                    if let m = r.failureMessage { problems.append(m) }
                }
                if !problems.isEmpty { return problems.joined(separator: "\n") }
                return parts.isEmpty ? String(localized: "Maps updated.")
                    : String(localized: "Unplug the device to install the software.")
            } then: { [weak self] in
                await self?.load(.updates)
            }
        case .installMap(let name):
            maps(.install, [name])
        }
    }

    /// Installs one software part (a beta, chosen by itself) without asking.
    public func install(_ update: SoftwareUpdate) {
        run(.installUpdates) { [engine, unitID] progress in
            let r = try await engine.installUpdates(unitID, parts: [update.part], progress: progress)
            return r.failureMessage ?? String(localized: "Unplug the device to install the software.")
        } then: { [weak self] in
            await self?.load(.updates)
        }
    }

    public func updateAllMaps() {
        run(.mapsUpdate) { [engine, unitID] progress in
            try await engine.updateAllMaps(unitID, progress: progress).failureMessage
        } then: { [weak self] in
            await self?.load(.maps)
        }
    }

    public func maps(_ action: MapAction, _ names: [String]) {
        guard !names.isEmpty else { return }
        run(action == .install ? .mapsInstall : .mapsRemove) { [engine, unitID] progress in
            try await engine.maps(action, unitID, names: names, progress: progress).failureMessage
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
        lastOutcome = nil
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

    /// Runs the automatic backup and sync on connection: backup → sync → updates + maps
    /// (unless both were read since `checkedSince`, by the Overview of this connection).
    /// Never installs anything. Returns a one-line summary for the notification.
    public func automaticBackupAndSync(checkedSince: Date? = nil) async -> String {
        var lines: [String] = []
        backUp()
        await waitForOperation()
        if let busy = device.busyBy {
            return String(localized: "\(busy) is using the device. Quit Garmin Express, then sync.")
        }
        if errorMessage == nil, let o = lastOutcome { lines.append(o) }
        sync()
        await waitForOperation()
        if needsFirstSyncChoice {
            lines.append(String(localized: "Open openExpress for Mac to choose what its first sync uploads."))
        } else if errorMessage == nil, let o = lastOutcome {
            lines.append(o)
        }
        if let since = checkedSince, let u = updatesChecked, let m = mapsChecked, u >= since, m >= since {
            // Read moments ago: the Garmin server is not asked again.
        } else {
            await load(.updates)
        }
        let n = installAllParts.count
        let m = mapUpdates.count
        if n > 0 { lines.append(String(localized: "\(n) software update(s) available.")) }
        if m > 0 { lines.append(String(localized: "\(m) map update(s) available.")) }
        if let errorMessage { lines.append(errorMessage) }
        return lines.joined(separator: " ")
    }

    private func handle(_ error: any Error) {
        guard let engineError = error as? EngineError else {
            errorMessage = error.localizedDescription
            return
        }
        if let program = engineError.busyProgram {
            device.busyBy = program.isEmpty ? String(localized: "Another program") : program
            return
        }
        if engineError.code == "first_sync_choice" {
            needsFirstSyncChoice = true
            return
        }
        if context.accountProblem(engineError) { return }
        errorMessage = engineError.localizedDescription
    }

    // MARK: Summaries

    static func summary(of r: SyncResult) -> String {
        var parts = [r.sentence ?? String(localized: "Synced: \(r.uploaded) uploaded, \(r.downloaded) downloaded.")]
        if r.dropFolderCopies > 0 { parts.append(String(localized: "\(r.dropFolderCopies) copied to the FIT drop folder.")) }
        if r.stravaUploads > 0 { parts.append(String(localized: "\(r.stravaUploads) sent to Strava.")) }
        if let e = r.stravaError { parts.append(String(localized: "Strava: \(e)")) }
        return parts.joined(separator: " ")
    }

    static func summary(of r: BackupResult) -> String {
        var s = String(localized: "Backed up: \(r.copied) files read (\(Format.bytes(r.copiedBytes))), \(r.linked) unchanged.")
        if r.incomplete > 0 {
            s += " " + String(localized: "\(r.incomplete) file(s) still being written were left out: unplug the device, plug it in again and back up again.")
        }
        return s
    }
}
