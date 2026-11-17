import Charts
import MapKit
import OpenExpressKit
import SwiftUI

struct ActivitiesPage: View {
    let model: DeviceModel
    @State private var selection: Activity.ID?
    @State private var sortOrder = [KeyPathComparator(\Activity.start, order: .reverse)]
    @State private var search = ""
    @State private var showsInspector = false

    private var rows: [Activity] {
        let all = model.activities ?? []
        let filtered = search.isEmpty ? all : all.filter {
            $0.sportName.localizedStandardContains(search) || ($0.name ?? "").localizedStandardContains(search)
        }
        return filtered.sorted(using: sortOrder)
    }

    private var selected: Activity? { model.activities?.first { $0.id == selection } }

    var body: some View {
        Group {
            if model.activities == nil {
                PageLoadingView(model: model, page: .activities)
            } else if model.activities?.isEmpty == true {
                ContentUnavailableView("No Activities", systemImage: "figure.run",
                                       description: Text("Activities recorded on the device appear here."))
            } else {
                table
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Activities")
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
            .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            .toolbar {
                ToolbarItem {
                    Button("Details", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                        .help("Show or hide the activity's details")
                }
            }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            // The sport first, then when: the engine's `name` repeats the date and the file,
            // so it stays in the inspector.
            TableColumn("Sport", value: \.sport) { a in
                Label(a.sportName, systemImage: a.systemImage)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Date", value: \.start) { a in
                Text(a.start.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 140, ideal: 170)
            TableColumn("Distance", value: \.distance.orZero) { a in
                Text(a.distance.map(Format.distance) ?? "—").monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            .alignment(.trailing)
            TableColumn("Duration", value: \.duration.orZero) { a in
                Text(a.duration.map(Format.duration) ?? "—").monospacedDigit()
            }
            .width(min: 60, ideal: 72)
            .alignment(.trailing)
            TableColumn("Ascent", value: \.ascent.orZero) { a in
                Text(a.ascent.map { Measurement(value: $0, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .asProvided)) } ?? "—")
                    .monospacedDigit()
            }
            .width(min: 52, ideal: 64)
            .alignment(.trailing)
            TableColumn("Avg HR", value: \.averageHeartRate.orZero) { a in
                Text(a.averageHeartRate.map { "\(Int($0))" } ?? "—").monospacedDigit()
            }
            .width(60)
            .alignment(.trailing)
        }
    }
}

private extension Optional where Wrapped == Double {
    var orZero: Double { self ?? 0 }
}

/// An activity: its route on a map and its charts when the engine can read its FIT file.
struct ActivityDetailView: View {
    @Environment(AppModel.self) private var app
    @State private var stravaSent = false
    let model: DeviceModel
    let activity: Activity
    @State private var track: ActivityTrack?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                if let track, !track.points.isEmpty {
                    RouteMap(track: track)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                } else if loaded {
                    ContentUnavailableView("No Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                           description: Text(activity.fitPath == nil
                                                             ? "This activity has no FIT file on this Mac."
                                                             : "The route is shown once the engine can read it."))
                        .frame(height: 160)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            }

            Section(activity.name ?? activity.sportName) {
                LabeledContent("Start", value: activity.start.formatted(date: .complete, time: .shortened))
                if let d = activity.distance { LabeledContent("Distance", value: Format.distance(d)) }
                if let t = activity.duration { LabeledContent("Duration", value: Format.duration(t)) }
                if let a = activity.ascent {
                    LabeledContent("Ascent", value: Measurement(value: a, unit: UnitLength.meters).formatted())
                }
                if let hr = activity.averageHeartRate { LabeledContent("Average heart rate", value: "\(Int(hr)) bpm") }
                if let c = activity.calories { LabeledContent("Calories", value: "\(Int(c)) kcal") }
            }

            if let track, track.points.contains(where: { $0.elevation != nil }) {
                Section("Elevation") {
                    Chart(track.points.indices.filter { track.points[$0].elevation != nil }, id: \.self) { i in
                        let p = track.points[i]
                        AreaMark(x: .value("Time", (p.time ?? Double(i)) / 60),
                                 y: .value("Elevation", p.elevation ?? 0))
                            .foregroundStyle(.green.gradient.opacity(0.5))
                        LineMark(x: .value("Time", (p.time ?? Double(i)) / 60),
                                 y: .value("Elevation", p.elevation ?? 0))
                            .foregroundStyle(.green)
                    }
                    .chartXAxisLabel("min")
                    .chartYAxisLabel("m")
                    .frame(height: 120)
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
                    .chartXAxisLabel("min")
                    .chartYAxisLabel("bpm")
                    .frame(height: 120)
                    .accessibilityLabel("Heart rate")
                }
            }

            if let path = activity.fitPath, activity.isOnThisMac {
                Section {
                    if FileManager.default.fileExists(atPath: path) {
                        Button("Show FIT File in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    if app.strava?.connected == true, app.supports("strava.upload") {
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

    private var coordinates: [CLLocationCoordinate2D] {
        track.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: coordinates)
                .stroke(.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let first = coordinates.first {
                Marker("Start", systemImage: "flag", coordinate: first)
                    .tint(.green)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .accessibilityLabel("Route map")
    }
}
