import Foundation
import Testing
@testable import OpenExpressKit

/// The real EngineClient against a tiny engine written in sh: process, framing, ids,
/// events, progress routing, errors and the restart after a crash.
@Suite("EngineClient against a fake engine process", .serialized)
struct EngineClientTests {
    static let script = #"""
    while IFS= read -r l; do
      id=$(printf '%s' "$l" | sed -E 's/.*"id":([0-9]+).*/\1/')
      m=$(printf '%s' "$l" | sed -E 's/.*"method":"([^"]*)".*/\1/')
      case "$m" in
        hello) printf '{"id": %s, "result": {"engine": "fake", "platform": "darwin", "methods": ["hello"]}}\n' "$id" ;;
        busy) printf '{"id": %s, "error": {"code": "device_busy", "message": "Garmin Express Service is using the device.", "data": {"program": "Garmin Express Service"}}}\n' "$id" ;;
        work)
          printf 'a stray line that is not JSON\n'
          printf '{"event": "progress", "params": {"request": %s, "phase": "copying", "done": 1, "total": 2}}\n' "$id"
          printf '{"event": "log", "params": {"level": "info", "message": "half"}}\n'
          printf '{"event": "progress", "params": {"request": %s, "phase": "copying", "done": 2, "total": 2}}\n' "$id"
          printf '{"id": %s, "result": {"lang": "%s"}}\n' "$id" "$LANG" ;;
        crash) exit 3 ;;
        shutdown) printf '{"id": %s, "result": {}}\n' "$id"; exit 0 ;;
        *) printf '{"id": %s, "error": {"code": "unknown_method", "message": "no"}}\n' "$id" ;;
      esac
    done
    """#

    func makeClient() throws -> (EngineClient, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "fake-engine-\(UUID().uuidString).sh")
        try Self.script.write(to: url, atomically: true, encoding: .utf8)
        let cfg = EngineClient.Configuration(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: [url.path],
            environment: EngineEnvironment.overrides(preferredLanguages: ["de-DE"]),
            restartDelay: .milliseconds(10))
        return (EngineClient(configuration: cfg), url)
    }

    @Test func requestsEventsAndProgress() async throws {
        let (client, script) = try makeClient()
        defer { try? FileManager.default.removeItem(at: script) }
        let events = await client.events()
        try await client.start()

        let hello = try await client.hello(client: "test")
        #expect(hello.engine == "fake")

        let seen = ProgressRecorder()
        let r = try await client.call("work", params: nil, progress: { seen.add($0) })
        #expect(r["lang"]?.stringValue == "de_DE.UTF-8")
        #expect(seen.values.map(\.done) == [1, 2])

        var iterator = events.makeAsyncIterator()
        var names: [String] = []
        while names.count < 3, let e = await iterator.next() {
            switch e {
            case .progress: names.append("progress")
            case .log(let l): names.append("log:\(l.message)")
            default: names.append("other")
            }
        }
        #expect(names == ["progress", "log:half", "progress"])

        await #expect(throws: EngineError.self) { try await client.call("nope") }
        do {
            _ = try await client.call("busy")
            Issue.record("expected device_busy")
        } catch let e as EngineError {
            #expect(e.busyProgram == "Garmin Express Service")
        }
        await client.shutdown()
        #expect(await client.isRunning == false)
    }

    @Test func restartsAfterCrash() async throws {
        let (client, script) = try makeClient()
        defer { try? FileManager.default.removeItem(at: script) }
        let events = await client.events()
        try await client.start()
        await #expect(throws: EngineError.terminated) { try await client.call("crash") }
        var iterator = events.makeAsyncIterator()
        var restarted = false
        while let e = await iterator.next() {
            if case .engineRestarted = e { restarted = true; break }
        }
        #expect(restarted)
        #expect(try await client.hello(client: "test").engine == "fake")
        await client.shutdown()
    }

    @Test func launchFailure() async {
        let client = EngineClient(configuration: .init(executable: URL(fileURLWithPath: "/nonexistent/openexpress")))
        await #expect(throws: EngineError.self) { try await client.start() }
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [EngineProgress] = []
    func add(_ p: EngineProgress) { lock.withLock { _values.append(p) } }
    var values: [EngineProgress] { lock.withLock { _values } }
}
