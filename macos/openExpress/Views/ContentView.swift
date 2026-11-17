import OpenExpressKit
import SwiftUI

/// The main window: devices and Account in the sidebar, the selected one's pages in the detail.
struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var windowWidth: CGFloat = 0

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { windowWidth = $0 }
        .environment(\.windowWidth, windowWidth)
        .sheet(isPresented: $app.isShowingSetup) { SetupSheet() }
        .sheet(isPresented: $app.isShowingSignIn) { SignInSheet() }
        .alert("openExpress", isPresented: Binding(
            get: { app.alertMessage != nil },
            set: { if !$0 { app.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.engineState {
        case .starting:
            ProgressView("Starting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why):
            ContentUnavailableView {
                Label("The Engine Is Not Running", systemImage: "exclamationmark.triangle")
            } description: {
                Text(why)
            } actions: {
                Button("Try Again") { Task { await app.retry() } }
                SettingsLink { Text("Settings…") }
            }
        case .ready:
            switch app.selection {
            case .device(let id):
                if let model = app.model(for: id) {
                    DeviceDetailView(model: model)
                        .id(id)
                } else {
                    noSelection
                }
            case .account:
                AccountView()
            case nil:
                noSelection
            }
        }
    }

    @ViewBuilder
    private var noSelection: some View {
        if let busy = app.unassignedBusy {
            ContentUnavailableView {
                Label("\(busy.name ?? String(localized: "A Garmin device")) Is in Use", systemImage: "lock.circle")
            } description: {
                Text("\(busy.program) is using the device. Quit Garmin Express: choose Quit from its menu bar icon, so that Garmin Express Service stops too. The device appears here once it is free.")
            }
        } else {
            ContentUnavailableView {
                Label("Connect a Device", systemImage: "cable.connector")
            } description: {
                Text("Connect your Garmin watch or bike computer with its USB cable.")
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            if !app.connectedDevices.isEmpty {
                Section("Connected") {
                    ForEach(app.connectedDevices) { device in
                        DeviceRow(device: device, model: app.model(for: device.unitID))
                            .tag(SidebarItem.device(device.unitID))
                    }
                }
            }
            if !app.rememberedDevices.isEmpty {
                Section("Other Devices") {
                    ForEach(app.rememberedDevices) { device in
                        DeviceRow(device: device, model: app.model(for: device.unitID))
                            .tag(SidebarItem.device(device.unitID))
                    }
                }
            }
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Account")
                        Text(accountSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.crop.circle")
                }
                .tag(SidebarItem.account)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if app.engineState == .ready, app.devices.isEmpty {
                ContentUnavailableView("No Devices", systemImage: "applewatch.slash",
                                       description: Text("Connect a device to see it here."))
            }
        }
    }

    private var accountSubtitle: String {
        guard let account = app.account else { return "" }
        if !account.setupDone { return String(localized: "Setup needed") }
        return account.signedIn ? (account.account ?? String(localized: "Signed in")) : String(localized: "Not signed in")
    }
}

struct DeviceRow: View {
    let device: Device
    let model: DeviceModel?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .lineLimit(1)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: device.kind.systemImage)
                .foregroundStyle(device.connected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .badge(model?.badgeCount ?? 0)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(status))
    }

    private var statusIsWarning: Bool { (model?.busyBy ?? device.busyBy) != nil }

    private var status: String {
        if let busy = model?.busyBy ?? device.busyBy {
            return String(localized: "In use by \(busy)")
        }
        if let op = model?.operation {
            return op.kind.title + "…"
        }
        if model?.waitingUpdates.isEmpty == false {
            return String(localized: "Unplug to install")
        }
        if device.connected {
            if let count = model?.badgeCount, count > 0 { return String(localized: "Update available") }
            return String(localized: "Connected")
        }
        if let last = device.lastSync {
            return String(localized: "Synced \(Format.relative(last))")
        }
        return String(localized: "Not connected")
    }
}

extension EnvironmentValues {
    /// The main window's width, for layouts that change with it (the toolbar's page picker).
    @Entry var windowWidth: CGFloat = 0
}
