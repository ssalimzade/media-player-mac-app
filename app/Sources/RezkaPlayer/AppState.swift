import Foundation
import SwiftUI
import Combine
import UserNotifications
import Darwin   // getifaddrs / ifaddrs for LAN IP discovery (AirPlay relay)

@MainActor
final class AppState: ObservableObject {
    @AppStorage("hdrezkaOrigin") var origin: String = "https://hdrezka.ag" {
        didSet { objectWillChange.send() }
    }
    /// Optional proxy (e.g. "socks5://user:pass@host:1080"). When set, scraping AND video
    /// (playback + downloads, via the sidecar relay) egress through it.
    @AppStorage("proxyURL") var proxyURLString: String = "" {
        didSet { objectWillChange.send() }
    }

    /// Globally preferred playback resolution (e.g. "1080p"); "" == auto (best available).
    @AppStorage("preferredQuality") var preferredQuality: String = "" {
        didSet { objectWillChange.send() }
    }

    /// When on, watched titles are filtered out of catalogue/search grids.
    @AppStorage("hideWatched") var hideWatched: Bool = false {
        didSet { objectWillChange.send() }
    }

    /// Detect intros/credits in series and skip them (with a short on-screen countdown): the
    /// intro jumps ahead, the credits go straight to the next episode. Off = no detection at all,
    /// so no extra audio is fetched.
    @AppStorage("autoSkipIntroCredits") var autoSkip: Bool = true {
        didSet { objectWillChange.send() }
    }

    /// Maximum on-disk size for downloads, in GB. `0` means unlimited. When exceeded,
    /// the oldest completed downloads are auto-deleted after a download finishes.
    @AppStorage("maxStorageGB") var maxStorageGB: Double = 0 {
        didSet {
            downloads.capBytes = Self.bytes(fromGB: maxStorageGB)
            objectWillChange.send()
        }
    }

    /// Convert a GB value to bytes (1 GB == 1_000_000_000 bytes, matching `.file` formatting).
    static func bytes(fromGB gb: Double) -> Int64 {
        gb <= 0 ? 0 : Int64(gb * 1_000_000_000)
    }

    /// Trakt.tv API app client id (user-supplied; the secret lives in the Keychain).
    @AppStorage("traktClientID") var traktClientID: String = "" {
        didSet { objectWillChange.send() }
    }

    // MARK: Trakt.tv

    /// Connection/status state for the Trakt integration, surfaced to Settings.
    @Published var traktConnected: Bool = false
    @Published var traktUsername: String = ""
    /// Transient status shown while the device flow is running ("", "Waiting…", error, etc.).
    @Published var traktStatus: String = ""
    /// The pending device-flow code to display (user_code + verification_url), if any.
    @Published var traktPendingCode: TraktClient.DeviceCode?

    /// REST client for Trakt (pure Swift; does NOT use the sidecar).
    lazy var trakt = TraktClient { [weak self] in
        self?.traktClientID ?? ""
    } clientSecretProvider: { [weak self] in
        self?.traktClientSecret ?? ""
    }

    /// The Trakt client secret, stored in the Keychain (never in UserDefaults).
    var traktClientSecret: String {
        get { Keychain.load(account: Keychain.traktSecretAccount) ?? "" }
        set {
            if newValue.isEmpty { Keychain.delete(account: Keychain.traktSecretAccount) }
            else { Keychain.save(newValue, account: Keychain.traktSecretAccount) }
            objectWillChange.send()
        }
    }

    private var traktPollTask: Task<Void, Never>?

    /// HDRezka session cookies (empty when logged out). Sent on every sidecar request
    /// so premium translations / higher resolutions are available.
    @Published var cookies: [String: String] = [:]
    /// Email of the currently logged-in account (empty when logged out).
    @AppStorage("hdrezkaEmail") var loggedInEmail: String = ""

    var isLoggedIn: Bool { !cookies.isEmpty }

    // MARK: Command palette navigation intents
    //
    // The ⌘K command palette publishes its outcome here; `RootView` observes these
    // and drives the actual sidebar selection / navigation push. (`SidebarSection`
    // lives in RootView.swift — same module, so referencing it here is fine.)

    /// Whether the ⌘K command palette sheet is presented.
    @Published var showCommandPalette = false
    /// A sidebar section the user chose in the palette; RootView selects it then clears this.
    @Published var pendingSection: SidebarSection?
    /// A catalogue item the user chose in the palette; RootView pushes its DetailView then clears this.
    @Published var pendingItem: CatalogueItem?

    let sidecar = SidecarManager()
    let downloads = DownloadManager()
    let bookmarks = BookmarkStore()
    let progress = ProgressStore()
    let watched = WatchedStore()
    let prefs = PreferenceStore()
    let skips = SkipStore()
    /// Finds intros/credits by comparing neighbouring episodes' audio (see SkipDetector).
    lazy var skipDetector = SkipDetector(store: skips) { [weak self] page, season, episode, translator in
        guard let self else { throw CancellationError() }
        return try await self.skipAnalysisURL(pageURL: page, season: season, episode: episode,
                                              translator: translator)
    }
    lazy var api = APIClient(sidecar: sidecar) { [weak self] in
        self?.origin ?? "https://hdrezka.ag"
    } cookiesProvider: { [weak self] in
        self?.cookies ?? [:]
    }

    private var cancellables = Set<AnyCancellable>()

    var proxyEnabled: Bool {
        !proxyURLString.trimmingCharacters(in: .whitespaces).isEmpty
    }

    init() {
        // Restore a previously saved HDRezka session from the keychain.
        if let json = Keychain.load(account: Keychain.cookiesAccount),
           let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            cookies = saved
        }

        // Apply the saved storage cap (enforced after each completed download).
        downloads.capBytes = Self.bytes(fromGB: maxStorageGB)

        // Repair Continue Watching entries written by older builds, which stored a media file path
        // instead of the HDRezka page URL for downloaded playback (see ProgressStore).
        progress.repairLocalFilePathEntries { [downloads] path in
            let name = (path as NSString).lastPathComponent
            guard let item = downloads.items.first(where: { $0.fileName == name }) else { return nil }
            return (item.pageURL, item.seasonEpisodeNumbers?.season,
                    item.seasonEpisodeNumbers?.episode)
        }

        // Re-publish sidecar state changes so views observing AppState refresh.
        sidecar.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        downloads.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        progress.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        watched.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        skips.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        prefs.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Push the proxy config to the sidecar whenever it (re)starts and becomes ready, then
        // preload what Continue Watching leads with.
        sidecar.$state
            .sink { [weak self] state in
                if case .ready = state { self?.pushProxyConfig(warmAfter: true) }
            }
            .store(in: &cancellables)

        // Ensure the Python helper is torn down when the app quits normally.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.sidecar.stop() }
            .store(in: &cancellables)

        // Restore a previously connected Trakt session (tokens live in the Keychain).
        Task { await refreshTraktConnection() }
    }

    func boot() {
        sidecar.start()
        requestNotificationAuthorizationIfPossible()
        updatePhoneRemote()
    }

    /// Ask once for permission to post local notifications (download-finished alerts).
    /// Safe to call repeatedly; does nothing harmful if the user has denied access.
    private func requestNotificationAuthorizationIfPossible() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: HDRezka account

    /// Log in via the sidecar; on success persist the session cookies to the keychain
    /// so they flow on all subsequent requests. Throws on failure with a usable message.
    func login(email: String, password: String) async throws {
        let resp = try await api.login(origin: origin, email: email, password: password)
        guard resp.ok, let c = resp.cookies, !c.isEmpty else {
            throw APIError.server(resp.message ?? "Login failed", type: nil)
        }
        cookies = c
        loggedInEmail = email
        if let data = try? JSONEncoder().encode(c),
           let json = String(data: data, encoding: .utf8) {
            Keychain.save(json, account: Keychain.cookiesAccount)
        }
    }

    /// Clear the stored session (cookies + saved email).
    func logout() {
        cookies = [:]
        loggedInEmail = ""
        Keychain.delete(account: Keychain.cookiesAccount)
    }

    // MARK: Trakt account

    /// Sync `traktConnected`/`traktUsername` from the client's stored tokens.
    func refreshTraktConnection() async {
        let connected = await trakt.hasTokens
        let name = connected ? (await trakt.username()) : nil
        traktConnected = connected
        traktUsername = name ?? ""
    }

    /// Start the OAuth device flow: fetch a code to show the user, then poll until authorized.
    func traktConnect() {
        traktPollTask?.cancel()
        traktStatus = "Requesting code…"
        traktPendingCode = nil
        traktPollTask = Task {
            do {
                let code = try await trakt.requestDeviceCode()
                traktPendingCode = code
                traktStatus = "Waiting for you to authorize on trakt.tv…"
                try await trakt.pollForToken(code)
                traktPendingCode = nil
                traktStatus = ""
                await refreshTraktConnection()
            } catch is CancellationError {
                traktPendingCode = nil
                traktStatus = ""
            } catch let e as TraktClient.TraktError {
                traktPendingCode = nil
                switch e {
                case .notConfigured: traktStatus = "Enter your Trakt client ID and secret first."
                case .denied: traktStatus = "Authorization was denied."
                case .expired: traktStatus = "The code expired. Try Connect again."
                case .http(let c): traktStatus = "Trakt error (HTTP \(c))."
                case .transport(let m): traktStatus = m
                }
            } catch {
                traktPendingCode = nil
                traktStatus = error.localizedDescription
            }
        }
    }

    /// Disconnect from Trakt (clears the stored tokens; keeps the entered credentials).
    func traktDisconnect() {
        traktPollTask?.cancel(); traktPollTask = nil
        Task {
            await trakt.clearTokens()
            traktPendingCode = nil
            traktStatus = ""
            await refreshTraktConnection()
        }
    }

    /// Send the current proxy setting to the sidecar (applies to all its traffic + the relay).
    /// `warmAfter` (a freshly started sidecar) then preloads the top Continue Watching titles.
    func pushProxyConfig(warmAfter: Bool = false) {
        let proxy = proxyURLString.trimmingCharacters(in: .whitespaces)
        Task {
            try? await api.configure(proxy: proxy)
            if warmAfter { warmContinueWatching() }
        }
    }

    // MARK: Prefetch

    /// Titles recently preloaded (page URL → when), so each is asked for at most once per
    /// `warmInterval`; the sidecar keeps a loaded title for 15 minutes.
    private var warmed: [String: Date] = [:]
    private static let warmInterval: TimeInterval = 10 * 60

    /// Have the sidecar load a title ahead of time — and, when you're part-way through it, the
    /// stream its page will open on — so opening it is instant. Called on poster hover and, for
    /// Continue Watching, at launch. Fire-and-forget: a failure just means it loads on open.
    func prefetchTitle(_ url: String) {
        guard case .ready = sidecar.state, url.hasPrefix("http") else { return }
        let now = Date()
        if let at = warmed[url], now.timeIntervalSince(at) < Self.warmInterval { return }
        warmed[url] = now
        // The same translator and episode DetailView will ask for (see loadInfo/resumeEpisode).
        let last = progress.latestForPage(url)
        let translation = prefs.translator(for: url) ?? last?.translatorId
        let api = api
        Task {
            _ = try? await api.info(url: url, translation: translation)
            if let last, !last.isComplete, let translation {
                _ = try? await api.stream(url: url, translation: translation,
                                          season: last.season, episode: last.episode)
            }
        }
    }

    /// CDN links recently warmed (link → when); see `warmStream`.
    private var warmedStreams: [String: Date] = [:]

    /// Get the link the player is about to open ready: the sidecar resolves its redirect to a
    /// storage node and opens a connection there, taking a second or more off the player's
    /// start. Called when a title page settles on a stream and for the player's next episode.
    func warmStream(_ cdnURL: String) {
        guard case .ready = sidecar.state else { return }
        let now = Date()
        if let at = warmedStreams[cdnURL], now.timeIntervalSince(at) < 60 { return }
        warmedStreams[cdnURL] = now
        let api = api
        Task { try? await api.warm(url: cdnURL) }
    }

    /// Preload the first few Continue Watching titles.
    private func warmContinueWatching() {
        var pages: [String] = []
        for e in progress.recent() where !pages.contains(e.pageURL) {
            pages.append(e.pageURL)
            if pages.count == 4 { break }
        }
        pages.forEach(prefetchTitle)
    }

    // MARK: Phone remote

    /// Serve the phone remote (see `PhoneRemote`) on the local network.
    @AppStorage("phoneRemoteEnabled") var phoneRemoteEnabled: Bool = true {
        didSet { objectWillChange.send(); updatePhoneRemote() }
    }
    /// The secret in the remote's link; "New link" replaces it, retiring old links.
    @AppStorage("phoneRemoteKey") private var phoneRemoteKey: String = ""
    /// The port the remote listens on once it's up (nil while off, or if it couldn't get one).
    @Published private(set) var phoneRemotePort: UInt16?
    private var remoteServer: RemoteServer?

    lazy var phoneRemote: PhoneRemote = {
        let remote = PhoneRemote()
        remote.app = self
        return remote
    }()

    /// The link the phone opens (shown as a QR code in Settings).
    var phoneRemoteURL: String? {
        guard let port = phoneRemotePort, let ip = LANAddress.primaryIPv4() else { return nil }
        return "http://\(ip):\(port)/?k=\(phoneRemoteKey)"
    }

    /// The same link by this Mac's Bonjour name, which survives the LAN IP changing.
    var phoneRemoteBonjourURL: String? {
        guard let port = phoneRemotePort, let host = RemoteServer.bonjourHost else { return nil }
        return "http://\(host):\(port)/?k=\(phoneRemoteKey)"
    }

    func updatePhoneRemote() {
        guard phoneRemoteEnabled else {
            remoteServer?.stop()
            remoteServer = nil
            phoneRemotePort = nil
            return
        }
        guard remoteServer == nil else { return }
        if phoneRemoteKey.isEmpty { phoneRemoteKey = Self.newRemoteKey() }
        phoneRemote.key = phoneRemoteKey
        let remote = phoneRemote
        let server = RemoteServer(handler: { remote.handle($0) },
                                  onPort: { [weak self] port in self?.phoneRemotePort = port })
        remoteServer = server
        server.start()
    }

    /// Replace the remote's link; phones holding the old one get turned away.
    func newPhoneRemoteLink() {
        phoneRemoteKey = Self.newRemoteKey()
        phoneRemote.key = phoneRemoteKey
        objectWillChange.send()
    }

    private static func newRemoteKey() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in alphabet.randomElement()! })
    }

    /// A title the title page should start playing as soon as its stream is ready — set when the
    /// phone remote picks something from Continue Watching.
    var autoplayPage: String?
    /// A player for RootView to push (the autoplay above).
    @Published var pendingPlayer: PlayerTarget?

    /// Open a title from the phone remote and play it where it was left off.
    func playFromRemote(pageURL: String) {
        let last = progress.latestForPage(pageURL)
        autoplayPage = pageURL
        pendingItem = CatalogueItem(
            title: last?.title.components(separatedBy: " · ").first ?? "", url: pageURL,
            image: last?.posterURL, rating: nil, category: nil, info: nil, postId: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// For a remote CDN URL, return the URL playback/downloads should actually hit:
    /// the local sidecar relay when a proxy is configured (so bytes egress via the proxy),
    /// otherwise the CDN URL directly.
    func playbackURLString(for cdnURL: String) -> String {
        guard proxyEnabled, let base = sidecar.baseURL else { return cdnURL }
        var comps = URLComponents(url: base.appendingPathComponent("relay"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "u", value: Self.b64url(cdnURL)),
            URLQueryItem(name: "t", value: sidecar.token),
            URLQueryItem(name: "r", value: Self.b64url(origin)),
        ]
        return comps.url!.absoluteString
    }

    /// Relay URL on this Mac's **LAN IP** — used for all remote playback, not just AirPlay.
    /// AVPlayer's external-playback mode hands the *URL* to the TV, which fetches it itself, so a
    /// `127.0.0.1` relay is useless to the receiver; worse, AVFoundation won't even offer a video
    /// AirPlay route for a loopback URL. A LAN URL works in both cases: the Mac plays it locally,
    /// and the TV can pull the same URL while the Mac still egresses to the CDN via its own
    /// VPN/proxy. Falls back to the loopback relay / direct CDN when there's no LAN IP.
    func lanRelayURLString(for cdnURL: String) -> String {
        guard let port = sidecar.port, let ip = LANAddress.primaryIPv4(),
              var comps = URLComponents(string: "http://\(ip):\(port)/relay") else {
            return playbackURLString(for: cdnURL)
        }
        comps.queryItems = [
            URLQueryItem(name: "u", value: Self.b64url(cdnURL)),
            URLQueryItem(name: "t", value: sidecar.token),
            URLQueryItem(name: "r", value: Self.b64url(origin)),
        ]
        return comps.url?.absoluteString ?? playbackURLString(for: cdnURL)
    }

    /// Where `SkipDetector` fetches an episode's audio from: the lowest-quality stream (it only
    /// needs the soundtrack, and it's the least data), routed like playback so a proxy still
    /// applies. Falls back to any translation if the requested one isn't offered for the episode.
    func skipAnalysisURL(pageURL: String, season: Int, episode: Int,
                         translator: Int?) async throws -> URL {
        let s: StreamResponse
        do {
            s = try await api.stream(url: pageURL, translation: translator,
                                     season: season, episode: episode)
        } catch where translator != nil {
            s = try await api.stream(url: pageURL, translation: nil, season: season, episode: episode)
        }
        guard let q = s.sortedQualities.first, let cdn = s.url(for: q),
              let url = URL(string: playbackURLString(for: cdn)) else {
            throw APIError.transport("No stream for S\(season)E\(episode)")
        }
        return url
    }

    /// LAN-reachable URL for a *downloaded* file, served by the sidecar's `/media` endpoint. Used
    /// when AirPlay engages on local playback: the receiver fetches the URL itself, so a `file://`
    /// path is meaningless to it. Returns nil if there's no LAN IP / sidecar port to build one.
    func localMediaURLString(forFilePath path: String) -> String? {
        guard let port = sidecar.port, let ip = LANAddress.primaryIPv4(),
              var comps = URLComponents(string: "http://\(ip):\(port)/media") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "f", value: Self.b64url((path as NSString).lastPathComponent)),
            URLQueryItem(name: "t", value: sidecar.token),
        ]
        return comps.url?.absoluteString
    }

    /// URL-safe base64 without padding (matches the sidecar's `_b64url_decode`).
    static func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Discovers this Mac's primary LAN IPv4 — the address an AirPlay receiver on the same network
/// uses to reach the sidecar relay. Prefers Wi-Fi/Ethernet (`en0`/`en1`/…), skips loopback and
/// link-local (`169.254.*`). Returns nil if the Mac has no routable LAN address.
enum LANAddress {
    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.isEmpty || ip.hasPrefix("169.254.") { continue }   // skip link-local
            candidates.append((String(cString: ifa.ifa_name), ip))
        }
        // Prefer the usual primary interfaces (Wi-Fi/Ethernet) before anything else.
        for pref in ["en0", "en1", "en2", "en3"] {
            if let m = candidates.first(where: { $0.name == pref }) { return m.ip }
        }
        return candidates.first?.ip
    }
}
