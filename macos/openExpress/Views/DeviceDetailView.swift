import OpenExpressKit
import SwiftUI

/// The pages of one device, chosen in the toolbar; the floating action of the page at the bottom.
struct DeviceDetailView: View {
    @Environment(AppModel.self) private var app
    let model: DeviceModel

    var body: some View {
        @Bindable var app = app
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if model.busyBy == nil {
                    FloatingActionBar(model: model, page: app.page)
                }
            }
            .navigationTitle(model.device.name)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Page", selection: $app.page) {
                        ForEach(DevicePage.allCases) { page in
                            Text(page.title).tag(page)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Device page")
                }
                ToolbarSpacer(.flexible)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.load(app.page) }
                    }
                    .help("Read this page from the device again")
                    .disabled(model.loading.contains(app.page) || (app.page.needsConnection && !model.device.connected))
                }
            }
            .task(id: app.page) { await model.load(app.page) }
            .alert("openExpress", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    private var subtitle: String {
        if let outcome = model.lastOutcome { return outcome }
        if model.device.connected { return model.device.software.map { String(localized: "Software \($0)") } ?? "" }
        return String(localized: "Not connected")
    }

    @ViewBuilder
    private var page: some View {
        if let program = model.busyBy {
            BusyView(model: model, program: program)
        } else if app.page.needsConnection, !model.device.connected {
            ContentUnavailableView {
                Label("\(model.device.name) Is Not Connected", systemImage: "cable.connector")
            } description: {
                Text("Connect it with its USB cable to see its \(app.page.title.lowercased()).")
            }
        } else {
            switch app.page {
            case .overview: OverviewPage(model: model)
            case .activities: ActivitiesPage(model: model)
            case .updates: UpdatesPage(model: model)
            case .maps: MapsPage(model: model)
            case .apps: AppsPage(model: model)
            case .backups: BackupsPage(model: model)
            }
        }
    }
}

/// Another program (Garmin Express Service) holds the device. openExpress never quits it.
struct BusyView: View {
    let model: DeviceModel
    let program: String

    var body: some View {
        ContentUnavailableView {
            Label("\(model.device.name) Is in Use", systemImage: "lock.circle")
        } description: {
            Text("\(program) is using the device, so openExpress cannot read it.")
            Text("Quit Garmin Express: choose Quit from its menu bar icon, so that Garmin Express Service stops too. Then try again. openExpress does not quit other apps for you.")
                .font(.callout)
        } actions: {
            Button("Try Again") { Task { await model.retryAfterBusy() } }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The page's primary action as a floating glass button that morphs into the progress
/// capsule of the running operation (Install All → progress).
struct FloatingActionBar: View {
    let model: DeviceModel
    let page: DevicePage
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Action {
        var title: LocalizedStringKey
        var systemImage: String
        var perform: () -> Void
    }

    private var action: Action? {
        guard model.device.connected else { return nil }
        switch page {
        case .overview:
            return Action(title: "Sync Now", systemImage: "arrow.triangle.2.circlepath") { model.sync() }
        case .updates:
            let n = model.installAllParts.count
            guard n > 0 else { return nil }
            return Action(title: n == 1 ? "Install" : "Install All", systemImage: "arrow.down.circle") { model.install() }
        case .maps:
            let names = model.maps?.updatable.map(\.name) ?? []
            guard !names.isEmpty else { return nil }
            return Action(title: "Update All Maps", systemImage: "map") { model.maps(.update, names) }
        case .backups:
            return Action(title: "Back Up Now", systemImage: "externaldrive.badge.timemachine") { model.backUp() }
        case .activities, .apps:
            return nil
        }
    }

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            if let operation = model.operation {
                OperationCapsule(operation: operation) { model.cancelOperation() }
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("action", in: glass)
            } else if let action {
                Button(action: action.perform) {
                    Label(action.title, systemImage: action.systemImage)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .glassEffectID("action", in: glass)
            }
        }
        .padding(.bottom, 20)
        .animation(reduceMotion ? nil : .bouncy, value: model.operation?.kind)
    }
}

struct OperationCapsule: View {
    let operation: DeviceModel.Operation
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let fraction = operation.progress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.circular)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text(operation.kind.title)
                    .font(.headline)
                Text(operation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .frame(minWidth: 180, alignment: .leading)

            Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(operation.cancelling)
                .help("Stops at the next safe point; a file being written to the device is finished first.")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(operation.kind.title), \(operation.detail)"))
        .accessibilityValue(operation.progress?.fraction.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text(""))
    }
}
