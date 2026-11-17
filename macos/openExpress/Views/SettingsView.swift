import OpenExpressKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Account", systemImage: "person.crop.circle") { AccountForm() }
            Tab("FIT Folder", systemImage: "folder") { DropFolderSettings() }
            Tab("Backups", systemImage: "externaldrive.badge.timemachine") { BackupSettings() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .scenePadding()
        .frame(width: 520)
        .frame(minHeight: 340)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            try LaunchAtLogin.set(on)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("openExpress stays in the menu bar, so it can back up and sync a device when you connect it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Back up and sync when a device is connected", isOn: $settings.automaticBackupAndSync)
                Toggle("Show notifications", isOn: $settings.notificationsEnabled)
            } footer: {
                Text("Software and map updates are only checked, never installed automatically.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The FIT drop folder: a folder another program watches for newly synced FIT files.
/// Kept by the engine (`copy_fit_to`, `copy_fit_types`).
struct DropFolderSettings: View {
    @Environment(AppModel.self) private var app
    @State private var folder = ""
    @State private var types: Set<String> = [FITDataType.activities.rawValue]
    @State private var choosing = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(folder.isEmpty ? String(localized: "Off") : (folder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(folder.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { choosing = true }
                        if !folder.isEmpty {
                            Button("Turn Off") { save(folder: "") }
                        }
                    }
                }
            } footer: {
                Text("After each sync, new FIT files are copied to this folder for other apps to pick up.")
                    .foregroundStyle(.secondary)
            }
            Section("Copy") {
                ForEach(FITDataType.allCases) { type in
                    Toggle(type.title, isOn: Binding(
                        get: { types.contains(type.rawValue) },
                        set: { on in
                            if on { types.insert(type.rawValue) } else { types.remove(type.rawValue) }
                            if types.isEmpty { types = [FITDataType.activities.rawValue] }
                            Task { await app.setEngineSetting("copy_fit_types", .string(types.sorted().joined(separator: ","))) }
                        }))
                }
            }
            .disabled(folder.isEmpty)
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { save(folder: url.path) }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            folder = await app.engineSetting("copy_fit_to")?.stringValue ?? ""
            let raw = await app.engineSetting("copy_fit_types")?.stringValue ?? ""
            let chosen = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            types = chosen.isEmpty ? [FITDataType.activities.rawValue] : chosen
        }
    }

    private func save(folder new: String) {
        folder = new
        Task { await app.setEngineSetting("copy_fit_to", .string(new)) }
    }
}

/// The engine's `backup_dir` and `backup_keep`: the defaults of every backup.
struct BackupSettings: View {
    @Environment(AppModel.self) private var app
    @State private var choosing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text((app.backupFolder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { choosing = true }
                    }
                }
                Stepper(value: Binding(
                    get: { app.backupKeep },
                    set: { n in Task { await app.setEngineSetting("backup_keep", .number(Double(n))) } }),
                        in: 0...50) {
                    LabeledContent("Keep", value: app.backupKeep == 0
                                   ? String(localized: "All backups")
                                   : String(localized: "Newest \(app.backupKeep)"))
                }
            } footer: {
                Text("Files unchanged since the previous backup are linked, not copied again, so keeping several backups costs little extra space.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await app.reloadEngineSettings() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await app.setEngineSetting("backup_dir", .string(url.path)) }
            }
        }
    }
}

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                TextField("Engine", text: $settings.engineOverride, prompt: Text("Built-in"))
                    .font(.body.monospaced())
                LabeledContent("Running", value: app.hello.map { "openexpress \($0.engine)" } ?? "—")
            } header: {
                Text("Debugging")
            } footer: {
                Text("A path to an `openexpress` program, or `mock`. Takes effect the next time openExpress opens. The environment variable OPENEXPRESS_ENGINE overrides it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
