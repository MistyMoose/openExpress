import OpenExpressKit
import SwiftUI

struct MenuBarLabel: View {
    let pending: Int

    var body: some View {
        if pending > 0 {
            // Icon and count: the count is the title of the menu bar item.
            Label("\(pending)", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("openExpress for Mac, \(pending) updates available")
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
                .accessibilityLabel("openExpress for Mac")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Connected Devices") {
            if app.connectedDevices.isEmpty {
                Text("No device connected")
            }
            ForEach(app.connectedDevices) { device in
                let model = app.model(for: device.unitID)
                Button {
                    open(.device(device.unitID), page: .overview)
                } label: {
                    Label(device.name + status(model), systemImage: device.kind.systemImage)
                }
            }
        }

        Button("Sync Now") {
            for d in app.connectedDevices { app.model(for: d.unitID)?.sync() }
        }
        .keyboardShortcut("r")
        .disabled(app.connectedDevices.isEmpty || app.connectedDevices.allSatisfy { app.model(for: $0.unitID)?.isBusy != false })

        if app.pendingUpdatesCount > 0, let first = app.connectedDevices.first(where: { (app.model(for: $0.unitID)?.badgeCount ?? 0) > 0 }) {
            Button("Updates Available (\(app.pendingUpdatesCount))…") {
                open(.device(first.unitID), page: .updates)
            }
        }

        Divider()
        Button("Open openExpress for Mac") { open(nil, page: nil) }
            .keyboardShortcut("o")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit openExpress for Mac") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func status(_ model: DeviceModel?) -> String {
        guard let model else { return "" }
        if model.busyBy != nil { return " — " + String(localized: "in use") }
        if let op = model.operation { return " — " + op.kind.title + "…" }
        return ""
    }

    private func open(_ item: SidebarItem?, page: DevicePage?) {
        if let item { app.selection = item }
        if let page { app.page = page }
        openWindow(id: WindowID.main)
        NSApplication.shared.activate()
    }
}
