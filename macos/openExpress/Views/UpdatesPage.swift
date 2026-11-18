import OpenExpressKit
import SwiftUI

/// Software and map updates in one list. Never installs by itself.
struct UpdatesPage: View {
    @Environment(AppModel.self) private var app
    let model: DeviceModel

    private var mapUpdates: [DeviceMap] { model.mapUpdates }

    var body: some View {
        Group {
            if model.updatesChecked == nil, model.loading.contains(.updates) {
                PageLoadingView(model: model, page: .updates, label: "Checking for updates…")
            } else if model.updates.isEmpty, mapUpdates.isEmpty {
                ContentUnavailableView {
                    Label("Up to Date", systemImage: "checkmark.seal")
                } description: {
                    if let checked = model.updatesChecked {
                        Text("Checked \(Format.relative(checked)).")
                    }
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if !model.waitingUpdates.isEmpty {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Unplug \(model.device.name) to install")
                                .font(.headline)
                            Text("The update is copied. The device installs it after you disconnect the USB cable; keep it charged until it restarts.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "cable.connector.slash")
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !model.updates.isEmpty {
                Section("Software") {
                    ForEach(model.updates) { update in
                        UpdateRow(
                            systemImage: "cpu",
                            title: update.name,
                            detail: [update.installed.map { "\($0) → \(update.version)" } ?? update.version,
                                     Format.bytes(update.size)].joined(separator: " · "),
                            beta: update.beta,
                            waiting: update.waitingOnDevice,
                            disabled: model.isBusy
                        ) { model.install(update) }
                    }
                }
            }

            if !mapUpdates.isEmpty {
                Section {
                    ForEach(mapUpdates) { map in
                        UpdateRow(
                            systemImage: "map",
                            title: map.name,
                            detail: [map.versionChange, Format.bytes(map.size)].compactMap { $0 }.joined(separator: " · "),
                            beta: false,
                            waiting: false,
                            disabled: model.isBusy,
                            install: nil)
                    }
                } header: {
                    Text("Maps")
                } footer: {
                    Text("Maps are updated together, with Install All or Update All Maps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.betaOffered {
                Section {
                    Text("Beta versions are installed only when you choose them one by one; Install All leaves them out.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct UpdateRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let beta: Bool
    let waiting: Bool
    let disabled: Bool
    /// nil: no button of its own (map updates go together).
    let install: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if beta { BetaBadge() }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if waiting {
                Label("Unplug to install", systemImage: "cable.connector.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if let install {
                Button("Install", action: install)
                    .buttonStyle(.glass)
                    .disabled(disabled)
                    .accessibilityLabel("Install \(title)")
            }
        }
        .padding(.vertical, 4)
    }
}

struct BetaBadge: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text("Beta")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
            .background(.orange.opacity(contrast == .increased ? 0.35 : 0.15), in: Capsule())
            .accessibilityLabel("Beta version")
    }
}
