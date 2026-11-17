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
        // Garmin devices report no real battery level: none is shown.
        #expect(app.devices.allSatisfy { $0.battery == nil })
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

    @Test func installAllAsksFirstThenInstallsSoftwareAndMaps() async throws {
        let (app, engine) = makeApp()
        await app.start()
        let model = try #require(app.model(for: MockEngine.fenixID))
        await model.load(.updates)
        model.requestInstallAll()
        let plan = try #require(model.pendingPlan)
        #expect(model.operation == nil)                           // nothing before the confirmation
        #expect(plan.items.map(\.name) == ["System Software", "GPS Chipset", "TopoActive Europe"])
        #expect(plan.items.last?.change == "2025.10 → 2025.20")
        #expect(plan.totalBytes == 412_000_000 + 2_400_000 + 9_800_000_000)
        #expect(plan.hasSoftware)
        #expect(plan.freeAfter == 18_740_000_000 - plan.totalBytes)
        model.perform(plan)
        #expect(model.pendingPlan == nil)
        await model.waitForOperation()
        #expect(model.waitingUpdates.count == 2)
        #expect(model.pendingUpdates.map(\.beta) == [true])
        #expect(model.mapUpdates.isEmpty)
        let methods = await engine.calls.map(\.method)
        #expect(methods.contains("updates.install") && methods.contains("maps.update"))
        #expect(model.lastOutcome == "Unplug the device to install the software.")
    }

    @Test func largeMapIsConfirmedSmallIsNot() async throws {
        let (app, engine) = makeApp()
        await app.start()
        let model = try #require(app.model(for: MockEngine.fenixID))
        await model.load(.maps)
        let big = try #require(model.maps?.available.first { $0.size >= InstallPlan.largeMap })
        model.requestInstall(map: big)
        #expect(model.pendingPlan?.items.first?.change == "new · 2025.20")
        #expect(model.operation == nil)
        model.pendingPlan = nil
        model.requestInstall(map: DeviceMap(name: "Ski Resorts", version: "2025.10", size: 120_000_000, installed: false, status: .available))
        #expect(model.pendingPlan == nil)
        await model.waitForOperation()
        #expect(await engine.calls.map(\.method).contains("maps.install"))
    }

    /// One source of truth: the badge after Overview equals the badge after Updates, the
    /// menu bar count and what Install All lists; betas are left out.
    @Test func badgeCountIsTheSameEverywhere() async throws {
        let (app, _) = makeApp()
        await app.start()
        let model = try #require(app.model(for: MockEngine.fenixID))
        await model.load(.overview)
        let afterOverview = model.badgeCount
        await model.load(.updates)
        #expect(afterOverview == 3)
        #expect(model.badgeCount == afterOverview)
        #expect(app.pendingUpdatesCount == afterOverview)
        model.requestInstallAll()
        #expect(model.pendingPlan?.items.count == afterOverview)
        #expect(model.updates.contains { $0.beta })
    }

    @Test func firstSyncAsksForTheChoice() async throws {
        let (app, engine) = makeApp()
        await app.start()
        await engine.requireFirstSyncChoice(MockEngine.fenixID)
        let model = try #require(app.model(for: MockEngine.fenixID))
        model.sync()
        await model.waitForOperation()
        #expect(model.needsFirstSyncChoice)
        #expect(model.errorMessage == nil)
        model.sync(firstRun: .newOnly)
        await model.waitForOperation()
        #expect(!model.needsFirstSyncChoice)
        #expect(model.lastOutcome?.hasPrefix("Synced: 4 files uploaded") == true)
        let last = await engine.calls.last { $0.method == "device.sync" }
        #expect(last?.params?["first_run"]?.stringValue == "baseline")
    }

    @Test func busyEventWithoutDeviceMatchesByName() async throws {
        let (app, engine) = makeApp()
        await app.start()
        await engine.simulateBusy(MockEngine.fenixID, knownSerial: false)
        for _ in 0..<100 where app.model(for: MockEngine.fenixID)?.busyBy == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(app.model(for: MockEngine.fenixID)?.busyBy == "Garmin Express Service")
        #expect(app.unassignedBusy == nil)
    }

    @Test func backupSettingsComeFromTheEngine() async {
        let (app, _) = makeApp()
        await app.start()
        #expect(app.backupKeep == 3)
        #expect(app.backupFolder.path.hasSuffix("Documents/Garmin/Backups"))
        await app.setEngineSetting("backup_keep", 5)
        #expect(app.backupKeep == 5)
    }

    @Test func stravaConnectFlow() async {
        let (app, _) = makeApp()
        await app.start()
        await app.startStrava(clientID: "1", clientSecret: "s")
        #expect(app.stravaAuthorizeURL?.absoluteString.contains("redirect_uri=\(AppModel.stravaRedirectURI)") == true)
        await app.finishStrava(code: "abc")
        #expect(app.strava?.connected == true)
        #expect(app.stravaAuthorizeURL == nil)
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
