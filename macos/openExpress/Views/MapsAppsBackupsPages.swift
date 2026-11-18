import OpenExpressKit
import SwiftUI

// MARK: - Maps

struct MapsPage: View {
    let model: DeviceModel
    @State private var search = ""
    @State private var removing: DeviceMap?

    private func matches(_ name: String) -> Bool { search.isEmpty || name.localizedStandardContains(search) }

    var body: some View {
        Group {
            if let maps = model.maps {
                list(maps)
            } else {
                PageLoadingView(model: model, page: .maps)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search Maps")
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing
        ) { map in
            Button("Remove", role: .destructive) { model.maps(.remove, [map.name]) }
        } message: { map in
            Text("This frees \(Format.bytes(map.size)) on the device. You can install it again later.")
        }
    }

    private func list(_ maps: MapsList) -> some View {
        List {
            if let message = maps.message {
                Section {
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            if let storage = model.device.storage {
                Section {
                    Gauge(value: storage.usedFraction) {
                        Text("Device storage")
                    } currentValueLabel: {
                        Text("\(Format.bytes(maps.free ?? storage.free)) free")
                    }
                    .gaugeStyle(.linearCapacity)
                }
            }
            let installed = maps.installed.filter { matches($0.name) }
            if !installed.isEmpty {
                Section("Installed") {
                    ForEach(installed) { map in
                        MapRow(map: map) {
                            if map.status == .update {
                                Text(map.versionChange ?? String(localized: "Update available"))
                                    .foregroundStyle(.orange)
                                    .monospacedDigit()
                            } else {
                                Text(map.statusText ?? String(localized: "Up to date")).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button("Remove…", role: .destructive) { removing = map }
                                .disabled(model.isBusy || map.canRemove == false)
                        }
                    }
                }
            }
            let available = maps.available.filter { matches($0.name) }
            if !available.isEmpty {
                Section("Available") {
                    ForEach(available) { map in
                        let fits = map.size <= (maps.free ?? model.device.storage?.free ?? .max)
                        MapRow(map: map) {
                            Button(map.size >= InstallPlan.largeMap ? "Install…" : "Install") { model.requestInstall(map: map) }
                                .buttonStyle(.glass)
                                .disabled(model.isBusy || !fits || map.canInstall == false)
                                .help(fits ? (map.statusText ?? "") : String(localized: "Not enough free space on the device."))
                        }
                    }
                }
            }
            let own = maps.ownMaps.filter { matches($0.name) }
            if !own.isEmpty {
                Section("Your Own Maps") {
                    ForEach(own) { map in
                        LabeledContent {
                            if let size = map.size { Text(Format.bytes(size)).monospacedDigit() }
                        } label: {
                            Label(map.name, systemImage: "doc")
                        }
                    }
                }
            }
        }
    }
}

struct MapRow<Trailing: View>: View {
    let map: DeviceMap
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "map")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(map.name)
                Text([map.region, map.installed ? map.installedVersion ?? map.version : map.version, Format.bytes(map.size)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Apps

struct AppsPage: View {
    let model: DeviceModel

    var body: some View {
        if let list = model.apps {
            if let apps = list.apps {
                structured(apps)
            } else if list.lines.isEmpty {
                ContentUnavailableView("No Connect IQ Apps", systemImage: "square.grid.2x2",
                                       description: Text("Apps, watch faces and data fields installed on the device appear here."))
            } else {
                // `apps.list` answers as the command line: its lines, as they are.
                List(Array(list.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }
        } else {
            PageLoadingView(model: model, page: .apps)
        }
    }

    private func structured(_ apps: [ConnectIQApp]) -> some View {
        List(apps) { app in
            HStack(spacing: 12) {
                Image(systemName: app.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                    Text([app.type?.replacingOccurrences(of: "-", with: " ").capitalized, app.version,
                          app.size.map(Format.bytes)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if app.updateAvailable == true {
                    Text("Update available").font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Backups

struct BackupsPage: View {
    @Environment(AppModel.self) private var app
    let model: DeviceModel
    @State private var selection: BackupSnapshot.ID?

    var body: some View {
        Group {
            if let backups = model.backups {
                if backups.isEmpty {
                    ContentUnavailableView("No Backups", systemImage: "externaldrive.badge.timemachine",
                                           description: Text("Back up the device to keep a copy of its files on this Mac."))
                } else {
                    List(backups, selection: $selection) { backup in
                        BackupRow(backup: backup)
                            .contextMenu { Button("Show in Finder") { showInFinder(backup.url) } }
                    }
                    .contextMenu(forSelectionType: BackupSnapshot.ID.self) { _ in } primaryAction: { ids in
                        if let id = ids.first { showInFinder(URL(fileURLWithPath: id)) }
                    }
                    .safeAreaInset(edge: .bottom) { footer }
                }
            } else {
                PageLoadingView(model: model, page: .backups)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Show in Finder", systemImage: "folder") {
                    let folder = app.backupFolder.appending(path: model.device.unitID)
                    let target = selection.map { URL(fileURLWithPath: $0) }
                        ?? (FileManager.default.fileExists(atPath: folder.path) ? folder : app.backupFolder)
                    showInFinder(target)
                }
                .help("Show the backup in Finder")
            }
        }
    }

    private var footer: some View {
        Text(app.backupKeep > 0
             ? "Backups are kept in \(app.backupFolder.path(percentEncoded: false)); the newest \(app.backupKeep) are kept."
             : "Backups are kept in \(app.backupFolder.path(percentEncoded: false)).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
    }
}

struct BackupRow: View {
    let backup: BackupSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.date, format: .dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
                Text(Format.relative(backup.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(backup.bytes)).monospacedDigit()
                Text("\(backup.files) files").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
