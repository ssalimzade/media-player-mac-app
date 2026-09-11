import SwiftUI
import AVKit
import Combine

struct PlayerView: View {
    let target: PlayerTarget
    @EnvironmentObject var state: AppState
    @State private var player: AVPlayer?

    // Progress / autoplay bookkeeping. These track the *currently playing* item, which can
    // advance past the pushed target when autoplay chains episodes.
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var readyObserver: AnyCancellable?
    @State private var externalObserver: AnyCancellable?
    @State private var swapReadyObserver: AnyCancellable?
    @State private var didSeekResume = false

    @State private var curSeason: Int?
    @State private var curEpisode: Int?
    @State private var curTranslatorId: Int?
    @State private var curQuality: String?
    @State private var curResumeAt: Double = 0
    @State private var isExternal = false
    /// Which download is playing, for local next-episode lookups (nil while streaming).
    @State private var curDownloadID: UUID?
    /// Display title of the *currently playing* item; advances with the episode.
    @State private var curTitle = ""
    /// Guards against double-advancing (end-of-playback firing while a manual skip is in flight).
    @State private var advancing = false

    @State private var overlayText: String?
    @State private var overlayVisible = false

    var body: some View {
        Group {
            if let player {
                ZStack {
                    // Host AVKit's native AVPlayerView directly. We deliberately avoid SwiftUI's
                    // `VideoPlayer`, which crashes during view-metadata instantiation on macOS 26.
                    AVPlayerViewContainer(player: player)
                        .onDisappear { player.pause() }

                    if overlayVisible, let overlayText {
                        VStack {
                            HStack {
                                Label(overlayText, systemImage: "forward.fill")
                                    .font(.callout).bold()
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(.black.opacity(0.7), in: Capsule())
                                    .foregroundStyle(.white)
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(24)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                }
            } else {
                CenteredMessage(systemImage: "play.slash", title: "Can't play this stream")
            }
        }
        .navigationTitle(curTitle.isEmpty ? target.title : curTitle)
        .toolbar {
            // "Next Episode", Netflix-style. In the window toolbar rather than overlaid on the
            // video, so it can't collide with AVKit's own inline controls (volume/PiP/full-screen).
            if hasNextEpisode {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        advanceToNextEpisode(auto: false)
                    } label: {
                        Label("Next Episode", systemImage: "forward.end.fill")
                    }
                    .disabled(advancing)
                    .help("Play the next episode")
                }
            }
        }
        .onAppear(perform: setup)
        .onDisappear(perform: teardown)
    }

    // MARK: Setup / teardown

    private func setup() {
        guard player == nil else { return }
        curSeason = target.season
        curEpisode = target.episode
        curTranslatorId = target.translatorId
        curQuality = target.quality
        curResumeAt = target.resumeAt
        curDownloadID = target.downloadID
        curTitle = target.title

        guard let item = makeItem(cdnURLString: target.urlString, isLocal: target.isLocal) else { return }
        let p = AVPlayer(playerItem: item)
        // Remote streams play through this Mac's LAN-IP relay (see makeItem) — a LAN-routable URL an
        // AirPlay receiver can also fetch. Because it isn't a 127.0.0.1 loopback (which a TV can
        // never reach, so AVFoundation suppresses the video route), the item stays AirPlay-eligible
        // and the player offers a real *video* route: selecting the TV plays it there, pulling from
        // this Mac. No source swap needed — the same URL works locally and on the receiver.
        p.allowsExternalPlayback = true
        player = p
        attachObservers(to: p, item: item)
        p.play()
    }

    private func teardown() {
        // Save the exact stop position — the periodic observer only records every few seconds.
        if let p = player { tick(time: p.currentTime()) }
        player?.pause()
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        readyObserver?.cancel(); readyObserver = nil
        externalObserver?.cancel(); externalObserver = nil
        swapReadyObserver?.cancel(); swapReadyObserver = nil
    }

    // MARK: Item construction

    private func makeItem(cdnURLString: String, isLocal: Bool) -> AVPlayerItem? {
        if isLocal {
            // While AirPlay is active the receiver fetches the URL itself, so hand it the sidecar's
            // /media URL — a file:// path is unusable to it. Matters when advancing episodes mid-cast.
            if isExternal, let s = state.localMediaURLString(forFilePath: cdnURLString),
               let url = URL(string: s) {
                return AVPlayerItem(url: url)
            }
            return AVPlayerItem(url: URL(fileURLWithPath: cdnURLString))
        }
        // Route remote streams through the Mac's LAN-IP relay for BOTH local playback and AirPlay:
        // it's reachable locally and by the TV, egresses via the configured proxy, and — being
        // LAN-routable rather than 127.0.0.1 — keeps the item AirPlay-eligible so macOS offers a
        // real video route. Falls back to the loopback relay / direct CDN when no LAN IP exists.
        let effective = state.lanRelayURLString(for: cdnURLString)
        guard let url = URL(string: effective) else { return nil }
        // HDRezka CDN expects a browser-like User-Agent (harmless for the local relay).
        let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                       "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        return AVPlayerItem(asset: asset)
    }

    // MARK: Observers

    private func attachObservers(to p: AVPlayer, item: AVPlayerItem) {
        // Periodic progress recording (~every 5s).
        let interval = CMTime(seconds: 5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in self.tick(time: time) }
        }
        // Resume seek once the item is ready and duration is known.
        readyObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                if status == .readyToPlay { self.seekResumeIfNeeded(item: item) }
            }
        // Track AirPlay engage/disengage for the on-screen overlay. No source swap is needed —
        // remote items already play from the LAN-IP relay the receiver can reach directly.
        externalObserver = p.publisher(for: \.isExternalPlaybackActive)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { active in self.handleExternalPlaybackChange(active) }
        // End-of-playback: mark finished + try autoplay.
        observeEnd(of: item)
    }

    /// AirPlay engaged/disengaged. Remote items need no swap — they already play from the LAN-IP
    /// relay, which the receiver can fetch directly. Downloaded files do: a `file://` path means
    /// nothing to the TV, so point it at the sidecar's `/media` URL while AirPlay is active and
    /// return to the local file afterwards, preserving the playback position.
    private func handleExternalPlaybackChange(_ active: Bool) {
        guard active != isExternal else { return }
        isExternal = active
        showOverlay(active ? "AirPlay — playing on TV" : "Playing on this Mac")

        // Use the *currently playing* file, which may have advanced past the pushed target.
        guard target.isLocal, let p = player, let path = currentLocalPath else { return }
        let swapped: AVPlayerItem
        if active {
            guard let s = state.localMediaURLString(forFilePath: path),
                  let url = URL(string: s) else { return }   // no LAN IP: leave playback as-is
            swapped = AVPlayerItem(url: url)
        } else {
            swapped = AVPlayerItem(url: URL(fileURLWithPath: path))
        }

        let resumeAt = p.currentTime()
        didSeekResume = true                    // don't re-apply the saved resume position
        observeEnd(of: swapped)
        p.replaceCurrentItem(with: swapped)
        // Seek back to where we were once the swapped item is ready.
        swapReadyObserver = swapped.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                if status == .readyToPlay {
                    p.seek(to: resumeAt)
                    p.play()
                    self.swapReadyObserver?.cancel(); self.swapReadyObserver = nil
                }
            }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                Task { @MainActor in self.handleEnd() }
        }
    }

    private func seekResumeIfNeeded(item: AVPlayerItem) {
        guard !didSeekResume, curResumeAt > 5 else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0, curResumeAt < duration - 30 else {
            didSeekResume = true; return
        }
        didSeekResume = true
        player?.seek(to: CMTime(seconds: curResumeAt, preferredTimescale: 600))
    }

    // MARK: Progress recording

    private func tick(time: CMTime) {
        guard let item = player?.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }   // skip until duration known
        let position = time.seconds
        guard position.isFinite, position >= 0 else { return }

        let key = currentKey()
        state.progress.record(
            id: key, title: target.title, pageURL: target.pageURL ?? target.urlString,
            posterURL: target.posterURL, season: curSeason, episode: curEpisode,
            translatorId: curTranslatorId, quality: curQuality,
            position: position, duration: duration)
    }

    private func currentKey() -> String {
        let page = target.pageURL ?? target.urlString
        return ProgressStore.key(pageURL: page, season: curSeason, episode: curEpisode)
    }

    // MARK: End-of-playback + autoplay

    private func handleEnd() {
        state.progress.markFinished(id: currentKey())
        state.watched.mark(url: target.pageURL ?? target.urlString,
                           title: target.title, posterURL: target.posterURL)

        // Best-effort Trakt scrobble for the just-finished item (uses the live season/episode
        // so it stays correct across autoplay). Fire-and-forget; never disturbs autoplay.
        if state.traktConnected {
            let trakt = state.trakt
            let isSeries = target.isSeries
            let original = target.originalTitle
            let title = target.title
            let year = target.year
            let season = curSeason
            let episode = curEpisode
            Task.detached {
                await trakt.markWatched(originalTitle: original, title: title, year: year,
                                        isSeries: isSeries, season: season, episode: episode)
            }
        }

        advanceToNextEpisode(auto: true)
    }

    // MARK: Next episode (streamed + downloaded)

    /// File path of the local item actually playing — follows episode advances, unlike
    /// `target.urlString`, which stays pinned to whatever was pushed.
    private var currentLocalPath: String? {
        guard target.isLocal else { return nil }
        if let id = curDownloadID, let item = state.downloads.item(withID: id) {
            return state.downloads.localURL(for: item).path
        }
        return target.urlString
    }

    /// Next downloaded episode of this series, or nil.
    private func nextDownload() -> DownloadItem? {
        guard let id = curDownloadID, let cur = state.downloads.item(withID: id) else { return nil }
        return state.downloads.nextDownloadedEpisode(after: cur)
    }

    /// Next episode number in the streamed season's list, or nil.
    private func nextStreamEpisode() -> Int? {
        guard target.pageURL != nil, let list = target.episodeList, let cur = curEpisode,
              let idx = list.firstIndex(of: cur), idx + 1 < list.count else { return nil }
        return list[idx + 1]
    }

    /// Drives the toolbar button's visibility; recomputes as episodes advance.
    private var hasNextEpisode: Bool {
        target.isLocal ? nextDownload() != nil : nextStreamEpisode() != nil
    }

    /// Play the next episode — from end-of-playback (`auto: true`) or the toolbar button.
    private func advanceToNextEpisode(auto: Bool) {
        guard !advancing else { return }
        if target.isLocal {
            guard let next = nextDownload() else { return }
            advancing = true
            play(downloaded: next)
        } else {
            guard let next = nextStreamEpisode() else { return }
            advancing = true
            play(streamedEpisode: next)
        }
    }

    private func play(downloaded next: DownloadItem) {
        defer { advancing = false }
        guard let p = player,
              let item = makeItem(cdnURLString: state.downloads.localURL(for: next).path,
                                  isLocal: true) else { return }
        // Advance bookkeeping so a further "next" (and the AirPlay swap) uses the new episode.
        curDownloadID = next.id
        curTitle = next.title
        didSeekResume = true       // no resume for a freshly-started next episode
        curResumeAt = 0

        observeEnd(of: item)
        p.replaceCurrentItem(with: item)
        p.play()
        showOverlay("Playing \(next.seasonEpisode ?? next.title)…")
    }

    private func play(streamedEpisode next: Int) {
        guard let pageURL = target.pageURL else { advancing = false; return }
        let season = curSeason
        let translator = curTranslatorId

        Task { @MainActor in
            defer { advancing = false }
            do {
                let s = try await state.api.stream(
                    url: pageURL, translation: translator, season: season, episode: next)
                // Pick the preferred quality if still offered, else the best available.
                let q: String? = {
                    if let cq = curQuality, s.videos[cq] != nil { return cq }
                    return s.sortedQualities.last
                }()
                guard let q, let cdn = s.url(for: q),
                      let item = makeItem(cdnURLString: cdn, isLocal: false),
                      let p = player else { return }

                // Advance bookkeeping so progress + further autoplay use the new episode.
                curEpisode = next
                curQuality = q
                didSeekResume = true
                curResumeAt = 0

                observeEnd(of: item)
                p.replaceCurrentItem(with: item)
                p.play()
                showOverlay("Playing S\(season ?? 0)E\(next)…")
            } catch {
                showOverlay("Couldn't load the next episode")
            }
        }
    }

    private func showOverlay(_ text: String) {
        overlayText = text
        withAnimation(.easeIn(duration: 0.25)) { overlayVisible = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeOut(duration: 0.6)) { overlayVisible = false }
        }
    }
}

/// Native AppKit AVKit player view, with inline controls, full-screen toggle and PiP.
private struct AVPlayerViewContainer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
