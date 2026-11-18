import Foundation

/// The filters of the Activities page: sports (search tokens, OR), free text, and ranges of
/// distance, duration and date. Pure: `apply` works on the list already loaded, no engine
/// call. Kept per device for the session (`DeviceModel.activityFilter`).
public struct ActivityFilter: Equatable, Sendable {
    /// An inclusive range; nil ends are open.
    public struct ValueRange: Equatable, Sendable {
        public var min: Double?
        public var max: Double?

        public init(min: Double? = nil, max: Double? = nil) {
            self.min = min
            self.max = max
        }

        public static let any = ValueRange()

        public var isAny: Bool { min == nil && max == nil }

        /// A missing value passes only when the range is Any.
        public func contains(_ value: Double?) -> Bool {
            if isAny { return true }
            guard let value else { return false }
            if let min, value < min { return false }
            if let max, value > max { return false }
            return true
        }
    }

    public enum DistancePreset: String, CaseIterable, Identifiable, Sendable {
        case any, under5, from5to10, from10to21, from21to42, over42, custom
        public var id: String { rawValue }

        /// Metres.
        public var range: ValueRange? {
            switch self {
            case .any: .any
            case .under5: ValueRange(max: 5_000)
            case .from5to10: ValueRange(min: 5_000, max: 10_000)
            case .from10to21: ValueRange(min: 10_000, max: 21_100)
            case .from21to42: ValueRange(min: 21_100, max: 42_200)
            case .over42: ValueRange(min: 42_200)
            case .custom: nil
            }
        }

        public var title: String {
            switch self {
            case .any: String(localized: "Any distance")
            case .under5: String(localized: "Under 5 km")
            case .from5to10: String(localized: "5–10 km")
            case .from10to21: String(localized: "10–21 km")
            case .from21to42: String(localized: "21–42 km")
            case .over42: String(localized: "Over 42 km")
            case .custom: String(localized: "Custom")
            }
        }
    }

    public enum DurationPreset: String, CaseIterable, Identifiable, Sendable {
        case any, under30, from30to60, from1to2h, over2h, custom
        public var id: String { rawValue }

        /// Seconds.
        public var range: ValueRange? {
            switch self {
            case .any: .any
            case .under30: ValueRange(max: 1_800)
            case .from30to60: ValueRange(min: 1_800, max: 3_600)
            case .from1to2h: ValueRange(min: 3_600, max: 7_200)
            case .over2h: ValueRange(min: 7_200)
            case .custom: nil
            }
        }

        public var title: String {
            switch self {
            case .any: String(localized: "Any duration")
            case .under30: String(localized: "Under 30 min")
            case .from30to60: String(localized: "30–60 min")
            case .from1to2h: String(localized: "1–2 h")
            case .over2h: String(localized: "Over 2 h")
            case .custom: String(localized: "Custom")
            }
        }
    }

    public enum DatePreset: String, CaseIterable, Identifiable, Sendable {
        case any, last7, last30, last365, thisYear
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .any: String(localized: "Any date")
            case .last7: String(localized: "Last 7 days")
            case .last30: String(localized: "Last 30 days")
            case .last365: String(localized: "Last 365 days")
            case .thisYear: String(localized: "This year")
            }
        }

        /// The earliest start that passes, or nil for Any.
        public func earliest(now: Date, calendar: Calendar) -> Date? {
            switch self {
            case .any: nil
            case .last7: calendar.date(byAdding: .day, value: -7, to: now)
            case .last30: calendar.date(byAdding: .day, value: -30, to: now)
            case .last365: calendar.date(byAdding: .day, value: -365, to: now)
            case .thisYear: calendar.dateInterval(of: .year, for: now)?.start
            }
        }
    }

    /// Sports (as the engine names them, "trail_running"); several: any of them.
    public var sports: Set<String> = []
    /// Matches the sport's name, the activity's name and its date as shown.
    public var text: String = ""
    public var distancePreset: DistancePreset = .any
    /// Metres, for `.custom`.
    public var customDistance: ValueRange = .any
    public var durationPreset: DurationPreset = .any
    /// Seconds, for `.custom`.
    public var customDuration: ValueRange = .any
    public var datePreset: DatePreset = .any

    public init() {}

    public var distance: ValueRange { distancePreset.range ?? customDistance }
    public var duration: ValueRange { durationPreset.range ?? customDuration }

    /// A range filter is set (what the Filter button shows filled); tokens and text are
    /// shown in the search field.
    public var hasRangeFilters: Bool { !distance.isAny || !duration.isAny || datePreset != .any }
    public var isActive: Bool { hasRangeFilters || !sports.isEmpty || !text.trimmingCharacters(in: .whitespaces).isEmpty }

    public mutating func resetRanges() {
        distancePreset = .any
        customDistance = .any
        durationPreset = .any
        customDuration = .any
        datePreset = .any
    }

    public mutating func resetAll() {
        resetRanges()
        sports = []
        text = ""
    }

    public func apply(_ activities: [Activity], now: Date = .now, calendar: Calendar = .current) -> [Activity] {
        activities.filter(matcher(now: now, calendar: calendar))
    }

    /// The test of one activity; what is the same for every activity is worked out once.
    private func matcher(now: Date, calendar: Calendar) -> (Activity) -> Bool {
        let sports = sports, distance = distance, duration = duration
        let earliest = datePreset.earliest(now: now, calendar: calendar)
        let text = text.trimmingCharacters(in: .whitespaces)
        return { a in
            if !sports.isEmpty, !sports.contains(a.sport) { return false }
            if !distance.contains(a.distance) { return false }
            if !duration.contains(a.duration) { return false }
            if let earliest, a.start < earliest { return false }
            if !text.isEmpty {
                let haystack = [a.sportName, a.name ?? "", a.start.formatted(date: .abbreviated, time: .shortened)]
                if !haystack.contains(where: { $0.localizedStandardContains(text) }) { return false }
            }
            return true
        }
    }

    // MARK: The sport scope bar

    /// A click in the scope bar: nil (All) clears; a plain click selects only that sport;
    /// with ⌘ (`extending`) it adds or removes that sport.
    public mutating func select(sport: String?, extending: Bool) {
        guard let sport else {
            sports = []
            return
        }
        if extending {
            if sports.contains(sport) { sports.remove(sport) } else { sports.insert(sport) }
        } else {
            sports = [sport]
        }
    }

    /// Every sport of the list with the number of its activities under the OTHER filters
    /// (ranges and text, not the sport selection): what selecting it would show. Most first,
    /// then by name; a sport with none under the filters stays, with 0.
    public func sportCounts(in activities: [Activity], now: Date = .now,
                            calendar: Calendar = .current) -> [(sport: String, count: Int)] {
        var others = self
        others.sports = []
        var counts = Dictionary(activities.map { ($0.sport, 0) }, uniquingKeysWith: { a, _ in a })
        let matches = others.matcher(now: now, calendar: calendar)
        for a in activities where matches(a) { counts[a.sport, default: 0] += 1 }
        return counts.map { (sport: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.sport.localizedStandardCompare($1.sport) == .orderedAscending }
    }

    /// The sports present in a list, most frequent first.
    public static func sports(in activities: [Activity]) -> [String] {
        let counts = Dictionary(activities.map { ($0.sport, 1) }, uniquingKeysWith: +)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}

/// Sums of a list of activities, of the values that are known.
public struct ActivityTotals: Equatable, Sendable {
    public var count: Int
    public var distance: Double
    public var duration: Double
    public var ascent: Double

    public init(_ activities: [Activity]) {
        count = activities.count
        distance = activities.compactMap(\.distance).reduce(0, +)
        duration = activities.compactMap(\.duration).reduce(0, +)
        ascent = activities.compactMap(\.ascent).reduce(0, +)
    }

    /// "37 of 280 activities · 412 km · 38 hr, 12 min · 5,400 m ascent".
    public func summary(of total: Int) -> String {
        var parts = [count == total
                     ? String(localized: "\(total) activities")
                     : String(localized: "\(count) of \(total) activities")]
        if distance > 0 { parts.append(Format.distance(distance)) }
        if duration > 0 {
            parts.append(Duration.seconds(duration.rounded())
                .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        }
        if ascent > 0 {
            parts.append(String(localized: "\(Measurement(value: ascent, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .asProvided))) ascent"))
        }
        return parts.joined(separator: " · ")
    }
}
