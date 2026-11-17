import OpenExpressKit
import SwiftUI

struct OverviewPage: View {
    @Environment(AppModel.self) private var app
    let model: DeviceModel

    private var device: Device { model.device }

    var body: some View {
        @Bindable var settings = app.settings
        VStack(spacing: 0) {
            DeviceHero(device: device)
            form(settings: $settings)
        }
    }

    private func form(settings: Bindable<AppSettings>) -> some View {
        Form {
            Section("Device") {
                LabeledContent("Software") {
                    HStack(spacing: 6) {
                        Text(device.software ?? "—")
                        if !model.pendingUpdates.isEmpty {
                            Button("Update Available") { app.page = .updates }
                                .buttonStyle(.link)
                        } else if !model.waitingUpdates.isEmpty {
                            Text("Unplug to install").foregroundStyle(.orange)
                        }
                    }
                }
                if let part = device.partNumber {
                    LabeledContent("Part number", value: part)
                }
                if let battery = device.battery {
                    LabeledContent("Battery") {
                        Label("\(battery)%", systemImage: batterySymbol(battery))
                            .labelStyle(.titleAndIcon)
                    }
                }
                LabeledContent("Connection", value: device.connected
                               ? String(localized: "Connected over USB")
                               : String(localized: "Not connected"))
            }

            if let storage = device.storage {
                Section("Storage") {
                    LabeledContent("Free", value: String(localized: "\(Format.bytes(storage.free)) of \(Format.bytes(storage.capacity))"))
                    Gauge(value: storage.usedFraction) {
                        EmptyView()
                    }
                    .gaugeStyle(.linearCapacity)
                    .accessibilityLabel("Storage used")
                    .tint(storage.usedFraction > 0.9 ? .orange : .accentColor)
                    .accessibilityValue(Text("\(Format.bytes(storage.free)) free"))
                }
            }

            Section("Sync and Backup") {
                LabeledContent("Last sync", value: device.lastSync.map { Format.relative($0) } ?? String(localized: "Never"))
                LabeledContent("Last backup", value: device.lastBackup.map { Format.relative($0) } ?? String(localized: "Never"))
                Toggle("Back up and sync when connected", isOn: settings.automaticBackupAndSync)
                if let outcome = model.lastOutcome {
                    Text(outcome)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// The device's picture. There are no Garmin product images in the app, so a large symbol
/// of its kind stands in on a tinted field; the field extends under the sidebar.
struct DeviceHero: View {
    let device: Device
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor.opacity(contrast == .increased ? 0.35 : 0.18).gradient)
                .backgroundExtensionEffect()
            VStack(spacing: 10) {
                Image(systemName: device.kind.systemImage)
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(spacing: 2) {
                    Text(device.name)
                        .font(.title2.weight(.semibold))
                    if let software = device.software {
                        Text("Software \(software)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .accessibilityElement(children: .combine)
    }
}
