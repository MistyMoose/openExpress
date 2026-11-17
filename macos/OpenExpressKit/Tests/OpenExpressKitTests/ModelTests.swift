import Foundation
import Testing
@testable import OpenExpressKit

@MainActor
final class RecordingNotifier: Notifier {
    var notes: [(String, String)] = []
    func notify(title: String, body: String) { notes.append((title, body)) }
}

@MainActor
@Suite("View models against the MockEngine")
struct ModelTests {
    func makeApp(_ scenario: MockEngine.Scenario = .standard) -> (AppModel, MockEngine) {
        let engine = MockEngine(scenario: scenario, stepDelay: .milliseconds(1))
        let defaults = UserDefaults(suiteName: "oe-test-\(UUID().uuidString)")!
        let app = AppModel(engine: engine, settings: AppSettings(defaults: defaults))
        return (app, engine)
    }

    @Test func bootstrapSelectsConnectedDevice() async {
        let (app, _) = makeApp()
        await app.start()
        #expect(app.engineState == .ready)
        #expect(app.account?.signedIn == true)
        #expect(app.connectedDevices.map(\.unitID) == [MockEngine.fenixID])
        #expect(app.rememberedDevices.map(\.unitID) == [MockEngine.edgeID])
        #expect(app.selection == .device(MockEngine.fenixID))
        #expect(app.isShowingSetup == false)
    }

    @Test func firstRunShowsSetup() async {
        let (app, _) = makeApp(.firstRun)
        await app.start()
        #expect(app.isShowingSetup)
    }

    @Test func automaticModeBacksUpSyncsChecksAndNeverInstalls() async throws {
        let (app, engine) = makeApp()
        let notifier = RecordingNotifier()
        app.notifier = notifier
        await app.start()
        await app.runAutomatic(MockEngine.fenixID)
        let methods = await engine.calls.map(\.method)
        let tail = methods.filter { ["device.backup", "device.sync", "updates.list", "maps.list", "updates.install", "maps.install", "maps.update"].contains($0) }
        #expect(Array(tail.drop { $0 != "device.backup" }) == ["device.backup", "device.sync", "updates.list", "maps.list"])
        #expect(!methods.contains("updates.install"))
        #expect(notifier.notes.count == 1)
        #expect(notifier.notes.first?.1.contains("Synced") == true)
        let model = try #require(app.model(for: MockEngine.fenixID))
        #expect(model.installAllParts.count == 2)
        #expect(app.pendingUpdatesCount == 3) // 2 software + 1 map
    }

    @Test func attachEventTriggersAutomaticMode() async throws {
        let (app, engine) = makeApp()
        let notifier = RecordingNotifier()
        app.notifier = notifier
        await app.start()
        await engine.simulateAttach(MockEngine.edgeID)
        for _ in 0..<200 where notifier.notes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(notifier.notes.first?.0 == "Edge 1050")
        #expect(app.connectedDevices.count == 2)
    }

    @Test func busyDevice() async throws {
        let (app, _) = makeApp(.busy)
        await app.start()
        let model = try #require(app.model(for: MockEngine.fenixID))
        #expect(model.busyBy == "Garmin Express Service")
        await model.load(.updates)
        #expect(model.busyBy == "Garmin Express Service")
        #expect(model.errorMessage == nil)
    }

    @Test func installAllSkipsBetaAndMarksWaiting() async throws {
        let (app, _) = makeApp()
        await app.start()
        let model = try #require(app.model(for: MockEngine.fenixID))
        await model.load(.updates)
        model.install()
        #expect(model.operation?.kind == .installUpdates)
        await model.waitForOperation()
        #expect(model.operation == nil)
        #expect(model.waitingUpdates.count == 2)
        #expect(model.pendingUpdates.map(\.beta) == [true])
    }

    @Test func cancelOperation() async throws {
        let engine = MockEngine(stepDelay: .milliseconds(50))
        let app = AppModel(engine: engine, settings: AppSettings(defaults: UserDefaults(suiteName: "oe-\(UUID())")!))
        await app.start()
        let model = try #require(app.model(for: MockEngine.fenixID))
        model.sync()
        try await Task.sleep(for: .milliseconds(80))
        model.cancelOperation()
        await model.waitForOperation()
        #expect(model.lastOutcome == "Cancelled.")
    }

    @Test func signIn() async {
        let (app, _) = makeApp(.signedOut)
        await app.start()
        #expect(app.account?.signedIn == false)
        await app.completeSignIn(ticketURL: "https://sso.garmin.com/sso/embed?ticket=ST-1-x")
        #expect(app.account?.signedIn == true)
        #expect(app.alertMessage == nil)
    }
}
