import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: UpdaterController

    @AppStorage("sidecarDir") private var sidecarDir: String = SidecarManager.defaultSidecarDir
    @AppStorage("pythonPath") private var pythonPath: String = ""

    @State private var autoCheckUpdates = true

    @State private var originField: String = ""

    // HDRezka login
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var loggingIn = false
    @State private var loginError: String?

    // Trakt credentials (client id is bound to AppStorage; secret lives in the Keychain).
    @State private var traktSecretField: String = ""

    // Storage management
    @State private var confirmDeleteWatched = false

    /// Cap options shown in the menu (GB; 0 == unlimited / "Off").
    private let storageCapOptions: [Double] = [0, 5, 10, 20, 50, 100]

    var body: some View {
        Form {
            Section("HDRezka account") {
                if state.isLoggedIn {
                    LabeledContent("Account") {
                        Text(state.loggedInEmail.isEmpty ? "Logged in" : state.loggedInEmail)
                            .foregroundStyle(.secondary)
                    }
                    Button("Log out", role: .destructive) { state.logout() }
                    Text("Logging in enables premium translations and higher resolutions where your account allows.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Email", text: $email, prompt: Text("you@example.com"))
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                    HStack {
                        Button("Log in") { logIn() }
                            .disabled(loggingIn || email.isEmpty || password.isEmpty)
                        if loggingIn { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let loginError {
                        Label(loginError, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Your session cookies are stored in the macOS Keychain and sent to HDRezka only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("HDRezka mirror") {
                TextField("Domain", text: $originField, prompt: Text("https://hdrezka.ag"))
                    .textFieldStyle(.roundedBorder)
                Text("HDRezka rotates domains and may be geo-blocked. Paste a mirror that works for you (include https://).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply domain") {
                    let v = originField.trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { state.origin = normalized(v) }
                }
            }

            Section("Proxy (for geo-restricted streaming)") {
                TextField("Proxy URL", text: $state.proxyURLString,
                          prompt: Text("socks5://user:pass@host:1080"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.pushProxyConfig() }
                Text("HDRezka's video CDN is geo-blocked in some regions. A SOCKS5/HTTP proxy in a "
                     + "permitted region routes scraping, playback and downloads through it. Many "
                     + "VPNs expose a SOCKS5 endpoint (PIA, NordVPN, Windscribe, Mullvad). Leave "
                     + "empty to go direct.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Apply proxy") { state.pushProxyConfig() }
                    Spacer()
                    Label(state.proxyEnabled ? "Proxy on" : "Direct",
                          systemImage: state.proxyEnabled ? "lock.shield" : "globe")
                        .font(.caption).foregroundStyle(state.proxyEnabled ? .green : .secondary)
                }
            }

            Section("Playback") {
                Toggle("Skip intros and credits automatically", isOn: $state.autoSkip)
                Text("Finds each series' intro and closing credits by comparing the sound of "
                     + "neighbouring episodes, then skips them after a 3-second countdown — the "
                     + "credits go straight to the next episode. Works over AirPlay too. For "
                     + "streamed episodes this fetches a few minutes of each episode's start and "
                     + "end at the lowest quality, once; downloaded episodes need no extra data.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Used") {
                    Text("\(byteString(state.downloads.diskUsage)) · \(state.downloads.items.count) "
                         + "download\(state.downloads.items.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }

                Picker("Storage limit", selection: $state.maxStorageGB) {
                    ForEach(storageCapOptions, id: \.self) { gb in
                        Text(gb <= 0 ? "Off (unlimited)" : "\(Int(gb)) GB").tag(gb)
                    }
                }
                Text("When the total exceeds this limit, the oldest completed downloads are "
                     + "deleted automatically after a download finishes.")
                    .font(.caption).foregroundStyle(.secondary)

                let watchedCount = state.downloads
                    .watchedDownloads(isWatched: { state.watched.isWatched(url: $0) }).count
                Button(role: .destructive) {
                    confirmDeleteWatched = true
                } label: {
                    Label("Delete watched downloads", systemImage: "trash")
                }
                .disabled(watchedCount == 0)
                .confirmationDialog(
                    "Delete \(watchedCount) watched download\(watchedCount == 1 ? "" : "s")?",
                    isPresented: $confirmDeleteWatched, titleVisibility: .visible
                ) {
                    Button("Delete \(watchedCount)", role: .destructive) {
                        state.downloads.deleteMatching {
                            $0.state == .completed && state.watched.isWatched(url: $0.pageURL)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently removes completed downloads you've already watched.")
                }
                if watchedCount > 0 {
                    Text("\(watchedCount) completed download\(watchedCount == 1 ? "" : "s") "
                         + "marked watched.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                let largest = state.downloads.largestDownloads(limit: 5)
                if !largest.isEmpty {
                    ForEach(largest) { item in
                        LabeledContent {
                            Text(byteString(state.downloads.fileSize(of: item)))
                                .foregroundStyle(.secondary)
                        } label: {
                            Text(item.title).lineLimit(1)
                        }
                    }
                }
            }

            Section("Trakt") {
                if state.traktConnected {
                    LabeledContent("Account") {
                        Text(state.traktUsername.isEmpty ? "Connected"
                             : "Connected as \(state.traktUsername)")
                            .foregroundStyle(.secondary)
                    }
                    Button("Disconnect", role: .destructive) { state.traktDisconnect() }
                    Text("Finished movies/episodes are marked watched on Trakt, and Watch Later "
                         + "additions are mirrored to your Trakt watchlist.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Client ID", text: $state.traktClientID,
                              prompt: Text("from your Trakt API app"))
                        .textFieldStyle(.roundedBorder)
                    SecureField("Client Secret", text: $traktSecretField)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: traktSecretField) { _, v in state.traktClientSecret = v }

                    if let code = state.traktPendingCode {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enter this code on trakt.tv:")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(code.user_code)
                                .font(.system(.title2, design: .monospaced)).bold()
                                .textSelection(.enabled)
                            Button {
                                if let url = URL(string: code.verification_url) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("Open trakt.tv to authorize", systemImage: "safari")
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button("Connect") { state.traktConnect() }
                            .disabled(state.traktClientID.trimmingCharacters(in: .whitespaces).isEmpty
                                      || traktSecretField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if !state.traktStatus.isEmpty {
                        HStack(spacing: 6) {
                            if state.traktPendingCode != nil { ProgressView().controlSize(.small) }
                            Text(state.traktStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Create a free API app at trakt.tv/oauth/applications (use urn:ietf:wg:"
                         + "oauth:2.0:oob as the redirect URI), then paste its Client ID and Secret "
                         + "here. The secret is stored in the macOS Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                LabeledContent("Current version") {
                    Text(appVersionString).foregroundStyle(.secondary)
                }
                Toggle("Automatically check for updates", isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) { _, v in
                        updater.automaticallyChecksForUpdates = v
                    }
                Button("Check for updates now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Text("Updates are downloaded from this project's GitHub releases and verified with "
                     + "the app's built-in signature before installing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Python helper") {
                LabeledContent("Status") { Text(statusText).foregroundStyle(.secondary) }
                TextField("Sidecar folder", text: $sidecarDir).textFieldStyle(.roundedBorder)
                TextField("Python path (optional)", text: $pythonPath,
                          prompt: Text("auto (.venv or system python3)"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Restart helper") { state.sidecar.restart() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            originField = state.origin
            traktSecretField = state.traktClientSecret
            autoCheckUpdates = updater.automaticallyChecksForUpdates
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func logIn() {
        loggingIn = true; loginError = nil
        Task {
            defer { loggingIn = false }
            do {
                try await state.login(email: email, password: password)
                password = ""
            } catch {
                loginError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private func normalized(_ s: String) -> String {
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        return "https://" + s
    }

    private var statusText: String {
        switch state.sidecar.state {
        case .ready(let p): return "Ready on port \(p)"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .failed(let m): return m
        }
    }
}
