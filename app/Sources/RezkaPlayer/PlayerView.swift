import SwiftUI
import AVKit
import Combine

struct PlayerView: View {
    let target: PlayerTarget
    @EnvironmentObject var state: AppState
    @State private var player: AVPlayer?
    /// What the controls drawn over the video show (episode bar, skip countdown, notices).
    @StateObject private var overlay = PlayerOverlayModel()

    // Progress / autoplay bookkeeping. These track the *currently playing* item, which can
    // advance past the pushed target when autoplay chains episodes.
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var readyObserver: AnyCancellable?
    @State private var externalObserver: AnyCancellable?
    @State private var swapReadyObserver: AnyCancellable?
    @State private var didSeekResume = false
    @State private var lastRecorded = Date.distantPast

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

    // Intro/credits skipping for the current item (reset whenever the item changes).
    /// Media time a running countdown fires at (media time, so pausing pauses the countdown).
    @State private var introSkipAt: Double?
    @State private var creditsSkipAt: Double?
    /// Skipped already, or the user cancelled — either way, leave this episode alone.
    @State private var introDone = false
    @State private var creditsDone = false
    /// The credits countdown and the real end of the item can both fire; only act once.
    @State private var endHandled = false
    /// After a credits skip dipped to black: brings picture and sound back once the next
    /// episode's item is ready.
    @State private var pendingReveal: (() -> Void)?

    var body: some View {
        Group {
            if let player {
                AVPlayerViewContainer(player: player, overlay: overlay)
                    .onDisappear { player.pause() }
            } else {
                CenteredMessage(systemImage: "play.slash", title: "Can't play this stream")
            }
        }
        .navigationTitle(curTitle.isEmpty ? target.title : curTitle)
        .toolbar {
            // Mirrors the on-video bar's Next button in the window toolbar. The bar is the main
            // control (it also works in full screen); this one is just easy to find.
            if hasNextEpisode {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        advanceToNextEpisode()
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
        .onChange(of: state.autoSkip) { _, on in
            overlay.autoSkip = on
            if on { requestSkipDetection() } else { setSkipPrompt(nil) }
        }
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
        wireOverlay()

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
        episodeChanged()
    }

    private func teardown() {
        // Save the exact stop position — the periodic observer only records every few seconds.
        if let p = player, let item = p.currentItem {
            let d = item.duration.seconds, t = p.currentTime().seconds
            if d.isFinite, d > 0, t.isFinite, t >= 0 { recordProgress(position: t, duration: d) }
        }
        player?.pause()
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        readyObserver?.cancel(); readyObserver = nil
        externalObserver?.cancel(); externalObserver = nil
        swapReadyObserver?.cancel(); swapReadyObserver = nil
        overlay.detach()
    }

    private func wireOverlay() {
        overlay.autoSkip = state.autoSkip
        overlay.onPrevious = { if let ref = neighbour(-1) { jump(to: ref) } }
        overlay.onNext = { advanceToNextEpisode() }
        overlay.onSelect = { jump(to: $0) }
        overlay.onSkipNow = { skipNow() }
        overlay.onCancelSkip = { cancelSkip() }
        overlay.onToggleAutoSkip = { state.autoSkip = $0 }
    }

    /// The playing episode changed (or playback just started): refresh the on-video controls and
    /// make sure intro/credits detection covers this episode and the next.
    private func episodeChanged() {
        refreshOverlay()
        requestSkipDetection()
        prefetchNextStream()
    }

    /// Resolve the next episode's stream now, so Next, auto-advance and the credits skip start it
    /// without waiting on HDRezka (the sidecar keeps the answer for a while).
    private func prefetchNextStream() {
        guard !target.isLocal, let page = target.pageURL, let next = neighbour(+1) else { return }
        let api = state.api, translator = curTranslatorId, quality = curQuality
        Task {
            guard let s = try? await api.stream(url: page, translation: translator,
                                                season: next.season, episode: next.episode)
            else { return }
            let q = quality.flatMap { s.videos[$0] != nil ? $0 : nil } ?? s.sortedQualities.last
            if let q, let url = s.url(for: q) { state.warmStream(url) }
        }
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

    /// Swap in another episode's item with fresh per-item state (resume seek, skip countdowns,
    /// the end-of-episode guard).
    private func load(_ item: AVPlayerItem, into p: AVPlayer, resumeAt: Double) {
        curResumeAt = resumeAt
        didSeekResume = false
        introSkipAt = nil; creditsSkipAt = nil
        introDone = false; creditsDone = false; endHandled = false
        setSkipPrompt(nil)
        lastRecorded = .distantPast

        observeEnd(of: item)
        observeReady(of: item)
        p.replaceCurrentItem(with: item)
        p.play()
        episodeChanged()
    }

    // MARK: Observers

    private func attachObservers(to p: AVPlayer, item: AVPlayerItem) {
        // Quarter-second ticks drive the skip countdown; progress is saved every ~5s of them.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in self.tick(time: time) }
        }
        // Resume seek once the item is ready and duration is known.
        observeReady(of: item)
        // Track AirPlay engage/disengage for the on-screen notice. No source swap is needed —
        // remote items already play from the LAN-IP relay the receiver can reach directly.
        externalObserver = p.publisher(for: \.isExternalPlaybackActive)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { active in self.handleExternalPlaybackChange(active) }
        // End-of-playback: mark finished + try autoplay.
        observeEnd(of: item)
    }

    private func observeReady(of item: AVPlayerItem) {
        readyObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { status in
                if status == .readyToPlay {
                    self.seekResumeIfNeeded(item: item)
                    self.revealIfPending()
                }
            }
    }

    /// AirPlay engaged/disengaged. Remote items need no swap — they already play from the LAN-IP
    /// relay, which the receiver can fetch directly. Downloaded files do: a `file://` path means
    /// nothing to the TV, so point it at the sidecar's `/media` URL while AirPlay is active and
    /// return to the local file afterwards, preserving the playback position.
    private func handleExternalPlaybackChange(_ active: Bool) {
        guard active != isExternal else { return }
        isExternal = active
        overlay.showToast(active ? String(localized: "AirPlay — playing on TV")
                                 : String(localized: "Playing on this Mac"))

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

        checkSkips(position: position, duration: duration)
        if Date().timeIntervalSince(lastRecorded) >= 5 {
            recordProgress(position: position, duration: duration)
        }
    }

    private func recordProgress(position: Double, duration: Double) {
        lastRecorded = Date()
        state.progress.record(
            id: currentKey(), title: curTitle.isEmpty ? target.title : curTitle,
            pageURL: target.pageURL ?? target.urlString,
            posterURL: target.posterURL, season: curSeason, episode: curEpisode,
            translatorId: curTranslatorId, quality: curQuality,
            position: position, duration: duration)
    }

    private func currentKey() -> String {
        let page = target.pageURL ?? target.urlString
        return ProgressStore.key(pageURL: page, season: curSeason, episode: curEpisode)
    }

    // MARK: Intro / credits skipping

    /// Seconds the skip button takes to fill before an automatic skip (Netflix-like).
    private static let skipLead: Double = 5

    /// Runs every tick. Shows a countdown as playback reaches a detected intro (then jumps to its
    /// end) or the credits (then plays the next episode). The seek happens on the AVPlayer, so it
    /// also skips on an AirPlay TV — only the countdown itself is drawn on the Mac.
    private func checkSkips(position t: Double, duration: Double) {
        guard target.isSeries, let m = state.skips.markers(for: currentKey()) else {
            return setSkipPrompt(nil)
        }
        let lead = Self.skipLead

        if let intro = m.intro, !introDone, t >= intro.lowerBound - lead, t < intro.upperBound - 1 {
            if state.autoSkip {
                let fireAt = introSkipAt ?? max(intro.lowerBound, t + lead)
                introSkipAt = fireAt
                if t >= fireAt {
                    skipIntro(to: intro.upperBound)
                } else {
                    setSkipPrompt(.init(kind: .intro, progress: Self.countdown(fireAt: fireAt, now: t)))
                }
            } else {
                setSkipPrompt(t >= intro.lowerBound ? .init(kind: .intro, progress: nil) : nil)
            }
            return
        }
        introSkipAt = nil   // outside the intro (e.g. seeked past it): drop any countdown

        // Credits only make sense to skip when there's an episode to go to; a marker in the
        // first half is a misdetection.
        if let cs = m.creditsStart, !creditsDone, cs > duration * 0.5,
           t >= cs - lead, t < duration - 1, neighbour(+1) != nil {
            if state.autoSkip {
                let fireAt = creditsSkipAt ?? max(cs, t + lead)
                creditsSkipAt = fireAt
                if t >= fireAt {
                    skipCredits()
                } else {
                    setSkipPrompt(.init(kind: .credits, progress: Self.countdown(fireAt: fireAt, now: t)))
                }
            } else {
                setSkipPrompt(t >= cs ? .init(kind: .credits, progress: nil) : nil)
            }
            return
        }
        creditsSkipAt = nil
        setSkipPrompt(nil)
    }

    private func setSkipPrompt(_ p: PlayerOverlayModel.SkipPrompt?) {
        if overlay.skip != p { overlay.skip = p }
    }

    /// How far a countdown firing at `fireAt` has run, 0…1 (the skip button's fill).
    private static func countdown(fireAt: Double, now t: Double) -> Double {
        min(1, max(0, 1 - (fireAt - t) / skipLead))
    }

    private func skipIntro(to end: Double) {
        introDone = true
        introSkipAt = nil
        setSkipPrompt(nil)
        cut { reveal in
            player?.seek(to: CMTime(seconds: end, preferredTimescale: 600),
                         toleranceBefore: .zero,
                         toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)) { _ in
                DispatchQueue.main.async { reveal() }
            }
        }
    }

    /// Credits reached (or "Next Episode" pressed): dip out, then go to the next episode. The
    /// picture comes back when its item is ready (see `observeReady`).
    private func skipCredits() {
        creditsDone = true
        setSkipPrompt(nil)
        cut { reveal in
            pendingReveal = reveal
            handleEnd()
            // Failsafe: never leave the picture black if the next episode doesn't load.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                revealIfPending()
            }
        }
    }

    /// A soft cut around a jump: picture and sound ease out (~0.35 s), `jump` runs, and calling
    /// the `reveal` it's handed eases them back in (~0.6 s), so a skip never lands abruptly. The
    /// fade is drawn on the Mac; an AirPlay TV just cuts.
    private func cut(_ jump: @escaping (_ reveal: @escaping () -> Void) -> Void) {
        guard let p = player else { return jump {} }
        let volume = p.volume
        rampVolume(p, to: 0, over: 0.35)
        overlay.setBlackout(true, 0.35) {
            jump {
                overlay.setBlackout(false, 0.6, nil)
                rampVolume(p, to: volume, over: 0.6)
            }
        }
    }

    private func revealIfPending() {
        guard let reveal = pendingReveal else { return }
        pendingReveal = nil
        reveal()
    }

    private func rampVolume(_ p: AVPlayer, to target: Float, over seconds: Double) {
        let start = p.volume, steps = 8
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds * Double(i) / Double(steps)) {
                p.volume = start + (target - start) * Float(i) / Float(steps)
            }
        }
    }

    /// "Skip Now" / "Play Now" / the manual Skip button.
    private func skipNow() {
        guard let kind = overlay.skip?.kind else { return }
        switch kind {
        case .intro:
            if let end = state.skips.markers(for: currentKey())?.intro?.upperBound { skipIntro(to: end) }
        case .credits:
            skipCredits()
        }
    }

    private func cancelSkip() {
        switch overlay.skip?.kind {
        case .intro: introDone = true; introSkipAt = nil
        case .credits: creditsDone = true; creditsSkipAt = nil
        case nil: break
        }
        setSkipPrompt(nil)
    }

    /// Kick off detection for the playing episode (and pre-analysis of the next one) against its
    /// neighbours. Cheap when markers already exist; off entirely when auto-skip is off.
    private func requestSkipDetection() {
        guard state.autoSkip, let page = target.pageURL, let cur = currentRef else { return }
        // Next first (it's pre-analysed too), then previous, then the one after next — so a
        // single odd neighbour (a recap episode, a differently mixed dub) can't hide the intro.
        let refs = [neighbour(+1), neighbour(-1), neighbour(+2)].compactMap { $0 }
        guard !refs.isEmpty else { return }
        let current = skipEpisode(cur, page: page)
        let neighbours = refs.map { skipEpisode($0, page: page) }
        let detector = state.skipDetector
        Task { await detector.prepare(current: current, neighbours: neighbours) }
    }

    /// Detection input for an episode: its download when there is one (no network needed),
    /// else the stream in the current translation.
    private func skipEpisode(_ ref: EpisodeRef, page: String) -> SkipEpisode {
        let key = ProgressStore.key(pageURL: page, season: ref.season, episode: ref.episode)
        if let item = downloadedEpisodes.first(where: { $0.ref == ref })?.item {
            return SkipEpisode(key: key, location: .file(state.downloads.localURL(for: item)))
        }
        return SkipEpisode(key: key, location: .stream(pageURL: page, season: ref.season,
                                                        episode: ref.episode, translator: curTranslatorId))
    }

    // MARK: End-of-playback + autoplay

    private func handleEnd() {
        guard !endHandled else { return }
        endHandled = true
        setSkipPrompt(nil)
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

        advanceToNextEpisode()
    }

    // MARK: Episode navigation (streamed + downloaded)

    private var currentRef: EpisodeRef? {
        guard let s = curSeason, let e = curEpisode else { return nil }
        return EpisodeRef(season: s, episode: e)
    }

    /// Completed downloads of this series, in watch order.
    private var downloadedEpisodes: [(ref: EpisodeRef, item: DownloadItem)] {
        guard let page = target.pageURL else { return [] }
        return state.downloads.downloadedEpisodes(ofPage: page).compactMap { item in
            item.seasonEpisodeNumbers.map { (EpisodeRef(season: $0.season, episode: $0.episode), item) }
        }
    }

    /// The episodes previous/next walk: downloaded ones for local playback (they have to be
    /// watchable offline), else the whole series — across seasons — for streams.
    private var episodeOrder: [EpisodeRef] {
        if target.isLocal { return downloadedEpisodes.map(\.ref) }
        guard target.pageURL != nil else { return [] }
        if let all = target.allEpisodes { return all }
        guard let s = target.season, let list = target.episodeList else { return [] }
        return list.map { EpisodeRef(season: s, episode: $0) }
    }

    private func neighbour(_ offset: Int) -> EpisodeRef? {
        let order = episodeOrder
        guard let cur = currentRef, let i = order.firstIndex(of: cur),
              order.indices.contains(i + offset) else { return nil }
        return order[i + offset]
    }

    /// Drives the toolbar button's visibility; recomputes as episodes advance.
    private var hasNextEpisode: Bool { neighbour(+1) != nil }

    /// File path of the local item actually playing — follows episode advances, unlike
    /// `target.urlString`, which stays pinned to whatever was pushed.
    private var currentLocalPath: String? {
        guard target.isLocal else { return nil }
        if let id = curDownloadID, let item = state.downloads.item(withID: id) {
            return state.downloads.localURL(for: item).path
        }
        return target.urlString
    }

    /// Play the next episode — from end-of-playback, the credits countdown, or a button.
    private func advanceToNextEpisode() {
        if let next = neighbour(+1) { jump(to: next) }
    }

    /// Switch to another episode of the series, resuming it if it was part-watched.
    private func jump(to ref: EpisodeRef) {
        guard !advancing, ref != currentRef else { return }
        let resume = savedResume(for: ref)
        if target.isLocal {
            guard let item = downloadedEpisodes.first(where: { $0.ref == ref })?.item else { return }
            play(downloaded: item, ref: ref, resumeAt: resume)
        } else {
            play(streamed: ref, resumeAt: resume)
        }
    }

    private func savedResume(for ref: EpisodeRef) -> Double {
        let key = ProgressStore.key(pageURL: target.pageURL ?? target.urlString,
                                    season: ref.season, episode: ref.episode)
        guard let e = state.progress.entry(id: key), !e.isComplete else { return 0 }
        return e.position
    }

    private func play(downloaded next: DownloadItem, ref: EpisodeRef, resumeAt: Double) {
        guard let p = player,
              let item = makeItem(cdnURLString: state.downloads.localURL(for: next).path,
                                  isLocal: true) else { return }
        // Advance bookkeeping so progress, a further "next" and the AirPlay swap use the new
        // episode (the season/episode drive the progress key).
        curDownloadID = next.id
        curSeason = ref.season
        curEpisode = ref.episode
        curTitle = next.title
        load(item, into: p, resumeAt: resumeAt)
        overlay.showToast(String(localized: "Playing \(ref.tag)…"))
    }

    private func play(streamed ref: EpisodeRef, resumeAt: Double) {
        guard let pageURL = target.pageURL else { return }
        advancing = true
        let translator = curTranslatorId
        overlay.showToast(String(localized: "Loading \(ref.tag)…"))

        Task { @MainActor in
            defer { advancing = false }
            do {
                let s: StreamResponse
                do {
                    s = try await state.api.stream(url: pageURL, translation: translator,
                                                   season: ref.season, episode: ref.episode)
                } catch where translator != nil {
                    // This episode isn't offered in the current translation: take what it has.
                    s = try await state.api.stream(url: pageURL, translation: nil,
                                                   season: ref.season, episode: ref.episode)
                }
                // Pick the preferred quality if still offered, else the best available.
                let q: String? = {
                    if let cq = curQuality, s.videos[cq] != nil { return cq }
                    return s.sortedQualities.last
                }()
                guard let q, let cdn = s.url(for: q),
                      let item = makeItem(cdnURLString: cdn, isLocal: false),
                      let p = player else {
                    revealIfPending()
                    overlay.showToast(String(localized: "Couldn't load \(ref.tag)"))
                    return
                }

                // Advance bookkeeping so progress + further autoplay use the new episode.
                curSeason = ref.season
                curEpisode = ref.episode
                curQuality = q
                if let t = s.translatorId { curTranslatorId = t }
                curTitle = "\(target.seriesName ?? target.title) · \(ref.tag)"
                load(item, into: p, resumeAt: resumeAt)
                overlay.showToast(String(localized: "Playing \(ref.tag)…"))
            } catch {
                revealIfPending()
                overlay.showToast(String(localized: "Couldn't load \(ref.tag)"))
            }
        }
    }

    // MARK: On-video controls

    private func refreshOverlay() {
        let order = episodeOrder
        overlay.isSeries = target.isSeries && !order.isEmpty
        overlay.title = target.seriesName ?? ""
        overlay.episodeLabel = currentRef?.tag
        overlay.canPrevious = neighbour(-1) != nil
        overlay.canNext = neighbour(+1) != nil

        let page = target.pageURL ?? target.urlString
        let cur = currentRef
        let bySeason = Dictionary(grouping: order, by: \.season)
        overlay.sections = bySeason.keys.sorted().map { s in
            EpisodeMenuSection(season: s, items: bySeason[s, default: []].map { ref in
                let key = ProgressStore.key(pageURL: page, season: ref.season, episode: ref.episode)
                return EpisodeMenuItem(ref: ref, current: ref == cur,
                                       watched: state.progress.entry(id: key)?.isComplete == true)
            })
        }
    }
}

/// Native AppKit AVKit player view, with inline controls, full-screen toggle and PiP. Our own
/// controls are installed into its content overlay so they follow it into full screen.
private struct AVPlayerViewContainer: NSViewRepresentable {
    let player: AVPlayer
    let overlay: PlayerOverlayModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        if let content = view.contentOverlayView {
            PlayerOverlayHost.install(in: content, model: overlay)
        }
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
