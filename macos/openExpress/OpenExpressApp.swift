import OpenExpressKit
import SwiftUI

@main
struct OpenExpressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppBootstrap.app

    var body: some Scene {
        Window("openExpress", id: WindowID.main) {
            ContentView()
                .environment(app)
                .task { await app.start() }
        }
        .defaultSize(width: 1040, height: 700)
        .commands { OpenExpressCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(app)
        } label: {
            MenuBarLabel(pending: app.pendingUpdatesCount)
                // The menu bar item exists from launch, with or without a window: the
                // engine starts here so the automatic mode works in the background.
                .task { await app.start() }
        }
        .menuBarExtraStyle(.menu)
    }
}

enum WindowID {
    static let main = "main"
}

/// The one AppModel, shared by the scenes and the app delegate.
@MainActor
enum AppBootstrap {
    static let app: AppModel = {
        let settings = AppSettings()
        let location = EngineLocation.resolve(
            environment: ProcessInfo.processInfo.environment,
            override: settings.engineOverride,
            resources: Bundle.main.resourceURL,
            home: FileManager.default.homeDirectoryForCurrentUser)
        let engine: any EngineConnection = switch location {
        case .mock(let scenario):
            MockEngine(scenario: scenario.flatMap(MockEngine.Scenario.init(rawValue:)) ?? .standard)
        case .executable(let url):
            EngineClient(configuration: .init(executable: url))
        }
        let model = AppModel(engine: engine, settings: settings)
        model.notifier = SystemNotifier.shared
        // Development: `-OEInitialPage updates` on the command line opens on that page.
        if let raw = UserDefaults.standard.string(forKey: "OEInitialPage"), let page = DevicePage(rawValue: raw) {
            model.page = page
        }
        return model
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The menu bar item keeps the automatic mode running.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await AppBootstrap.app.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
