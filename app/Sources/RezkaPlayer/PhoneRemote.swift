import AppKit

/// The phone remote: a web page a phone on the same Wi-Fi opens (Settings shows it as a QR code)
/// to drive playback from the sofa — play/pause, seeking, previous/next episode, skipping the
/// intro, volume, full screen — and to start something from Continue Watching.
///
/// `RemoteServer` carries the HTTP; this routes each request to whatever the app is showing. The
/// player on screen registers itself (`attach`), so commands go straight to its `AVPlayer`.
/// Every request must carry the key from the link (`?k=`), so only a phone that scanned the code
/// can control anything.
@MainActor
final class PhoneRemote {
    enum Command {
        case toggle, previous, next, skip, cancelSkip, fullScreen, close
        case seek(by: Double)
        case seekTo(Double)
        case volume(Float)
        case autoSkip(Bool)
        case quality(String)
        case airPlay(Bool)
    }

    struct NowPlaying: Encodable {
        var title: String
        var episode: String?
        var poster: String?
        var playing: Bool
        var position: Double
        var duration: Double
        var volume: Float
        var canPrevious: Bool
        var canNext: Bool
        /// "intro" / "credits" while a skip button is up, with its countdown (0…1) if automatic.
        var skip: String?
        var skipProgress: Double?
        var autoSkip: Bool
        var airplay: Bool
        /// AirPlay was switched off from the phone, so "Play on TV" can switch it back.
        var airplayOff: Bool
        var fullScreen: Bool
        /// The playing resolution and every one on offer, best first (empty for downloads).
        var quality: String?
        var qualities: [String]
    }

    struct Title: Encodable {
        let url: String
        let title: String
        let info: String?
        let poster: String?
        /// Where opening it resumes (seconds) — when the title page will pick up this very episode.
        let resumeAt: Double?
    }

    struct State: Encodable {
        let nowPlaying: NowPlaying?
        let continueWatching: [Title]
    }

    struct PlayerHandle {
        let id: UUID
        let snapshot: () -> NowPlaying
        let perform: (Command) -> Void
    }

    weak var app: AppState?
    /// The key a request's `k` must match; changing it ("New link") retires old links.
    var key = ""
    private var player: PlayerHandle?

    func attach(_ handle: PlayerHandle) { player = handle }
    func detach(id: UUID) { if player?.id == id { player = nil } }

    func handle(_ r: RemoteServer.Request) -> RemoteServer.Response {
        if r.path == "/icon.png" { return icon }    // home-screen icon; nothing private
        guard !key.isEmpty, r.query["k"] == key else {
            return .text(403, "This remote link is out of date. Scan the QR code in "
                         + "Rezka Player › Settings › Phone remote again.")
        }
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(RemotePage.html)
        case ("GET", "/api/state"):
            return .json(state())
        case ("POST", "/api/cmd"):
            perform(r.body)
            return .json(state())
        default:
            return .text(404, "Not found")
        }
    }

    private func state() -> State {
        State(nowPlaying: player?.snapshot(), continueWatching: continueWatching())
    }

    private struct CommandBody: Decodable {
        let cmd: String
        var value: Double?
        var on: Bool?
        var url: String?
        var quality: String?
    }

    private func perform(_ body: Data) {
        guard let b = try? JSONDecoder().decode(CommandBody.self, from: body) else { return }
        if b.cmd == "open", let url = b.url {
            app?.playFromRemote(pageURL: url)
            return
        }
        let command: Command? = switch b.cmd {
        case "toggle": .toggle
        case "previous": .previous
        case "next": .next
        case "skip": .skip
        case "cancelSkip": .cancelSkip
        case "fullScreen": .fullScreen
        case "close": .close
        case "seek": b.value.map { .seek(by: $0) }
        case "seekTo": b.value.map { .seekTo($0) }
        case "volume": b.value.map { .volume(Float($0)) }
        case "autoSkip": b.on.map { .autoSkip($0) }
        case "quality": b.quality.map { .quality($0) }
        case "airplay": b.on.map { .airPlay($0) }
        default: nil
        }
        if let command { player?.perform(command) }
    }

    /// One tile per title, most recent first — the same row as Home's Continue Watching.
    private func continueWatching() -> [Title] {
        guard let app else { return [] }
        var seen = Set<String>()
        var out: [Title] = []
        for e in app.progress.recent() where e.pageURL.hasPrefix("http") && !seen.contains(e.pageURL) {
            seen.insert(e.pageURL)
            // The title page reopens on the page's latest entry (see DetailView.resumeEpisode).
            let latest = app.progress.latestForPage(e.pageURL)
            out.append(Title(url: e.pageURL,
                             title: e.title.components(separatedBy: " · ").first ?? e.title,
                             info: e.season.flatMap { s in e.episode.map { "S\(s)E\($0)" } },
                             poster: e.posterURL,
                             resumeAt: latest?.id == e.id && latest?.isComplete == false ? e.position : nil))
            if out.count == 8 { break }
        }
        return out
    }

    /// The app icon as a 180 pt PNG, for "Add to Home Screen".
    private lazy var icon: RemoteServer.Response = {
        let img = NSImage(size: NSSize(width: 180, height: 180), flipped: false) { rect in
            NSApp.applicationIconImage.draw(in: rect)
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return .text(404, "")
        }
        return RemoteServer.Response(type: "image/png", body: png)
    }()
}
