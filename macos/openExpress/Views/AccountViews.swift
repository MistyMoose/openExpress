import OpenExpressKit
import SwiftUI
import WebKit

/// The Account page of the sidebar; the same form is the Account tab of Settings.
struct AccountView: View {
    var body: some View {
        AccountForm()
            .navigationTitle("Account")
    }
}

struct AccountForm: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                if let account = app.account {
                    LabeledContent("Garmin account") {
                        Text(account.signedIn ? (account.account ?? String(localized: "Signed in")) : String(localized: "Not signed in"))
                    }
                    if !account.setupDone {
                        LabeledContent("Setup") {
                            Button("Set Up…") { app.isShowingSetup = true }
                        }
                    } else if account.signedIn {
                        Button("Sign Out", role: .destructive) { Task { await app.signOut() } }
                    } else {
                        Button("Sign In…") { app.isShowingSignIn = true }
                            .buttonStyle(.glassProminent)
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Garmin Connect")
            } footer: {
                Text("You type your password only on Garmin's own sign-in page. openExpress keeps a sign-in token in your Keychain.")
                    .foregroundStyle(.secondary)
            }

            if app.supports("strava.status") {
                StravaSection()
            }
        }
        .formStyle(.grouped)
    }
}

/// Strava: the client ID and secret of the user's own Strava API application (once), then
/// Strava's authorisation page in a sheet; its redirect brings the code.
struct StravaSection: View {
    @Environment(AppModel.self) private var app
    @State private var clientID = ""
    @State private var clientSecret = ""

    /// The engine's `strava_upload`: off unless chosen.
    private var uploadAfterSync: Binding<Bool> {
        Binding(get: { app.engineSettings["strava_upload"]?.boolValue ?? false },
                set: { on in Task { await app.setEngineSetting("strava_upload", .bool(on)) } })
    }

    var body: some View {
        @Bindable var app = app
        let connected = app.strava?.connected == true
        Section {
            LabeledContent("Strava") {
                Text(connected ? String(localized: "Connected") : String(localized: "Not connected"))
            }
            if connected {
                if let athlete = app.strava?.athleteName {
                    LabeledContent("Athlete", value: athlete)
                }
                if let scope = app.strava?.scope, !scope.isEmpty {
                    LabeledContent("Access") {
                        Text(scope.replacingOccurrences(of: ",", with: ", "))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Button("Disconnect Strava", role: .destructive) { Task { await app.disconnectStrava() } }
            } else {
                if app.strava?.configured != true {
                    TextField("Client ID", text: $clientID)
                    SecureField("Client secret", text: $clientSecret)
                }
                Button("Connect Strava…") {
                    Task { await app.startStrava(clientID: clientID, clientSecret: clientSecret) }
                }
                .disabled(app.strava?.configured != true && (clientID.isEmpty || clientSecret.isEmpty))
            }
        } header: {
            Text("Strava")
        } footer: {
            if app.strava?.configured != true {
                Text("Create an API application on strava.com/settings/api with “localhost” as its callback domain, then enter its client ID and secret.")
                    .foregroundStyle(.secondary)
            }
        }
        .task { await app.reloadEngineSettings() }
        .sheet(item: Binding(get: { app.stravaAuthorizeURL.map(IdentifiedURL.init) },
                             set: { if $0 == nil { app.stravaAuthorizeURL = nil } })) { item in
            StravaAuthorizeSheet(url: item.url)
        }
        if connected {
            Section {
                Toggle("Upload new activities after each sync", isOn: uploadAfterSync)
            } footer: {
                Text("Leave this off if Garmin Connect already sends your activities to Strava (Strava → Settings → My Apps → Garmin); otherwise every activity reaches Strava twice.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: URL { url }
}

struct StravaAuthorizeSheet: View {
    let url: URL
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SignInWebView(url: url, extract: { url in
            guard url.absoluteString.hasPrefix(AppModel.stravaRedirectURI),
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value
            else { return nil }
            return code
        }, readsPageText: false) { code in
            Task { await app.finishStrava(code: code) }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 600, idealHeight: 660)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { app.stravaAuthorizeURL = nil; dismiss() }
            }
        }
    }
}

// MARK: - Sign in

/// Garmin's sign-in page in a web view; the ticket it ends with goes to `account.sign_in`.
struct SignInSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var failure: String?
    @State private var completing = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let failure {
                    ContentUnavailableView("Sign-In Page Unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else if let url, !completing {
                    SignInWebView(url: url) { ticketURL in
                        completing = true
                        Task {
                            await app.completeSignIn(ticketURL: ticketURL)
                            completing = false
                        }
                    }
                } else {
                    ProgressView(completing ? "Signing in…" : "Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 480, idealWidth: 520, minHeight: 600, idealHeight: 660)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .navigationTitle("Sign In to Garmin Connect")
        .task {
            do {
                url = try await app.signInURL()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct SignInWebView: NSViewRepresentable {
    let url: URL
    /// What a navigation brings back (a ticket URL, an OAuth code); nil: keep browsing.
    var extract: (URL) -> String? = SignInTicket.fromURL
    /// Also look for a ticket in the page's text (Garmin's JSON answer).
    var readsPageText = true
    let onTicket: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(extract: extract, readsPageText: readsPageText, onTicket: onTicket) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing of the sign-in stays in a web cookie store of the app.
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let extract: (URL) -> String?
        let readsPageText: Bool
        let onTicket: (String) -> Void
        private var done = false

        init(extract: @escaping (URL) -> String?, readsPageText: Bool, onTicket: @escaping (String) -> Void) {
            self.extract = extract
            self.readsPageText = readsPageText
            self.onTicket = onTicket
        }

        private func deliver(_ ticketURL: String) {
            guard !done else { return }
            done = true
            onTicket(ticketURL)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url, let ticket = extract(url) {
                deliver(ticket)
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            if let url = webView.url, let ticket = extract(url) {
                webView.stopLoading()
                deliver(ticket)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url, let ticket = extract(url) {
                deliver(ticket)
                return
            }
            // Garmin's embed page may answer with the ticket as page content (JSON).
            guard readsPageText else { return }
            Task {
                let text = try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") as? String
                if let text, let ticket = SignInTicket.fromPageText(text) {
                    deliver(ticket)
                }
            }
        }
    }
}

// MARK: - First-run setup

/// Setup reads the app key from Garmin's Windows installer: download it to a temporary file,
/// hand it to `account.setup`, delete it. Or choose a copy already on this Mac.
struct SetupSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var working: LocalizedStringKey?
    @State private var failure: String?
    @State private var choosingFile = false

    static let installerURL = URL(string: "https://download.garmin.com/omt/express/GarminExpress.exe")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Set Up openExpress", systemImage: "key")
                .font(.title2.weight(.semibold))
            Text("openExpress talks to Garmin's services as Garmin Express does. To do that it needs the application key inside Garmin Express for Windows. openExpress can download the installer from Garmin, read the key from it and delete it again. Nothing is installed, and nothing else of it is kept.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Already have GarminExpress.exe? Choose it instead.")
                .foregroundStyle(.secondary)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let working {
                    ProgressView().controlSize(.small)
                    Text(working).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Installer…") { choosingFile = true }
                    .disabled(working != nil)
                Button("Download and Set Up") { Task { await downloadAndSetUp() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working != nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task { await setUp(with: url, deleteAfterwards: false) }
        }
    }

    private func downloadAndSetUp() async {
        failure = nil
        working = "Downloading the installer…"
        do {
            let (temp, response) = try await URLSession.shared.download(from: Self.installerURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temp)
                throw URLError(.badServerResponse)
            }
            let exe = FileManager.default.temporaryDirectory.appending(path: "GarminExpress-\(UUID().uuidString).exe")
            try FileManager.default.moveItem(at: temp, to: exe)
            await setUp(with: exe, deleteAfterwards: true)
        } catch {
            failure = error.localizedDescription
            working = nil
        }
    }

    private func setUp(with installer: URL, deleteAfterwards: Bool) async {
        failure = nil
        working = "Reading the installer…"
        let scoped = installer.startAccessingSecurityScopedResource()
        defer {
            if scoped { installer.stopAccessingSecurityScopedResource() }
            if deleteAfterwards { try? FileManager.default.removeItem(at: installer) }
        }
        do {
            try await app.setUp(installer: installer)
            working = nil
            dismiss()
            if app.account?.signedIn == false { app.isShowingSignIn = true }
        } catch {
            failure = error.localizedDescription
            working = nil
        }
    }
}
