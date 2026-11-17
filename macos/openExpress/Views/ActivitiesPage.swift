import Charts
import MapKit
import OpenExpressKit
import SwiftUI

struct ActivitiesPage: View {
    @Bindable var model: DeviceModel
    @State private var selection: Activity.ID?
    @State private var search = ""
    @State private var showsInspector = false
    @State private var showsFilters = false
    /// Columns the user can hide from the header's menu; Ascent and Avg HR make room while
    /// the inspector is open.
    @State private var columns = TableColumnCustomization<Activity>()
    /// The columns hidden to fit the width (see `fitColumns`).
    @State private var hiddenColumns: Set<String> = []
    /// "13 Nov, 10:36" instead of "13 Nov 2026 at 10:36" when space is tight.
    @State private var compactDate = false

    private var all: [Activity] { model.activities ?? [] }

    private var rows: [Activity] {
        model.activityFilter.apply(all).sorted(using: model.activitySort)
    }

    private var selected: Activity? { model.activities?.first { $0.id == selection } }


    var body: some View {
        Group {
            if model.activities == nil {
                PageLoadingView(model: model, page: .activities)
            } else if all.isEmpty {
                ContentUnavailableView("No Activities", systemImage: "figure.run",
                                       description: Text("Activities recorded on the device appear here."))
            } else {
                Group {
                    if rows.isEmpty {
                        ContentUnavailableView {
                            Label("No Activities Match", systemImage: "magnifyingglass")
                        } description: {
                            Text("No activity matches the sports, search and filters.")
                        } actions: {
                            Button("Reset Filters", action: resetAll)
                        }
                    } else {
                        table
                            // Only the columns that fit: no clipped number, no sideways scroller.
                            // A new set of columns lays the table out afresh at their widths.
                            .id(TableLayout(hidden: hiddenColumns, compactDate: compactDate, sportWidth: sportWidth))
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { fitColumns(to: $0) }
                    }
                }
                // The sport is the main filter: a scope bar on top, the totals below.
                .safeAreaInset(edge: .top, spacing: 0) {
                    SportScopeBar(filter: $model.activityFilter, activities: all)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { summaryBar }
            }
        }
        // Free text: sport, name and date. ⌘F focuses the field; Escape clears it. The sport
        // selection has one home, the scope bar.
        .searchable(text: $search, placement: .toolbar, prompt: "Search Activities")
        .onAppear {
            // The filters are kept per device for the session.
            search = model.activityFilter.text
            demo()
        }
        .onChange(of: model.activities == nil) { demo() }
        .onChange(of: search) { _, new in model.activityFilter.text = new }
        .onExitCommand(perform: resetSearch)
        .toolbar {
            ToolbarItem {
                Button {
                    showsFilters.toggle()
                } label: {
                    Label("Filter", systemImage: model.activityFilter.hasRangeFilters
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help("Filter by distance, duration and date")
                .accessibilityValue(model.activityFilter.hasRangeFilters ? Text("Filters on") : Text("No filters"))
                .popover(isPresented: $showsFilters, arrowEdge: .bottom) {
                    ActivityFilterPopover(filter: $model.activityFilter)
                }
                .disabled(model.activities?.isEmpty != false)
            }
        }
        .onChange(of: selection) { _, new in
            if new != nil { showsInspector = true }
        }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let selected {
                    ActivityDetailView(model: model, activity: selected)
                        .id(selected.id)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "figure.run",
                                           description: Text("Select an activity to see its route."))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 520)
            .toolbar {
                ToolbarItem {
                    Button("Details", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                        .help("Show or hide the activity's details")
                }
            }
        }
    }

    /// The totals of what is shown, in a plain bar under the table (not glass over content).
    private var summaryBar: some View {
        VStack(spacing: 0) {
            Divider()
            Text(ActivityTotals(rows).summary(of: all.count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
        }
        .background(.background)
        .accessibilityElement(children: .combine)
    }

    /// Development: `-OEDemo filters` opens the filter popover with filters set,
    /// `-OEDemo inspector` selects an activity with a route (for screenshots).
    private func demo() {
        guard !all.isEmpty else { return }
        // `-OESelectActivity newest`: the newest activity, with the inspector open.
        if UserDefaults.standard.string(forKey: "OESelectActivity") == "newest", selection == nil {
            selection = all.max { $0.start < $1.start }?.id
            showsInspector = true
        }
        guard let demo = UserDefaults.standard.string(forKey: "OEDemo") else { return }
        switch demo {
        case "filters":
            model.activityFilter.sports = ["Running", "Cycling"]
            model.activityFilter.distancePreset = .from5to10
            selection = nil
            showsInspector = false
            showsFilters = true
        case "sports":
            model.activityFilter.sports = ["Running", "Cycling"]
        case "inspector":
            selection = all.first { $0.sport == "Cycling" }?.id
        default:
            break
        }
    }

    /// Column widths as the table lays them out (their ideal widths, in points); Sport's
    /// follows its longest name (`sportWidth`), Date's its form.
    private static let columnWidth: [String: CGFloat] = [
        "date": 165, "distance": 88, "duration": 84, "ascent": 72, "hr": 64,
    ]
    private static let compactDateWidth: CGFloat = 118

    /// What lays the table out afresh when it changes.
    struct TableLayout: Hashable {
        var hidden: Set<String>
        var compactDate: Bool
        var sportWidth: CGFloat
    }

    /// Wide enough for the icon and the longest sport name in the list, within reason.
    private var sportWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let longest = Set(all.map(\.sportName)).map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 60
        // Icon (20) and its gap (8), the cell's insets; at least the header, at most 200.
        return min(200, max(80, (longest + 20 + 8 + 12).rounded(.up)))
    }

    /// Makes the columns fit the width: first Avg HR and Ascent go, then Date takes its
    /// compact form, then Duration and Distance go. Sport and Date always stay.
    private func fitColumns(to width: CGFloat) {
        // Cell spacing per column; the row insets and the vertical scroller.
        let spacing: CGFloat = 17, margins: CGFloat = 44
        var visible = ["date", "distance", "duration", "ascent", "hr"]
        var compact = false
        func needed() -> CGFloat {
            visible.reduce(margins + sportWidth + spacing) { total, id in
                total + spacing + (id == "date" && compact ? Self.compactDateWidth : Self.columnWidth[id] ?? 60)
            }
        }
        let steps: [() -> Void] = [
            { visible.removeAll { $0 == "hr" } },
            { visible.removeAll { $0 == "ascent" } },
            { compact = true },
            { visible.removeAll { $0 == "duration" } },
            { visible.removeAll { $0 == "distance" } },
        ]
        for step in steps where needed() > width { step() }
        let hidden = Set(["hr", "ascent", "duration", "distance"].filter { !visible.contains($0) })
        guard hidden != hiddenColumns || compact != compactDate else { return }
        for id in ["hr", "ascent", "duration", "distance"] {
            columns[visibility: id] = hidden.contains(id) ? .hidden : .automatic
        }
        hiddenColumns = hidden
        compactDate = compact
    }

    /// The date of a row: full, or compact (the year only when it is not this year).
    private func dateText(_ date: Date) -> String {
        guard compactDate else { return date.formatted(date: .abbreviated, time: .shortened) }
        let thisYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return thisYear
            ? date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            : date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    private func resetSearch() {
        search = ""
    }

    private func resetAll() {
        resetSearch()
        model.activityFilter.resetAll()
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $model.activitySort, columnCustomization: $columns) {
            // The sport first, then when: the engine's `name` repeats the date and the file,
            // so it stays in the inspector.
            TableColumn("Sport", value: \.sportName) { a in
                SportLabel(activity: a)
            }
            .width(min: 80, ideal: sportWidth, max: 260)
            .customizationID("sport")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Date", value: \.start) { a in
                Text(dateText(a.start))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: compactDate ? 100 : 150, ideal: compactDate ? Self.compactDateWidth : 165)
            .customizationID("date")
            TableColumn("Distance", value: \.distance.sortKey) { a in
                NumberCell(text: a.distance.map(Format.distance))
            }
            .width(min: 80, ideal: 88)
            .alignment(.trailing)
            .customizationID("distance")
            TableColumn("Duration", value: \.duration.sortKey) { a in
                NumberCell(text: a.duration.map(Format.duration))
            }
            .width(min: 76, ideal: 84)
            .alignment(.trailing)
            .customizationID("duration")
            TableColumn("Ascent", value: \.ascent.sortKey) { a in
                NumberCell(text: a.ascent.map(Format.elevation))
            }
            .width(min: 64, ideal: 72)
            .alignment(.trailing)
            .customizationID("ascent")
            TableColumn("Avg HR", value: \.averageHeartRate.sortKey) { a in
                NumberCell(text: a.averageHeartRate.map(Format.heartRate))
            }
            .width(min: 56, ideal: 64)
            .alignment(.trailing)
            .customizationID("hr")
        }
        .accessibilityLabel("Activities")
    }
}

private extension Optional where Wrapped == Double {
    /// Unknown values sort before every known one (after them, descending).
    var sortKey: Double { self ?? -.infinity }
}

/// The sport's icon, all in one column width so the names line up, and its name.
struct SportLabel: View {
    let activity: Activity

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: activity.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(activity.sportName)
                .lineLimit(1)
        }
    }
}

/// A number in a table: monospaced digits; an unknown value as "—" in the secondary colour.
struct NumberCell: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text).monospacedDigit()
        } else {
            Text(verbatim: "—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Unknown")
        }
    }
}

/// An activity: a header, its route on a map and its charts when the engine can read its
/// FIT file.
struct ActivityDetailView: View {
    @Environment(AppModel.self) private var app
    @State private var stravaSent = false
    let model: DeviceModel
    let activity: Activity
    @State private var track: ActivityTrack?
    @State private var loaded = false

    /// The map and its placeholders share one height: nothing jumps when the route arrives.
    private let mapHeight: CGFloat = 220

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: activity.systemImage)
                        .font(.title)
                        .foregroundStyle(.tint)
                        .frame(width: 40, height: 40)
                        .background(.tint.quaternary, in: .rect(cornerRadius: 9))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        // A title of its own when the activity has one, else the sport.
                        Text(activity.title ?? activity.sportName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Text(activity.title == nil
                             ? activity.start.formatted(date: .complete, time: .shortened)
                             : "\(activity.sportName) · \(activity.start.formatted(date: .long, time: .shortened))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section {
                Group {
                    if let track, !track.points.isEmpty {
                        RouteMap(track: track)
                    } else if loaded {
                        ContentUnavailableView {
                            Label("No Route Recorded", systemImage: "location.slash")
                        } description: {
                            Text(activity.fitPath == nil
                                 ? "This activity has no FIT file to read."
                                 : "This activity has no GPS points, as with an indoor activity.")
                        }
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Loading route…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: mapHeight)
                .listRowInsets(EdgeInsets())
            }

            Section("Summary") {
                if let d = activity.distance { LabeledContent("Distance", value: Format.distance(d)) }
                if let t = activity.duration { LabeledContent("Duration", value: Format.duration(t)) }
                if let a = activity.ascent { LabeledContent("Ascent", value: Format.elevation(a)) }
                if let hr = activity.averageHeartRate {
                    LabeledContent("Average heart rate", value: String(localized: "\(Format.heartRate(hr)) bpm"))
                }
                if let c = activity.calories {
                    LabeledContent("Calories", value: String(localized: "\(c.formatted(.number.precision(.fractionLength(0)))) kcal"))
                }
            }
            .monospacedDigit()

            if let track, track.points.contains(where: { $0.elevation != nil }) {
                Section("Elevation") {
                    Chart(track.points.indices.filter { track.points[$0].elevation != nil }, id: \.self) { i in
                        let p = track.points[i]
                        let x = (p.time ?? Double(i)) / 60
                        let y = Format.elevationValue(p.elevation ?? 0)
                        AreaMark(x: .value("Time", x), y: .value("Elevation", y))
                            .foregroundStyle(.green.gradient.opacity(0.35))
                        LineMark(x: .value("Time", x), y: .value("Elevation", y))
                            .foregroundStyle(.green)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxisLabel(String(localized: "Time (min)"), alignment: .trailing)
                    .chartYAxisLabel(Format.elevationUnit.symbol)
                    .frame(height: 130)
                    .padding(.vertical, 4)
                    .accessibilityLabel("Elevation profile")
                }
            }

            if let track, track.points.contains(where: { $0.heartRate != nil }) {
                Section("Heart Rate") {
                    Chart(track.points.indices.filter { track.points[$0].heartRate != nil }, id: \.self) { i in
                        let p = track.points[i]
                        LineMark(x: .value("Time", (p.time ?? Double(i)) / 60),
                                 y: .value("Heart rate", p.heartRate ?? 0))
                            .foregroundStyle(.red)
                            .interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXAxisLabel(String(localized: "Time (min)"), alignment: .trailing)
                    .chartYAxisLabel("bpm")
                    .frame(height: 130)
                    .padding(.vertical, 4)
                    .accessibilityLabel("Heart rate")
                }
            }

            if let path = activity.fitPath, let file = activity.fileName {
                Section {
                    // Quiet: the file it was read from, and where to find a backup's copy.
                    LabeledContent("File") {
                        HStack(spacing: 6) {
                            Text(file)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            if activity.isOnThisMac, FileManager.default.fileExists(atPath: path) {
                                Button("Show in Finder", systemImage: "magnifyingglass.circle") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Show the FIT file in Finder")
                            }
                        }
                    }
                    if activity.isOnThisMac, app.strava?.connected == true, app.supports("strava.upload") {
                        Button(stravaSent ? "Sent to Strava" : "Send to Strava") {
                            Task {
                                stravaSent = (try? await app.engine.stravaUpload(files: [path]))?["failed"]?.intValue == 0
                            }
                        }
                        .disabled(stravaSent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            track = await model.track(for: activity)
            loaded = true
        }
    }
}

struct RouteMap: View {
    let track: ActivityTrack
    @Environment(\.colorSchemeContrast) private var contrast

    private var coordinates: [CLLocationCoordinate2D] {
        track.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Start and finish within 50 m of each other: one start/finish marker.
    private var isLoop: Bool {
        guard let a = coordinates.first, let b = coordinates.last, coordinates.count > 1 else { return true }
        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) < 50
    }

    /// The route with room around it: more at the bottom, where the attribution is, so the
    /// markers and the route never touch it.
    private var camera: MapCameraPosition {
        guard !coordinates.isEmpty else { return .automatic }
        let points = coordinates.map(MKMapPoint.init)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let w = max(maxX - minX, 200), h = max(maxY - minY, 200)
        // Map y grows southwards: the bottom gets the larger margin.
        let rect = MKMapRect(x: minX - w * 0.15, y: minY - h * 0.18, width: w * 1.3, height: h * 1.48)
        return .rect(rect)
    }

    var body: some View {
        Map(initialPosition: camera, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: coordinates)
                .stroke(.orange, style: StrokeStyle(lineWidth: contrast == .increased ? 6 : 4,
                                                    lineCap: .round, lineJoin: .round))
            if let first = coordinates.first {
                if isLoop {
                    // Markers without text over the map; VoiceOver still reads their titles.
                    Marker("Start and finish", systemImage: "flag.checkered", coordinate: first)
                        .tint(.green)
                        .annotationTitles(.hidden)
                } else {
                    Marker("Start", systemImage: "flag.fill", coordinate: first)
                        .tint(.green)
                        .annotationTitles(.hidden)
                    if let last = coordinates.last {
                        Marker("Finish", systemImage: "flag.checkered", coordinate: last)
                            .tint(.red)
                            .annotationTitles(.hidden)
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapZoomStepper(); MapCompass() }
        .accessibilityLabel(isLoop ? "Route map, a loop" : "Route map")
    }
}

/// Distance, duration and date ranges, in a popover from the toolbar's Filter button.
struct ActivityFilterPopover: View {
    @Binding var filter: ActivityFilter

    /// Kilometres or miles, as the user's region measures roads.
    private var unit: UnitLength { Locale.current.measurementSystem == .metric ? .kilometers : .miles }

    var body: some View {
        Form {
            Section("Distance") {
                Picker("Distance", selection: $filter.distancePreset) {
                    ForEach(ActivityFilter.DistancePreset.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                if filter.distancePreset == .custom {
                    RangeFields(range: $filter.customDistance, unitSymbol: unit.symbol,
                                toStored: { Measurement(value: $0, unit: unit).converted(to: .meters).value },
                                fromStored: { Measurement(value: $0, unit: UnitLength.meters).converted(to: unit).value })
                }
            }
            Section("Duration") {
                Picker("Duration", selection: $filter.durationPreset) {
                    ForEach(ActivityFilter.DurationPreset.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                if filter.durationPreset == .custom {
                    RangeFields(range: $filter.customDuration, unitSymbol: String(localized: "min"),
                                toStored: { $0 * 60 }, fromStored: { $0 / 60 })
                }
            }
            Section("Date") {
                Picker("Date", selection: $filter.datePreset) {
                    ForEach(ActivityFilter.DatePreset.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            Section {
                Button("Reset Filters") { filter.resetRanges() }
                    .disabled(!filter.hasRangeFilters)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Min and max of a custom range, in the unit shown; empty is open.
struct RangeFields: View {
    @Binding var range: ActivityFilter.ValueRange
    let unitSymbol: String
    let toStored: (Double) -> Double
    let fromStored: (Double) -> Double

    var body: some View {
        HStack {
            TextField("Min", value: bound(\.min), format: .number.precision(.fractionLength(0...1)), prompt: Text("Min"))
                .accessibilityLabel("Minimum, \(unitSymbol)")
            Text("–").accessibilityHidden(true)
            TextField("Max", value: bound(\.max), format: .number.precision(.fractionLength(0...1)), prompt: Text("Max"))
                .accessibilityLabel("Maximum, \(unitSymbol)")
            Text(unitSymbol).foregroundStyle(.secondary)
        }
        .labelsHidden()
    }

    private func bound(_ key: WritableKeyPath<ActivityFilter.ValueRange, Double?>) -> Binding<Double?> {
        Binding(get: { range[keyPath: key].map(fromStored) },
                set: { range[keyPath: key] = $0.map(toStored) })
    }
}

/// The sport scope bar (as in Finder's and Mail's search): All, then each sport of the list
/// with its count under the other filters, most first. A click selects only that sport,
/// ⌘-click adds or removes it, All clears.
struct SportScopeBar: View {
    @Binding var filter: ActivityFilter
    let activities: [Activity]

    @State private var fade = EdgeFade(leading: false, trailing: false)

    struct EdgeFade: Equatable {
        var leading: Bool
        var trailing: Bool
    }

    private var counts: [(sport: String, count: Int)] { filter.sportCounts(in: activities) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    let all = counts.reduce(0) { $0 + $1.count }
                    ScopeButton(selected: filter.sports.isEmpty) {
                        filter.select(sport: nil, extending: false)
                    } label: {
                        ScopeLabel(systemImage: "square.grid.2x2", title: String(localized: "All"), count: all)
                    }
                    .accessibilityLabel("All sports, \(all) activities")
                    ForEach(counts, id: \.sport) { item in
                        let selected = filter.sports.contains(item.sport)
                        ScopeButton(selected: selected) {
                            filter.select(sport: item.sport, extending: NSEvent.modifierFlags.contains(.command))
                        } label: {
                            ScopeLabel(systemImage: symbol(item.sport), title: item.sport, count: item.count)
                        }
                        .opacity(item.count == 0 && !selected ? 0.45 : 1)
                        .help("Click to show only \(item.sport); ⌘-click to add or remove it")
                        .accessibilityLabel("\(item.sport), \(item.count) activities")
                    }
                }
                .controlSize(.regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .scrollIndicators(.never)
            // A soft fade at an edge with more sports beyond it.
            .onScrollGeometryChange(for: EdgeFade.self) { g in
                EdgeFade(leading: g.contentOffset.x > 1,
                         trailing: g.contentOffset.x + g.containerSize.width < g.contentSize.width - 1)
            } action: { _, new in fade = new }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(fade.leading ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 28)
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(fade.trailing ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 28)
                }
            }
            Divider()
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sports")
    }

    private func symbol(_ sport: String) -> String {
        activities.first { $0.sport == sport }?.systemImage ?? Activity.systemImage(sportID: nil, sport: sport)
    }
}

struct ScopeLabel: View {
    let systemImage: String
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .frame(minWidth: 16)
            Text(title)
            Text(count, format: .number)
                .opacity(0.7)
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A scope button: the selected one filled with the accent colour (and marked selected for
/// VoiceOver), the others bordered. In a window in the background the fill turns grey, so the
/// selected label also keeps the accent colour and a heavier weight there.
struct ScopeButton<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        if selected {
            Button(action: action) {
                label()
                    .fontWeight(.semibold)
                    .foregroundStyle(appearsActive ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityAddTraits(.isSelected)
        } else {
            Button(action: action, label: label)
                .buttonStyle(.bordered)
        }
    }
}
