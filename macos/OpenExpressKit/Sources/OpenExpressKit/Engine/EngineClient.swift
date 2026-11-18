import Foundation
import os
import Synchronization

/// The engine process: `openexpress engine`, spoken to over JSON Lines (docs/ENGINE.md).
///
/// - Requests get increasing ids; each `call` waits for the response with its id.
/// - Events go to every `events()` subscriber; `progress` also to the call it belongs to.
/// - A task cancelled while waiting sends `cancel` for its request.
/// - When the engine exits unexpectedly the running calls fail with `.terminated`, it is
///   started again (a few times a minute at most) and subscribers get `.engineRestarted`.
public actor EngineClient: EngineConnection {
    public struct Configuration: Sendable {
        public var executable: URL
        public var arguments: [String]
        /// Added to (and overriding) this process's environment; see `EngineEnvironment`.
        public var environment: [String: String]
        public var restartOnCrash: Bool
        public var maxRestarts: Int
        public var restartWindow: Duration
        public var restartDelay: Duration

        public init(executable: URL, arguments: [String] = ["engine"],
                    environment: [String: String] = EngineEnvironment.overrides(),
                    restartOnCrash: Bool = true, maxRestarts: Int = 5,
                    restartWindow: Duration = .seconds(60), restartDelay: Duration = .milliseconds(500)) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.restartOnCrash = restartOnCrash
            self.maxRestarts = maxRestarts
            self.restartWindow = restartWindow
            self.restartDelay = restartDelay
        }
    }

    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<Data, any Error>
        let progress: (@Sendable (EngineProgress) -> Void)?
    }

    private static let log = Logger(subsystem: "io.github.openexpress.mac", category: "engine")

    public let configuration: Configuration
    private let broadcaster = EventBroadcaster()
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var generation = 0
    private var stopping = false
    private var gaveUp = false
    private var restarts: [ContinuousClock.Instant] = []

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var isRunning: Bool { process?.isRunning == true }

    public func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }

    public func start() async throws {
        stopping = false
        gaveUp = false
        if process == nil { try launch() }
    }

    public func call(_ method: String, params: JSONValue?,
                     progress: (@Sendable (EngineProgress) -> Void)?) async throws -> JSONValue {
        let line = try await callLine(method, params: params, progress: progress)
        do {
            return try JSONDecoder().decode(EngineUntypedResultLine.self, from: line).result ?? .null
        } catch {
            throw EngineError.unexpectedResult(method: method, detail: String(describing: error))
        }
    }

    /// The response line itself: the caller decodes its result, once.
    public func callLine(_ method: String, params: JSONValue?,
                         progress: (@Sendable (EngineProgress) -> Void)?) async throws -> Data {
        if process == nil {
            if stopping || gaveUp { throw EngineError.notRunning }
            try launch()
            if generation > 1 { broadcaster.yield(.engineRestarted) }
        }
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        var line = try EngineRequest(id: id, method: method, params: params).line()
        line.append(0x0A)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
                pending[id] = Pending(method: method, continuation: cont, progress: progress)
                do {
                    guard let input else { throw EngineError.terminated }
                    try input.write(contentsOf: line)
                } catch {
                    pending[id] = nil
                    cont.resume(throwing: EngineError.terminated)
                }
            }
        } onCancel: {
            Task { await self.cancel(request: id) }
        }
    }

    public func shutdown() async {
        stopping = true
        guard let process, let input else { return }
        if var line = try? EngineRequest(id: nextID, method: "shutdown").line() {
            nextID += 1
            line.append(0x0A)
            try? input.write(contentsOf: line)
        }
        try? input.close()
        for _ in 0..<40 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.terminate() }
    }

    // MARK: - Process

    private func launch() throws {
        Self.ignoreSIGPIPE()
        let p = Process()
        p.executableURL = configuration.executable
        p.arguments = configuration.arguments
        p.environment = ProcessInfo.processInfo.environment
            .filter { !EngineEnvironment.removed.contains($0.key) }
            .merging(configuration.environment) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        // The engine's log: never parsed, passed on to ours (Xcode's console in development).
        p.standardError = FileHandle.standardError
        do {
            try p.run()
        } catch {
            Self.log.error("engine launch failed: \(error.localizedDescription, privacy: .public)")
            throw EngineError.launchFailed(error.localizedDescription)
        }
        generation += 1
        let gen = generation
        process = p
        input = stdin.fileHandleForWriting
        Self.log.info("engine started: \(self.configuration.executable.path, privacy: .public) (pid \(p.processIdentifier))")
        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            do {
                for try await line in reader.bytes.lines {
                    await self?.receive(line)
                }
            } catch {
                Self.log.error("engine stdout: \(error.localizedDescription, privacy: .public)")
            }
            await self?.ended(generation: gen)
        }
    }

    /// Writing to a pipe whose reader died must give an error, not kill the app.
    private static func ignoreSIGPIPE() {
        _ = sigpipeIgnored
    }

    private static let sigpipeIgnored: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()

    private func receive(_ line: String) {
        let data = Data(line.utf8)
        guard let envelope = EngineEnvelope.of(data) else {
            Self.log.debug("engine: not a message: \(line, privacy: .private)")
            return
        }
        if let id = envelope.id {
            // The result stays bytes here: the caller decodes it into what it expects.
            guard let p = pending.removeValue(forKey: id) else { return }
            switch envelope.engineError {
            case nil: p.continuation.resume(returning: data)
            case .remote("cancelled", _, _)?: p.continuation.resume(throwing: EngineError.cancelled)
            case let error?: p.continuation.resume(throwing: error)
            }
            return
        }
        guard envelope.event != nil, case .event(let event)? = EngineIncoming.parse(line) else {
            Self.log.debug("engine: not a message: \(line, privacy: .private)")
            return
        }
        if case .progress(let progress) = event { pending[progress.request]?.progress?(progress) }
        broadcaster.yield(event)
    }

    private func cancel(request id: Int) {
        guard pending[id] != nil, let input else { return }
        let cancelID = nextID
        nextID += 1
        guard var line = try? EngineRequest(id: cancelID, method: "cancel", params: ["request": .number(Double(id))]).line()
        else { return }
        line.append(0x0A)
        try? input.write(contentsOf: line)
    }

    private func ended(generation gen: Int) async {
        guard gen == generation else { return }
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        let failed = pending
        pending = [:]
        for p in failed.values { p.continuation.resume(throwing: EngineError.terminated) }
        if stopping {
            Self.log.info("engine stopped")
            return
        }
        Self.log.error("engine exited unexpectedly; \(failed.count) request(s) failed")
        let now = ContinuousClock.now
        restarts = restarts.filter { now - $0 < configuration.restartWindow }
        guard configuration.restartOnCrash, restarts.count < configuration.maxRestarts else {
            gaveUp = true
            broadcaster.yield(.engineStopped(String(localized: "The engine of openExpress for Mac stopped unexpectedly.")))
            return
        }
        restarts.append(now)
        try? await Task.sleep(for: configuration.restartDelay * (1 << (restarts.count - 1)))
        guard process == nil, !stopping else { return }
        do {
            try launch()
            broadcaster.yield(.engineRestarted)
        } catch {
            gaveUp = true
            broadcaster.yield(.engineStopped(error.localizedDescription))
        }
    }
}

/// Fans events out to any number of `AsyncStream`s.
public final class EventBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<EngineEvent>.Continuation]>([:])

    public init() {}

    public func subscribe() -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let key = UUID()
        continuations.withLock { $0[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: key) }
        }
        return stream
    }

    public func yield(_ event: EngineEvent) {
        let all = continuations.withLock { Array($0.values) }
        for c in all { c.yield(event) }
    }

    public func finish() {
        let all = continuations.withLock { c in
            defer { c.removeAll() }
            return Array(c.values)
        }
        for c in all { c.finish() }
    }
}

/// The environment the engine runs in.
public enum EngineEnvironment {
    /// Variables of the app's own environment that would override `LANG` for gettext.
    public static let removed: Set<String> = ["LC_ALL", "LC_MESSAGES", "LANGUAGE"]

    public static func overrides(preferredLanguages: [String] = Locale.preferredLanguages) -> [String: String] {
        [
            "LANG": lang(preferredLanguages: preferredLanguages),
            // Line by line on the pipe, in UTF-8, whatever Python would choose for a pipe.
            "PYTHONUNBUFFERED": "1",
            "PYTHONIOENCODING": "utf-8",
        ]
    }

    /// "de-DE" → "de_DE.UTF-8", "pl" → "pl.UTF-8", "zh-Hans-CN" → "zh_CN.UTF-8".
    public static func lang(preferredLanguages: [String]) -> String {
        guard let first = preferredLanguages.first else { return "en_US.UTF-8" }
        let language = Locale.Language(identifier: first)
        guard let code = language.languageCode?.identifier else { return "en_US.UTF-8" }
        if let region = language.region?.identifier {
            return "\(code)_\(region).UTF-8"
        }
        return "\(code).UTF-8"
    }
}

/// Which engine to run.
public enum EngineLocation: Sendable, Equatable {
    /// The in-memory engine; `scenario` as `MockEngine.Scenario` names it.
    case mock(scenario: String?)
    case executable(URL)

    public static let environmentKey = "OPENEXPRESS_ENGINE"
    public static let developmentPath = ".venvs/openexpress-mac/bin/openexpress"
    public static let bundledPath = "engine/bin/openexpress"

    /// `OPENEXPRESS_ENGINE` (a path, "mock" or "mock:<scenario>"), then the path set in
    /// Settings (debug), then the engine inside the app, then the development venv.
    public static func resolve(environment: [String: String], override: String?,
                               resources: URL?, home: URL,
                               fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> EngineLocation {
        for candidate in [environment[environmentKey], override] {
            guard let raw = candidate?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
            if raw == "mock" { return .mock(scenario: nil) }
            if raw.hasPrefix("mock:") { return .mock(scenario: String(raw.dropFirst(5))) }
            let expanded = (raw as NSString).expandingTildeInPath
            return .executable(URL(fileURLWithPath: expanded))
        }
        if let bundled = resources?.appending(path: bundledPath), fileExists(bundled.path) {
            return .executable(bundled)
        }
        return .executable(home.appending(path: developmentPath))
    }
}
