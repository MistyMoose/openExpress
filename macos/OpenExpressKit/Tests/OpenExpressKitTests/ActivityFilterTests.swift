import Foundation
import Testing
@testable import OpenExpressKit

@Suite("Activities filter")
struct ActivityFilterTests {
    static let now = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-17
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return c
    }

    static func a(_ sport: String, km: Double?, min: Double?, daysAgo: Double = 1, ascent: Double? = nil, name: String? = nil) -> Activity {
        Activity(start: now.addingTimeInterval(-daysAgo * 86400), sport: sport, distance: km.map { $0 * 1000 },
                 duration: min.map { $0 * 60 }, fitPath: "\(sport)-\(km ?? -1)-\(daysAgo).fit", name: name, ascent: ascent)
    }

    static let list = [
        a("running", km: 5, min: 28, ascent: 40),
        a("running", km: 10, min: 55, daysAgo: 20, ascent: 80),
        a("cycling", km: 42.2, min: 90, daysAgo: 40),
        a("cycling", km: 80, min: 180, daysAgo: 400),
        a("strength_training", km: nil, min: 45, daysAgo: 3),
        a("hiking", km: 12, min: nil, daysAgo: 8, name: "Utrechtse Heuvelrug"),
    ]

    func apply(_ f: ActivityFilter) -> [Activity] { f.apply(Self.list, now: Self.now, calendar: Self.calendar) }

    @Test func noFilterKeepsEverything() {
        #expect(apply(ActivityFilter()).count == Self.list.count)
        #expect(!ActivityFilter().isActive)
    }

    @Test func sportTokensAreOr() {
        var f = ActivityFilter()
        f.sports = ["running", "hiking"]
        #expect(apply(f).map(\.sport) == ["running", "running", "hiking"])
        #expect(f.isActive && !f.hasRangeFilters)
    }

    @Test func rangesAreInclusive() {
        var f = ActivityFilter()
        f.distancePreset = .from5to10
        #expect(apply(f).map(\.distance) == [5000, 10000])
        f.distancePreset = .custom
        f.customDistance = .init(min: 42_200, max: 42_200)
        #expect(apply(f).count == 1)
        f.resetRanges()
        f.durationPreset = .from1to2h
        #expect(apply(f).map(\.duration) == [5400])       // 90 min; 180 is over, 55 under
        f.durationPreset = .under30
        #expect(apply(f).map(\.duration) == [1680])
    }

    @Test func missingValuesOnlyExcludedWhenThatFilterIsSet() {
        var f = ActivityFilter()
        f.durationPreset = .over2h
        #expect(!apply(f).contains { $0.sport == "hiking" })      // no duration
        f.resetRanges()
        f.distancePreset = .any
        f.durationPreset = .under30
        #expect(!apply(f).contains { $0.sport == "strength_training" }) // 45 min
        f.resetRanges()
        f.distancePreset = .under5
        #expect(!apply(f).contains { $0.sport == "strength_training" }) // no distance
        #expect(f.hasRangeFilters)
    }

    @Test func dates() {
        var f = ActivityFilter()
        f.datePreset = .last7
        #expect(apply(f).count == 2)
        f.datePreset = .last30
        #expect(apply(f).count == 4)
        f.datePreset = .last365
        #expect(apply(f).count == 5)
        f.datePreset = .thisYear
        #expect(apply(f).count == 5)
    }

    @Test func text() {
        var f = ActivityFilter()
        f.text = "heuvel"
        #expect(apply(f).map(\.sport) == ["hiking"])
        f.text = "strength"
        #expect(apply(f).map(\.sport) == ["strength_training"])
        f.sports = ["running"]
        #expect(apply(f).isEmpty)
    }

    @Test func suggestedSportsMostFrequentFirst() {
        #expect(ActivityFilter.sports(in: Self.list) == ["cycling", "running", "hiking", "strength_training"])
    }

    @Test func scopeBarSelection() {
        var f = ActivityFilter()
        f.select(sport: "running", extending: false)
        #expect(f.sports == ["running"])
        f.select(sport: "cycling", extending: false)          // a plain click: only that one
        #expect(f.sports == ["cycling"])
        f.select(sport: "running", extending: true)           // ⌘-click adds
        #expect(f.sports == ["cycling", "running"])
        #expect(apply(f).count == 4)                          // OR
        f.select(sport: "cycling", extending: true)           // ⌘-click removes
        #expect(f.sports == ["running"])
        f.select(sport: nil, extending: false)                // All
        #expect(f.sports.isEmpty)
    }

    @Test func scopeBarCountsFollowTheOtherFilters() {
        var f = ActivityFilter()
        f.sports = ["hiking"]                                  // the selection does not change counts
        let all = f.sportCounts(in: Self.list, now: Self.now, calendar: Self.calendar)
        #expect(all.map(\.sport) == ["cycling", "running", "hiking", "strength_training"])
        #expect(all.map(\.count) == [2, 2, 1, 1])
        f.datePreset = .last30
        let recent = f.sportCounts(in: Self.list, now: Self.now, calendar: Self.calendar)
        #expect(recent.map(\.sport) == ["running", "hiking", "strength_training", "cycling"])
        #expect(recent.map(\.count) == [2, 1, 1, 0])          // a sport with none stays, with 0
    }

    @Test func totalsSumWhatIsKnown() {
        let t = ActivityTotals(Self.list)
        #expect(t.count == 6)
        #expect(t.distance == 5000 + 10000 + 42200 + 80000 + 12000)
        #expect(t.duration == (28 + 55 + 90 + 180 + 45) * 60)
        #expect(t.ascent == 120)
        #expect(t.summary(of: 6).hasPrefix("6 activities · "))
        // The ascent in the units of the Ascent column (feet where roads are in miles).
        #expect(t.summary(of: 6).hasSuffix("· \(Format.elevation(120)) ascent"))
        #expect(ActivityTotals(Array(Self.list.prefix(2))).summary(of: 6).hasPrefix("2 of 6 activities · "))
        #expect(ActivityTotals([]).summary(of: 6) == "0 of 6 activities")
    }
}

import AppKit

@Suite("Sport symbols")
struct SportSymbolTests {
    /// Image(systemName:) draws nothing for a name that does not exist.
    @Test func everySportSymbolExists() {
        for symbol in Activity.allSportSymbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }

    @Test func iconBySportNumberNameAsIs() {
        let a = Activity(start: .now, sport: "Surfing", sportID: 38)
        #expect(a.systemImage == "figure.surfing")
        #expect(Activity(start: .now, sport: "Sport 99", sportID: 99).systemImage == "figure.mixed.cardio")
    }
}

@Suite("Activity titles")
struct ActivityTitleTests {
    @Test func fileNamesAreNotTitles() {
        func title(_ name: String?) -> String? {
            Activity(start: .now, sport: "Running", fitPath: "/b/2026-11-13-10-36-39.fit", name: name).title
        }
        #expect(title("2026-11-13-10-36-39.fit") == nil)
        #expect(title("2026-11-13-10-36-39") == nil)
        #expect(title("Running") == nil)
        #expect(title(nil) == nil)
        #expect(title("Heuvelrug loop") == "Heuvelrug loop")
        #expect(Activity(start: .now, sport: "Running", fitPath: "/b/x.fit").fileName == "x.fit")
    }

    @Test func manyActivitiesInTheMock() async throws {
        let engine = MockEngine(scenario: .many, stepDelay: .milliseconds(0))
        let list = try await engine.activities(MockEngine.fenixID)
        #expect(list.count == 280)
        let request = await engine.calls.last { $0.method == "activities.list" }
        #expect((request?.params?["limit"]?.intValue ?? 0) >= 280)   // all, not the engine's default 20
    }
}
