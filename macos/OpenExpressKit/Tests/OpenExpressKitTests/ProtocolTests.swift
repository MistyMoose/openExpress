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

    /// Points in the engine's format (activities.track): short names, ISO time. Made-up place.
    @Test func trackPointsAsTheEngineSendsThem() throws {
        let json = #"{"points": [{"lat": 51.5007, "lon": -0.1246, "time": "2030-01-01T12:00:00+01:00", "hr": 72, "alt": -7.0, "speed": 0.898}, {"lat": 51.5008, "lon": -0.1247, "time": "2030-01-01T12:00:05.500000+01:00"}]}"#
        let track = try EngineCoding.decoder().decode(ActivityTrack.self, from: Data(json.utf8))
        #expect(track.points.count == 2)
        #expect(track.points[0].latitude == 51.5007)
        #expect(track.points[0].heartRate == 72)
        #expect(track.points[0].elevation == -7.0)
        #expect(track.points[0].time == 0)
        #expect(track.points[1].time == 5.5)
        #expect(track.points[1].heartRate == nil)
    }

    @Test func busyEvent() {
        let ev = EngineIncoming.parse(#"{"event": "device.busy", "params": {"device": "1", "program": "Garmin Express Service"}}"#)
        #expect(ev == .event(.deviceBusy(DeviceBusy(device: "1", program: "Garmin Express Service", name: nil))))
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
            #expect(a.sportName == "trail_running")   // the engine's name, as it is
        }
    }

    @Test func syncResult() {
        let r = SyncResult(raw: ["dry_run": false, "uploaded": ["a.fit", "b.fit"], "downloaded": 1,
                                 "sentence": "Synced.", "drop_folder": ["path": "/x", "copied": 3, "bytes": 1, "incomplete": 0],
                                 "strava": ["uploaded": 2, "duplicates": 0]])
        #expect(r.uploaded == 2)
        #expect(r.downloaded == 1)
        #expect(r.sentence == "Synced.")
        #expect(r.stravaUploads == 2)
        #expect(r.dropFolderCopies == 3)
        #expect(SyncResult(raw: ["strava": ["error": "rate limited"], "drop_folder": nil]).stravaError == "rate limited")
    }

    @Test func commandLineAndMapResults() {
        #expect(OperationResult(raw: ["exit_code": 0, "lines": ["ok"]]).failureMessage == nil)
        #expect(OperationResult(raw: ["exit_code": 1, "lines": ["a", "No room on the device."]]).failureMessage == "a\nNo room on the device.")
        let maps = OperationResult(raw: ["dry_run": false, "maps": [
            ["name": "A", "done": true, "exit_code": 0, "lines": []],
            ["name": "B", "done": false, "code": "failed", "reason": "Not enough space."]]])
        #expect(maps.refused == ["B": "Not enough space."])
        #expect(maps.failureMessage == "B: Not enough space.")
    }

    @Test func finalProtocolShapes() throws {
        let hello = try JSONValue(["engine": "1.0", "protocol": 1, "platform": "darwin", "methods": ["hello"]]).decode(EngineHello.self)
        #expect(hello.protocolVersion == 1)
        let busy = EngineIncoming.parse(#"{"event": "device.busy", "params": {"device": null, "program": "Garmin Express Service", "name": "fēnix 8"}}"#)
        #expect(busy == .event(.deviceBusy(DeviceBusy(device: nil, program: "Garmin Express Service", name: "fēnix 8"))))
        let log = EngineIncoming.parse(#"{"event": "log", "params": {"level": "info", "message": "x", "request": 4}}"#)
        #expect(log == .event(.log(EngineLogLine(level: "info", message: "x", request: 4))))
        let strava = try JSONValue(["configured": true, "connected": false, "athlete_id": nil, "athlete_name": nil,
                                    "authorize_url": "https://www.strava.com/oauth/authorize?x=1"]).decode(StravaStatus.self)
        #expect(strava.configured && !strava.connected)
        #expect(strava.authorizeURL == "https://www.strava.com/oauth/authorize?x=1")
        let apps = try JSONValue(["exit_code": 0, "lines": ["Klimat"]]).decode(AppsList.self)
        #expect(apps.exitCode == 0 && apps.lines == ["Klimat"])
        let a = try JSONValue(["name": "Morning Run", "source": "backup", "path": "/b/x.fit", "size": 10,
                               "start": "2026-11-17T09:41:00+01:00", "sport": "running", "sport_id": 1,
                               "distance": 5000, "duration": 1500, "ascent": nil, "state": "complete"]).decode(Activity.self)
        #expect(a.fitPath == "/b/x.fit" && a.isOnThisMac && a.state == "complete")
        let own = try JSONValue(["maps": [], "own_maps": [["file": "a.img", "size": 5, "title": "Alps", "path": "Garmin/a.img"]],
                                 "free": 1, "message": "No maps service."]).decode(MapsList.self)
        #expect(own.ownMaps.first?.name == "Alps" && own.message == "No maps service.")
    }

    @Test func mapVersionChange() {
        #expect(DeviceMap(name: "A", version: "2025.20", size: 1, installed: true, status: .update, installedVersion: "2025.10").versionChange == "2025.10 → 2025.20")
        #expect(DeviceMap(name: "A", version: "2025.20", size: 1, installed: false, status: .available).versionChange == "new · 2025.20")
    }

    @Test func shortName() {
        #expect(Device(unitID: "1", name: "fēnix 8 – 47 mm, AMOLED", connected: true).shortName == "fēnix 8")
        #expect(Device(unitID: "1", name: "Edge 1050", connected: true).shortName == "Edge 1050")
        #expect(Device(unitID: "1", name: "Instinct 3 - 45mm Tactical", connected: true).shortName == "Instinct 3")
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

    @Test func backupsAsTheEngineSendsThem() throws {
        let line = #"{"backups": [{"path": "/b/42/2026-11-15 (08.30.00)", "date": "2026-11-15T08:30:00+01:00", "files": 4210, "bytes": 1200000000}]}"#
        let list = try EngineCoding.decoder().decode(BackupsList.self, from: Data(line.utf8))
        #expect(list.backups[0].files == 4210 && list.backups[0].bytes == 1_200_000_000)
        #expect(list.backups[0].url.lastPathComponent == "2026-11-15 (08.30.00)")
    }

    @Test func formats() {
        #expect(Format.duration(605) == "10:05")
        #expect(Format.duration(3725) == "1:02:05")
    }
}
