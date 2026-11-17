import OpenExpressKit
import SwiftUI

/// The pages of one device, chosen in the toolbar; the floating action of the page at the bottom.
struct DeviceDetailView: View {
    @Environment(AppModel.self) private var app
    let model: DeviceModel

    var body: some View {
        @Bindable var app = app
        @Bindable var model = model
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // An inset, not an overlay: lists and forms scroll their last rows clear of the
            // floating action, under the scroll edge effect.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.busyBy == nil {
                    FloatingActionBar(model: model, page: app.page)
                }
            }
            // The short name: the full one is on Overview.
            .navigationTitle(model.device.shortName)
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
            // The model owns the load: leaving the page never cancels it, and a page read
            // once is shown again without reading the device (Refresh reads it again).
            .task(id: app.page) {
                await model.loadIfNeeded(app.page)
                // Development: `-OEInitialPage updates -OEShowInstallPlan YES` opens the confirmation.
                if app.page == .updates, UserDefaults.standard.bool(forKey: "OEShowInstallPlan") {
                    model.requestInstallAll()
                }
            }
            .sheet(item: $model.pendingPlan) { plan in
                InstallConfirmationSheet(plan: plan, deviceName: model.device.shortName) {
                    model.perform(plan)
                }
            }
            .confirmationDialog("First Sync of \(model.device.shortName)", isPresented: $model.needsFirstSyncChoice) {
                Button("Upload New Data Only") { model.sync(firstRun: .newOnly) }
                Button("Upload Everything on the Device") { model.sync(firstRun: .everything) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("openExpress has not synced this device before. Upload only what the device records from now on, or everything still on it (activities Garmin Connect already has are recognised).")
            }
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
            guard model.badgeCount > 0 else { return nil }
            return Action(title: model.badgeCount == 1 ? "Install…" : "Install All…", systemImage: "arrow.down.circle") {
                model.requestInstallAll()
            }
        case .maps:
            guard !model.mapUpdates.isEmpty else { return nil }
            return Action(title: "Update All Maps", systemImage: "map") { model.updateAllMaps() }
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
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
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

/// Install All (and a large map) asks first: what, how much, the space left, and that the
/// software installs only once the device is unplugged.
struct InstallConfirmationSheet: View {
    let plan: InstallPlan
    let deviceName: String
    let install: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(plan.items.count == 1 ? "Install \(plan.items[0].name)?" : "Install \(plan.items.count) Updates on \(deviceName)?",
                  systemImage: "arrow.down.circle")
                .font(.title2.weight(.semibold))

            Form {
                Section {
                    ForEach(plan.items) { item in
                        LabeledContent {
                            Text(Format.bytes(item.size)).monospacedDigit()
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                    if let change = item.change {
                                        Text(change).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            } icon: {
                                Image(systemName: item.kind == .software ? "cpu" : "map")
                            }
                        }
                    }
                }
                Section {
                    LabeledContent("Download", value: Format.bytes(plan.totalBytes))
                    if let after = plan.freeAfter {
                        LabeledContent("Free on the device afterwards") {
                            Text(after >= 0 ? Format.bytes(after) : String(localized: "\(Format.bytes(-after)) too little"))
                                .foregroundStyle(after >= 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(plan.items.count < 6)
            .frame(minHeight: 140, maxHeight: 360)

            VStack(alignment: .leading, spacing: 6) {
                Label("Keep the device connected while the files are copied.", systemImage: "cable.connector")
                if plan.hasSoftware {
                    Label("Then unplug the device: it installs the software by itself and restarts. Keep it charged.",
                          systemImage: "cable.connector.slash")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") {
                    dismiss()
                    install()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!plan.fits)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

/// A page while it is read: counted progress when the engine reports it (the first read of
/// the activities goes through every FIT file), "Waiting for the device…" while the request
/// waits behind another for the same device, else a plain spinner.
struct PageLoadingView: View {
    let model: DeviceModel
    let page: DevicePage
    var label: LocalizedStringKey? = nil

    var body: some View {
        VStack(spacing: 10) {
            if let progress = model.loadProgress[page] {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 280)
                } else {
                    ProgressView()
                }
                Text(progress.detail)
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if progress.phase == "reading_activities" {
                    Text("The first time, every activity file is read from the device; this takes a while. Later it is quick.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
            } else if model.isWaiting(page) {
                ProgressView()
                Text("Waiting for the device…")
                    .font(.headline)
                Text("The device answers one request at a time; this page is next.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                if let label { Text(label).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
