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
    /// Measured from the list when it changes (see `ColumnWidths`).
    @State private var widths = ColumnWidths()
    /// The table's width as last measured. Not state: a resize changes the view only when
    /// `fitColumns` picks other columns, not on every frame.
    @State private var tableWidth = MeasuredWidth()

    private var all: [Activity] { model.activities ?? [] }

    private var selected: Activity? { model.activities?.first { $0.id == selection } }

    var body: some View {
        Group {
            if model.activities == nil {
                PageLoadingView(model: model, page: .activities)
            } else if all.isEmpty {
                ContentUnavailableView("No Activities", systemImage: "figure.run",
                                       description: Text("Activities recorded on the device appear here."))
            } else {
                let rows = model.activityFilter.apply(all).sorted(using: model.activitySort)
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
                        table(rows)
                            // Only the columns that fit: no clipped number, no sideways scroller.
                            // A new set of columns lays the table out afresh at their widths.
                            .id(TableLayout(hidden: hiddenColumns, compactDate: compactDate, widths: widths))
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                                tableWidth.value = width
                                fitColumns(to: width)
                            }
                    }
                }
                // The sport is the main filter: a scope bar on top, the totals below.
                .safeAreaInset(edge: .top, spacing: 0) {
                    // Filtering lives in one place: the sports, and the Filter button pinned
                    // at the end of the same bar (never lost in a toolbar overflow).
                    SportScopeBar(filter: $model.activityFilter, activities: all) {
                        filterButton
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { summaryBar(rows) }
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
        .onChange(of: model.activities, initial: true) { widths = ColumnWidths(all) }
        .onChange(of: widths) { if tableWidth.value > 0 { fitColumns(to: tableWidth.value) } }
        .onChange(of: search) { _, new in model.activityFilter.text = new }
        .onExitCommand(perform: resetSearch)
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

    /// Distance, duration and date ranges in a popover; filled while any is set.
    private var filterButton: some View {
        Button {
            showsFilters.toggle()
        } label: {
            Label("Filter", systemImage: model.activityFilter.hasRangeFilters
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(model.activityFilter.hasRangeFilters ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help("Filter by distance, duration and date")
        .accessibilityLabel("Filter")
        .accessibilityValue(model.activityFilter.hasRangeFilters ? Text("Filters on") : Text("No filters"))
        .popover(isPresented: $showsFilters, arrowEdge: .bottom) {
            ActivityFilterPopover(filter: $model.activityFilter)
        }
    }

    /// The totals of what is shown, in a plain bar under the table (not glass over content).
    private func summaryBar(_ rows: [Activity]) -> some View {
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

    /// A width kept across renders without being observed.
    final class MeasuredWidth {
        var value: CGFloat = 0
    }

    /// What lays the table out afresh when it changes.
    struct TableLayout: Hashable {
        var hidden: Set<String>
        var compactDate: Bool
        var widths: ColumnWidths
    }

    /// Each column as wide as its widest value or its header, measured once per list.
    struct ColumnWidths: Hashable {
        var sport: CGFloat = 110
        var date: CGFloat = 150
        var compactDate: CGFloat = 100
        var distance: CGFloat = 80
        var duration: CGFloat = 76
        var ascent: CGFloat = 64
        var hr: CGFloat = 56

        init() {}

        init(_ activities: [Activity]) {
            let body = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let header = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            func widest(_ texts: some Sequence<String>) -> CGFloat {
                texts.map { ($0 as NSString).size(withAttributes: [.font: body]).width }.max() ?? 0
            }
            func head(_ title: String) -> CGFloat {
                // The header's title, and some room for its sort arrow.
                (title as NSString).size(withAttributes: [.font: header]).width + 10
            }
            /// The cell's insets on both sides.
            let inset: CGFloat = 8
            func column(_ title: LocalizedStringResource, _ values: some Sequence<String>) -> CGFloat {
                (max(head(String(localized: title)), widest(values)) + inset).rounded(.up)
            }
            // Icon (20) and its gap (8).
            sport = min(200, (max(head(String(localized: "Sport")), widest(Set(activities.map(\.sport))) + 28) + inset).rounded(.up))
            date = min(220, column("Date", Set(activities.map { ActivitiesPage.formatDate($0.start, compact: false) })))
            compactDate = min(160, column("Date", Set(activities.map { ActivitiesPage.formatDate($0.start, compact: true) })))
            distance = column("Distance", activities.compactMap(\.distance).map(Format.distance))
            duration = column("Duration", activities.compactMap(\.duration).map(Format.duration))
            ascent = column("Ascent", activities.compactMap(\.ascent).map(Format.elevation))
            hr = column("Avg HR", activities.compactMap(\.averageHeartRate).map(Format.heartRate))
        }

        func width(_ id: String, compactDate compact: Bool) -> CGFloat {
            switch id {
            case "sport": sport
            case "date": compact ? compactDate : date
            case "distance": distance
            case "duration": duration
            case "ascent": ascent
            default: hr
            }
        }
    }

    private static let debugLayout = ProcessInfo.processInfo.environment["OEDEBUG_LAYOUT"] != nil

    /// Makes the columns fit the width: first Avg HR and Ascent go, then Date takes its
    /// compact form, then Duration and Distance go. Sport and Date always stay.
    private func fitColumns(to width: CGFloat) {
        // The table's spacing between columns (17), its row insets; the scroller overlays.
        let spacing: CGFloat = 17, margins: CGFloat = 20
        var visible = ["sport", "date", "distance", "duration", "ascent", "hr"]
        var compact = false
        func needed() -> CGFloat {
            visible.reduce(margins) { $0 + widths.width($1, compactDate: compact) + spacing }
        }
        let steps: [() -> Void] = [
            { visible.removeAll { $0 == "hr" } },
            { visible.removeAll { $0 == "ascent" } },
            { compact = true },
            { visible.removeAll { $0 == "duration" } },
            { visible.removeAll { $0 == "distance" } },
        ]
        for step in steps where needed() > width { step() }
        // Development: `OEDEBUG_LAYOUT=1` logs the measured widths and what was chosen.
        if Self.debugLayout {
            NSLog("openExpress layout: table %.0f, needed %.0f; widths %@; compact date %d; columns %@",
                  width, needed(), String(describing: widths), compact ? 1 : 0, visible.joined(separator: " · "))
        }
        let hidden = Set(["hr", "ascent", "duration", "distance"].filter { !visible.contains($0) })
        guard hidden != hiddenColumns || compact != compactDate else { return }
        for id in ["hr", "ascent", "duration", "distance"] {
            columns[visibility: id] = hidden.contains(id) ? .hidden : .automatic
        }
        hiddenColumns = hidden
        compactDate = compact
    }

    /// The date of a row: full, or compact (the year only when it is not this year).
    private func dateText(_ date: Date) -> String { Self.formatDate(date, compact: compactDate) }

    /// Full: "13 Nov 2026 at 10:36". Compact: "13 Nov, 10:36", and "13 Nov 25, 10:36" for
    /// another year (two digits: the compact form must stay compact for older activities).
    static func formatDate(_ date: Date, compact: Bool) -> String {
        guard compact else { return date.formatted(date: .abbreviated, time: .shortened) }
        let thisYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        let day = thisYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year(.twoDigits))
        return day + ", " + date.formatted(date: .omitted, time: .shortened)
    }

    private func resetSearch() {
        search = ""
    }

    private func resetAll() {
        resetSearch()
        model.activityFilter.resetAll()
    }

    private func table(_ rows: [Activity]) -> some View {
        Table(rows, selection: $selection, sortOrder: $model.activitySort, columnCustomization: $columns) {
            // The sport first, then when: the engine's `name` repeats the date and the file,
            // so it stays in the inspector.
            TableColumn("Sport", value: \.sport) { a in
                SportLabel(activity: a)
            }
            .width(min: 80, ideal: widths.sport, max: 260)
            .customizationID("sport")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Date", value: \.start) { a in
                Text(dateText(a.start))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 70, ideal: widths.width("date", compactDate: compactDate))
            .customizationID("date")
            TableColumn("Distance", value: \.distance.sortKey) { a in
                NumberCell(text: a.distance.map(Format.distance))
            }
            .width(min: 50, ideal: widths.distance)
            .alignment(.trailing)
            .customizationID("distance")
            TableColumn("Duration", value: \.duration.sortKey) { a in
                NumberCell(text: a.duration.map(Format.duration))
            }
            .width(min: 50, ideal: widths.duration)
            .alignment(.trailing)
            .customizationID("duration")
            TableColumn("Ascent", value: \.ascent.sortKey) { a in
                NumberCell(text: a.ascent.map(Format.elevation))
            }
            .width(min: 44, ideal: widths.ascent)
            .alignment(.trailing)
            .customizationID("ascent")
            TableColumn("Avg HR", value: \.averageHeartRate.sortKey) { a in
                NumberCell(text: a.averageHeartRate.map(Format.heartRate))
            }
            .width(min: 44, ideal: widths.hr)
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
            Text(activity.sport)
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
                        Text(activity.title ?? activity.sport)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Text(activity.title == nil
                             ? activity.start.formatted(date: .complete, time: .shortened)
                             : "\(activity.sport) · \(activity.start.formatted(date: .long, time: .shortened))")
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

            if let track {
                TrackChart(title: "Elevation", valueLabel: "Elevation", accessibilityTitle: "Elevation profile",
                           unit: Format.elevationUnit.symbol, color: .green, filled: true,
                           points: track.points) { $0.elevation.map(Format.elevationValue) }
                TrackChart(title: "Heart Rate", valueLabel: "Heart rate", accessibilityTitle: "Heart rate",
                           unit: "bpm", color: .red, filled: false,
                           points: track.points) { $0.heartRate }
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
                                    showInFinder(URL(fileURLWithPath: path))
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Show the FIT file in Finder")
                            }
                        }
                    }
                    if activity.isOnThisMac, app.strava?.connected == true {
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
            // A new selection makes a new view: a track read before is shown at once; else
            // the read waits for the selection to rest, so arrowing through the list reads
            // only the row it stops on (leaving a row cancels its wait or its read).
            if let cached = model.cachedTrack(for: activity) {
                track = cached
            } else {
                if activity.fitPath != nil {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                track = await model.track(for: activity)
            }
            loaded = true
        }
    }
}

/// One value of a track over its time, in a section of its own; nothing when no point has
/// it. Filled: the area under a straight line (elevation); else a smoothed line (heart rate).
struct TrackChart: View {
    let title: LocalizedStringKey
    let valueLabel: LocalizedStringKey
    let accessibilityTitle: LocalizedStringKey
    let unit: String
    let color: Color
    let filled: Bool
    let points: [ActivityTrack.Point]
    let value: (ActivityTrack.Point) -> Double?

    var body: some View {
        let indices = points.indices.filter { value(points[$0]) != nil }
        if !indices.isEmpty {
            Section(title) {
                Chart(indices, id: \.self) { i in
                    let x = (points[i].time ?? Double(i)) / 60
                    let y = value(points[i]) ?? 0
                    if filled {
                        AreaMark(x: .value("Time", x), y: .value(valueLabel, y))
                            .foregroundStyle(color.gradient.opacity(0.35))
                    }
                    LineMark(x: .value("Time", x), y: .value(valueLabel, y))
                        .foregroundStyle(color)
                        .interpolationMethod(filled ? .linear : .catmullRom)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxisLabel(String(localized: "Time (min)"), alignment: .trailing)
                .chartYAxisLabel(unit)
                .frame(height: 130)
                .padding(.vertical, 4)
                .accessibilityLabel(accessibilityTitle)
            }
        }
    }
}

struct RouteMap: View {
    private let coordinates: [CLLocationCoordinate2D]
    private let isLoop: Bool
    private let camera: MapCameraPosition
    @Environment(\.colorSchemeContrast) private var contrast
    /// Bumped when the window comes back into view: see `.id` below.
    @State private var renderPass = 0
    @State private var window: NSWindow?
    @State private var wasHidden = false
    /// The size the map has been given; the map is made once it has stopped changing.
    @State private var size: CGSize = .zero
    @State private var settled = false

    init(track: ActivityTrack) {
        let points = RouteGeometry.drawable(track.points)
        coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        isLoop = RouteGeometry.isLoop(points)
        camera = RouteGeometry.cameraRect(points).map { .rect($0) } ?? .automatic
    }

    var body: some View {
        // A map made while its frame still changes (the inspector opening beside a table
        // that lays itself out again) can stay blank: no tiles, no route. It is made once
        // its size has held for a moment.
        Group {
            if settled {
                map
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
        .task(id: size) {
            guard !settled, size.width > 50, size.height > 50 else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { settled = true }
        }
    }

    private var map: some View {
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
        // MapKit draws nothing (no tiles, no route) while its window is fully covered, and a
        // map made then can stay blank: made again once the window is in view.
        .id(renderPass)
        .background(WindowReader(window: $window))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let w = note.object as? NSWindow, w === window else { return }
            if !w.occlusionState.contains(.visible) {
                wasHidden = true
            } else if wasHidden {
                wasHidden = false
                renderPass += 1
            }
        }
        .onChange(of: window) { _, w in
            if let w, !w.occlusionState.contains(.visible) { wasHidden = true }
        }
        .accessibilityLabel(isLoop ? "Route map, a loop" : "Route map")
    }
}

/// The window a view is in.
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window !== window { DispatchQueue.main.async { window = nsView.window } }
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
struct SportScopeBar<Trailing: View>: View {
    @Binding var filter: ActivityFilter
    let activities: [Activity]
    /// Pinned at the end of the bar, outside the scrolling sports.
    @ViewBuilder let trailing: () -> Trailing

    @State private var fade = EdgeFade(leading: false, trailing: false)

    struct EdgeFade: Equatable {
        var leading: Bool
        var trailing: Bool
    }

    var body: some View {
        let counts = filter.sportCounts(in: activities)
        // The icon of each sport: that of its first activity.
        let symbols = Dictionary(activities.map { ($0.sport, $0.systemImage) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            HStack(spacing: 0) {
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
                                ScopeLabel(systemImage: symbols[item.sport] ?? Activity.systemImage(sportID: nil), title: item.sport, count: item.count)
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
                trailing()
                    .padding(.leading, 6)
                    .padding(.trailing, 12)
            }
            Divider()
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sports")
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
