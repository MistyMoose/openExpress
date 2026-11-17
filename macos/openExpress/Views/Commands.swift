import OpenExpressKit
import SwiftUI

/// The menus: About, Device (Sync ⌘R, Check for Updates ⌘U, Back Up ⌘B) and the pages in View.
struct OpenExpressCommands: Commands {
    let app: AppModel

    private var model: DeviceModel? { app.selectedModel }
    private var canAct: Bool {
        guard let model else { return false }
        return model.device.connected && model.busyBy == nil && model.operation == nil
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About openExpress") { AboutPanel.show() }
        }

        CommandMenu("Device") {
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { model?.sync() }
                .keyboardShortcut("r")
                .disabled(!canAct)
            Button("Check for Updates", systemImage: "arrow.down.circle") {
                app.page = .updates
                if let model { Task { await model.load(.updates) } }
            }
            .keyboardShortcut("u")
            .disabled(model?.device.connected != true)
            Button("Back Up Now", systemImage: "externaldrive.badge.timemachine") { model?.backUp() }
                .keyboardShortcut("b")
                .disabled(!canAct)
            Divider()
            Button("Install All Updates…", systemImage: "arrow.down.circle.fill") {
                app.page = .updates
                model?.requestInstallAll()
            }
            .disabled(!canAct || (model?.badgeCount ?? 0) == 0)
            Button("Cancel Operation") { model?.cancelOperation() }
                .keyboardShortcut(".")
                .disabled(model?.operation == nil)
        }

        CommandGroup(before: .sidebar) {
            ForEach(Array(DevicePage.allCases.enumerated()), id: \.element) { index, page in
                Button(page.title) { app.page = page }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(model == nil)
            }
            Divider()
        }
    }
}

enum AboutPanel {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: String(localized: "macOS edition of openExpress — not affiliated with Garmin.\nFree software under the GNU GPL v3.0 or later."),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "openExpress",
            .credits: credits,
        ])
        NSApplication.shared.activate()
    }
}
