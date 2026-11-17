import Foundation
import Testing
@testable import OpenExpressKit

@Suite("Protocol: messages and models (docs/ENGINE.md)")
struct ProtocolTests {
    @Test func requestLine() throws {
        let line = try EngineRequest(id: 7, method: "maps.list", params: ["device": "3491967800", "all": false]).line()
        #expect(String(decoding: line, as: UTF8.self)
            == #"{"id":7,"method":"maps.list","params":{"all":false,"device":"3491967800"}}"#)
    }

    @Test func parsesResponseErrorAndEvent() throws {
        #expect(EngineIncoming.parse(#"{"id": 7, "result": {"x": 1}}"#) == .response(id: 7, result: .success(["x": 1])))
        let err = EngineIncoming.parse(#"{"id": 7, "error": {"code": "device_busy", "message": "Garmin Express Service is using the device. Quit it, then try again.", "data": {"program": "Garmin Express Service"}}}"#)
        guard case .response(7, .failure(let e)) = err else { Issue.record("not an error"); return }
        #expect(e.code == "device_busy")
        #expect(e.busyProgram == "Garmin Express Service")
        #expect(e.localizedDescription.hasPrefix("Garmin Express Service is using"))

        let ev = EngineIncoming.parse(#"{"event": "progress", "params": {"request": 9, "phase": "downloading", "done": 1048576, "total": 52428800, "item": "TopoActive Western Europe"}}"#)
        guard case .event(.progress(let p)) = ev else { Issue.record("not progress"); return }
        #expect(p.request == 9)
        #expect(p.item == "TopoActive Western Europe")
        #expect(abs((p.fraction ?? 0) - 0.02) < 0.0001)
        #expect(EngineIncoming.parse("Traceback (most recent call last):") == nil)
    }

    @Test func busyEvent() {
        let ev = EngineIncoming.parse(#"{"event": "device.busy", "params": {"device": "1", "program": "Garmin Express Service"}}"#)
        #expect(ev == .event(.deviceBusy(DeviceBusy(device: "1", program: "Garmin Express Service"))))
    }

    @Test func device() throws {
        let json: JSONValue = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"unit_id": "3491967800", "name": "fēnix 8", "part_number": "006-B4536-00", "software": "21.19",
         "connected": true, "busy_by": null, "storage": {"free": 1000, "capacity": 4000},
         "last_sync": "2026-11-17T09:41:00.123456+01:00"}
        """#.utf8))
        let d = try json.decode(Device.self)
        #expect(d.unitID == "3491967800")
        #expect(d.partNumber == "006-B4536-00")
        #expect(d.storage?.usedFraction == 0.75)
        #expect(d.kind == .watch)
        let expected = try Date("2026-11-17T08:41:00Z", strategy: .iso8601).addingTimeInterval(0.123456)
        #expect(abs(d.lastSync!.timeIntervalSince(expected)) < 0.001)
        // Round trip through the engine's coding.
        let again = try JSONValue(encoding: d).decode(Device.self)
        #expect(again.unitID == d.unitID && again.storage == d.storage && again.name == d.name)
        #expect(abs(again.lastSync!.timeIntervalSince(d.lastSync!)) < 0.001)
    }

    @Test func dates() {
        #expect(EngineCoding.parseDate("2026-11-17T09:41:00+01:00") != nil)
        #expect(EngineCoding.parseDate("2026-11-17T08:41:00Z") != nil)
        #expect(EngineCoding.parseDate("2026-11-17T09:41:00.5+01:00")!.timeIntervalSince(
            EngineCoding.parseDate("2026-11-17T09:41:00+01:00")!) == 0.5)
        #expect(EngineCoding.parseDate("yesterday") == nil)
    }

    @Test func updatesAndMaps() throws {
        let u = try JSONValue(["updates": [["part": "006-B4536-00", "name": "System Software", "version": "21.22",
                                             "installed": "21.19", "size": 412000000, "beta": false,
                                             "waiting_on_device": true]], "beta_offered": true])
            .decode(UpdatesList.self)
        #expect(u.betaOffered)
        #expect(u.updates.first?.waitingOnDevice == true)
        let m = try JSONValue(["maps": [["name": "TopoActive", "version": "2025.20", "size": 1, "installed": true, "status": "up to date"],
                                        ["name": "Ski", "size": 1, "installed": true, "status": "update"],
                                        ["name": "Golf", "size": 1, "installed": false, "status": "something new"]],
                               "own_maps": ["contours.img", ["name": "trails.img", "size": 5]], "free": 100])
            .decode(MapsList.self)
        #expect(m.installed.count == 2)
        #expect(m.updatable.map(\.name) == ["Ski"])
        #expect(m.maps.last?.status == .unknown)
        #expect(m.ownMaps.map(\.name) == ["contours.img", "trails.img"])
    }

    @Test func activityFITPathSpellings() throws {
        for key in ["fit_path", "fit", "path"] {
            var o: [String: JSONValue] = ["start": "2026-11-17T09:41:00+01:00", "sport": "trail_running"]
            o[key] = "/a.fit"
            let a = try JSONValue.object(o).decode(Activity.self)
            #expect(a.fitPath == "/a.fit")
            #expect(a.sportName == "Trail Running")
        }
    }

    @Test func syncResultIsLenient() {
        let r = SyncResult(raw: ["uploaded": ["a.fit", "b.fit"], "downloaded": 1, "strava": 2])
        #expect(r.uploaded == 2)
        #expect(r.downloaded == 1)
        #expect(r.stravaUploads == 2)
        #expect(r.dropFolderCopies == 0)
    }
}

private extension JSONValue {
    init(_ v: JSONValue) { self = v }
}

@Suite("Support")
struct SupportTests {
    @Test func lang() {
        #expect(EngineEnvironment.lang(preferredLanguages: ["de-DE", "en"]) == "de_DE.UTF-8")
        #expect(EngineEnvironment.lang(preferredLanguages: ["pl"]) == "pl.UTF-8")
        #expect(EngineEnvironment.lang(preferredLanguages: ["zh-Hans-CN"]) == "zh_CN.UTF-8")
        #expect(EngineEnvironment.lang(preferredLanguages: []) == "en_US.UTF-8")
        #expect(EngineEnvironment.overrides(preferredLanguages: ["nl-NL"])["PYTHONUNBUFFERED"] == "1")
    }

    @Test func engineLocation() {
        let home = URL(fileURLWithPath: "/Users/x")
        let res = URL(fileURLWithPath: "/A.app/Contents/Resources")
        #expect(EngineLocation.resolve(environment: ["OPENEXPRESS_ENGINE": "mock"], override: "/e", resources: res, home: home) == .mock(scenario: nil))
        #expect(EngineLocation.resolve(environment: ["OPENEXPRESS_ENGINE": "mock:busy"], override: nil, resources: nil, home: home) == .mock(scenario: "busy"))
        #expect(EngineLocation.resolve(environment: [:], override: "/opt/oe", resources: res, home: home) == .executable(URL(fileURLWithPath: "/opt/oe")))
        #expect(EngineLocation.resolve(environment: [:], override: "", resources: res, home: home, fileExists: { _ in true })
            == .executable(res.appending(path: "engine/bin/openexpress")))
        #expect(EngineLocation.resolve(environment: [:], override: nil, resources: res, home: home, fileExists: { _ in false })
            == .executable(URL(fileURLWithPath: "/Users/x/.venvs/openexpress-mac/bin/openexpress")))
    }

    @Test func signInTicket() {
        #expect(SignInTicket.fromURL(URL(string: "https://sso.garmin.com/sso/embed?ticket=ST-0123-abc-cas")!)
            == "https://sso.garmin.com/sso/embed?ticket=ST-0123-abc-cas")
        #expect(SignInTicket.fromURL(URL(string: "https://sso.garmin.com/sso/signin")!) == nil)
        #expect(SignInTicket.fromPageText("{serviceUrl: 'https://sso.garmin.com/sso/embed', serviceTicket: 'ST-1234567-AbCdEf-sso'}")
            == "https://sso.garmin.com/sso/embed?ticket=ST-1234567-AbCdEf-sso")
        #expect(SignInTicket.fromPageText(#"{"serviceUrl":"https://sso.garmin.com/sso/embed","serviceTicket":"ST-9-x"}"#)
            == "https://sso.garmin.com/sso/embed?ticket=ST-9-x")
        #expect(SignInTicket.fromPageText("<html>Sign in</html>") == nil)
    }

    @Test func backupFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "oe-backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let unit = root.appending(path: "42")
        for name in ["2026-11-01 (10.00.00)", "2026-11-15 (08.30.00)", ".partial-2026-11-16 (01.00.00)", "notes"] {
            try FileManager.default.createDirectory(at: unit.appending(path: name), withIntermediateDirectories: true)
        }
        let snaps = BackupFolder.snapshots(root: root, unitID: "42")
        #expect(snaps.map { $0.url.lastPathComponent } == ["2026-11-15 (08.30.00)", "2026-11-01 (10.00.00)"])
        #expect(BackupFolder.snapshots(root: root, unitID: "7").isEmpty)
    }

    @Test func formats() {
        #expect(Format.duration(605) == "10:05")
        #expect(Format.duration(3725) == "1:02:05")
    }
}
