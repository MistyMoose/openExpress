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

            if let readings = model.readings, !readings.isEmpty {
                AccountReadingsSection(readings: readings)
            }
        }
        .formStyle(.grouped)
    }
}

/// What the Garmin Connect account says beside the device (`account.readings`): the sensors
/// on the account and their batteries, low ones first, and the activity time the sun gained a
/// device that charges from it. The engine words the readings; a battery that is low or
/// critical is also said in words, not only in colour.
struct AccountReadingsSection: View {
    @Environment(AppModel.self) private var app
    let readings: AccountReadings

    var body: some View {
        Section {
            if let sensors = readings.sensors {
                sensorsRow(sensors)
            }
            if let solar = readings.solar {
                LabeledContent("Solar Charging") {
                    value(solar.state, summary: solar.summary, message: solar.message)
                }
            }
        } header: {
            Text("Garmin Connect")
        } footer: {
            if readings.sensors?.state == .read {
                Text("The sensors are your account's: Garmin Connect does not say which device each one is paired with.")
            }
        }
    }

    @ViewBuilder
    private func sensorsRow(_ sensors: AccountReadings.Sensors) -> some View {
        if sensors.state == .read, let list = sensors.sensors, !list.isEmpty {
            // Closed, also with a low battery: the summary says so.
            DisclosureGroup {
                ForEach(Array(list.enumerated()), id: \.offset) { _, sensor in
                    LabeledContent(sensor.name) {
                        Text(sensor.detail)
                            .foregroundStyle(sensor.low ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
            } label: {
                LabeledContent("Account Sensors", value: sensors.summary ?? "")
            }
        } else {
            LabeledContent("Account Sensors") {
                value(sensors.state, summary: sensors.summary, message: sensors.message)
            }
        }
    }

    @ViewBuilder
    private func value(_ state: AccountReadings.State, summary: String?, message: String?) -> some View {
        switch state {
        case .read:
            Text(summary ?? "")
                .multilineTextAlignment(.trailing)
        case .signedOut:
            Button("Sign In to See") { app.isShowingSignIn = true }
                .buttonStyle(.link)
        case .failed:
            Text("Could not check")
                .foregroundStyle(.secondary)
                .help(message ?? "")
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
