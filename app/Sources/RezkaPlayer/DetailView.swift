import SwiftUI

struct DetailView: View {
    let item: CatalogueItem
    @EnvironmentObject var state: AppState

    @State private var info: TitleInfo?
    @State private var loading = true
    @State private var loadError: String?

    // Selection
    @State private var translatorID: Int?
    @State private var seasonID: Int?
    @State private var episodeID: Int?

    // Stream
    @State private var stream: StreamResponse?
    @State private var quality: String?
    @State private var streamLoading = false
    @State private var streamError: String?
    @State private var streamRequestID = 0   // guards against out-of-order refetches

    // Season download
    @State private var seasonDownloading = false
    @State private var seasonDone = 0
    @State private var seasonTotal = 0

    // Header description clamp
    @State private var descExpanded = false

    var body: some View {
        ScrollView {
            if loading {
                detailSkeleton
            } else if let loadError {
                CenteredMessage(systemImage: "exclamationmark.triangle",
                                title: "Couldn't load title", subtitle: loadError).frame(minHeight: 400)
            } else if let info {
                content(info)
            }
        }
        .navigationTitle(info?.name ?? item.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let saved = state.bookmarks.isBookmarked(item)
                Button {
                    let wasSaved = saved
                    state.bookmarks.toggle(item)
                    // When adding to Watch Later and Trakt is connected, mirror to the
                    // Trakt watchlist (best-effort, unobtrusive).
                    if !wasSaved, state.traktConnected {
                        let trakt = state.trakt
                        let original = info?.origName
                        let title = info?.name ?? item.title
                        let year = info?.releaseYear
                        let isSeries = info?.isSeries == true
                        Task.detached {
                            await trakt.addToWatchlist(originalTitle: original, title: title,
                                                       year: year, isSeries: isSeries)
                        }
                    }
                } label: {
                    Label(saved ? "In Watch Later" : "Watch Later",
                          systemImage: saved ? "star.fill" : "star")
                }
                .help(saved ? "Remove from Watch Later" : "Add to Watch Later")
            }
            ToolbarItem(placement: .primaryAction) {
                let isWatched = state.watched.isWatched(url: item.url)
                Button {
                    if isWatched { state.watched.unmark(url: item.url) }
                    else { state.watched.mark(item: item) }
                } label: {
                    Label(isWatched ? "Watched" : "Mark as watched",
                          systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help(isWatched ? "Watched" : "Mark as watched")
            }
        }
        .task { await loadInfo() }
    }

    // MARK: Layout — what it is, then pick & play, then related titles

    @ViewBuilder private func content(_ info: TitleInfo) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            header(info)
            watchPanel(info)
            if let similar = info.similar, !similar.isEmpty {
                similarSection(similar)
            }
        }
        .padding(24)
    }

    /// Cinematic header: blurred backdrop, poster, and what the title is.
    @ViewBuilder private func header(_ info: TitleInfo) -> some View {
        HStack(alignment: .top, spacing: 20) {
            PosterImage(urlString: info.thumbnail ?? item.image)
                .frame(width: 180, height: 262)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 10) {
                Text(info.name).font(.largeTitle).bold()
                    .fixedSize(horizontal: false, vertical: true)
                if let orig = info.origName, orig != info.name {
                    Text(orig).font(.title3).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let y = info.releaseYear { Badge(text: String(y), system: "calendar") }
                    if let r = info.rating { Badge(text: String(format: "%.2f", r.value), system: "star.fill") }
                    if let c = info.category?.name { Badge(text: c.capitalized, system: "tag") }
                    Badge(text: info.isSeries ? String(localized: "Series") : String(localized: "Movie"),
                          system: info.isSeries ? "tv" : "film")
                    if let n = seasonCount(info), n > 0 {
                        Badge(text: String(localized: "\(n) seasons"), system: "square.stack")
                    }
                }

                if let desc = info.description, !desc.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(desc).font(.body).foregroundStyle(.secondary)
                            .lineLimit(descExpanded ? nil : 4)
                            .fixedSize(horizontal: false, vertical: true)
                        if desc.count > 240 {
                            Button(descExpanded ? "Show less" : "Show more") {
                                withAnimation(.easeInOut(duration: 0.2)) { descExpanded.toggle() }
                            }
                            .buttonStyle(.link).font(.caption)
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(backdrop(info))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(.white.opacity(0.06)))
    }

    /// Blurred, scrimmed poster art filling the header card behind the content.
    @ViewBuilder private func backdrop(_ info: TitleInfo) -> some View {
        CachedAsyncImage(url: URL(string: info.thumbnailHQ ?? info.thumbnail ?? item.image ?? "")) { image in
            image.resizable().scaledToFill()
                .blur(radius: 34)
                .opacity(0.42)
                .overlay(LinearGradient(
                    colors: [.black.opacity(0.15), .black.opacity(0.45)],
                    startPoint: .top, endPoint: .bottom))
        } placeholder: { _ in Color(nsColor: .quaternarySystemFill) }
        .background(Color(nsColor: .quaternarySystemFill))
    }

    /// Skeleton shown while the title's metadata loads.
    private var detailSkeleton: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 20) {
                SkeletonBox(cornerRadius: Theme.cardRadius).frame(width: 180, height: 262)
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBox(cornerRadius: 6).frame(width: 300, height: 30)
                    SkeletonBox(cornerRadius: 6).frame(width: 160, height: 16)
                    SkeletonBox(cornerRadius: 6).frame(width: 320, height: 14)
                    SkeletonBox(cornerRadius: 6).frame(height: 70).frame(maxWidth: .infinity)
                    Spacer()
                }
                Spacer()
            }
            .frame(height: 262)
            SkeletonBox(cornerRadius: Theme.cardRadius).frame(height: 180).frame(maxWidth: .infinity)
        }
        .padding(24)
    }

    // MARK: Watch panel (season → episode → translation/quality → Play)

    @ViewBuilder private func watchPanel(_ info: TitleInfo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if info.isSeries {
                seasonTabs(info)
                episodeGrid(info)
                Divider()
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                translatorRow(info)
                if let stream, !stream.videos.isEmpty { qualityRow(stream) }
            }

            actionRow(info)

            if seasonDownloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Queuing season… \(seasonDone)/\(seasonTotal)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let stream, !stream.subtitles.isEmpty {
                Label("Subtitles: \(stream.subtitles.map(\.title).joined(separator: ", "))",
                      systemImage: "captions.bubble")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    @ViewBuilder private func seasonTabs(_ info: TitleInfo) -> some View {
        let seasons = info.episodes ?? []
        let current = currentSeason(info)
        if seasons.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons) { s in
                        let selected = s.season == current?.season
                        Button { selectSeason(s) } label: {
                            Text(s.season_text)
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(selected ? Theme.accent : Color(nsColor: .quaternarySystemFill),
                                            in: Capsule())
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else if let only = seasons.first {
            Text(only.season_text).font(.headline)
        }
    }

    @ViewBuilder private func episodeGrid(_ info: TitleInfo) -> some View {
        if let season = currentSeason(info) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56, maximum: 72), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(season.episodes) { ep in
                    let status = episodeStatus(season: season.season, episode: ep.episode)
                    Button { selectEpisode(ep.episode) } label: {
                        EpisodeChip(number: ep.episode, selected: ep.episode == episodeID, status: status)
                    }
                    .buttonStyle(.plain)
                    .help(ep.episode_text)
                    .contextMenu {
                        if case .watched = status {
                            Button("Mark as Unwatched") {
                                state.progress.remove(id: ProgressStore.key(
                                    pageURL: item.url, season: season.season, episode: ep.episode))
                            }
                        } else {
                            Button("Mark as Watched") {
                                markEpisodeWatched(info, season: season.season, episode: ep.episode)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func translatorRow(_ info: TitleInfo) -> some View {
        let translators = availableTranslators(info)
        if !translators.isEmpty {
            GridRow {
                Text("Translation").foregroundStyle(.secondary)
                Picker("Translation", selection: Binding(
                    get: { translatorID ?? translators.first?.id },
                    set: { newValue in
                        translatorID = newValue
                        if let tid = newValue { state.prefs.setTranslator(tid, for: item.url) }
                        Task { await refetch() }
                    })
                ) {
                    ForEach(translators) { t in
                        Text(t.premium ? "\(t.displayName) ★" : t.displayName).tag(Optional(t.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func qualityRow(_ stream: StreamResponse) -> some View {
        GridRow {
            Text("Quality").foregroundStyle(.secondary)
            Picker("Quality", selection: Binding(
                get: { quality ?? stream.sortedQualities.last ?? "" },
                set: { quality = $0; state.preferredQuality = $0 })
            ) {
                ForEach(stream.sortedQualities, id: \.self) { q in Text(q).tag(q) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    /// The one primary action (Play / Continue, labelled with where it resumes), plus downloads.
    @ViewBuilder private func actionRow(_ info: TitleInfo) -> some View {
        HStack(spacing: 12) {
            if let stream, let target = playerTarget(stream) {
                NavigationLink(value: target) {
                    playLabel.font(.headline).frame(minWidth: 170).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)

                downloadControl(stream, info: info)

                if let q = currentQuality(stream), let n = stream.videos[q]?.count, n > 1 {
                    Text("\(n) mirrors").font(.caption).foregroundStyle(.secondary)
                }
            } else if streamLoading {
                Button {} label: {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing…") }
                        .frame(minWidth: 170).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(true)
            } else if let streamError {
                Button { Task { await refetch() } } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(minWidth: 120).padding(.vertical, 4)
                }
                .buttonStyle(.bordered).controlSize(.large)
                Label(streamError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder private var playLabel: some View {
        let resumeAt = resumePosition
        if resumeAt > 5 {
            let at = Self.clock(resumeAt)
            if let tag = seasonEpisodeTag {
                Label("Continue \(tag) · \(at)", systemImage: "play.fill")
            } else {
                Label("Continue from \(at)", systemImage: "play.fill")
            }
        } else if let tag = seasonEpisodeTag {
            Label("Play \(tag)", systemImage: "play.fill")
        } else {
            Label("Play", systemImage: "play.fill")
        }
    }

    @ViewBuilder private func downloadControl(_ stream: StreamResponse, info: TitleInfo) -> some View {
        let have = currentQuality(stream).map {
            state.downloads.isDownloaded(pageURL: item.url, quality: $0, seasonEpisode: seasonEpisodeTag)
        } ?? false
        if info.isSeries {
            Menu {
                Button(have ? "Episode Already Downloaded" : "Download Episode") {
                    download(stream, info: info)
                }
                .disabled(have)
                Button("Download Whole Season") {
                    Task { await downloadSeason(info, like: stream) }
                }
                .disabled(seasonDownloading)
            } label: {
                Label("Download", systemImage: have ? "checkmark.circle" : "arrow.down.circle")
            }
            .fixedSize()
            .controlSize(.large)
        } else {
            Button { download(stream, info: info) } label: {
                Label(have ? "Downloaded" : "Download",
                      systemImage: have ? "checkmark.circle" : "arrow.down.circle")
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(have)
        }
    }

    // MARK: Similar titles

    @ViewBuilder private func similarSection(_ items: [CatalogueItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Similar").font(.title3).bold()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(items) { sim in
                        NavigationLink(value: sim) {
                            PosterCard(item: sim).frame(width: 140)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: Derived

    private func seasonCount(_ info: TitleInfo) -> Int? {
        guard info.isSeries, let n = info.episodes?.count, n > 1 else { return nil }
        return n
    }

    private func currentSeason(_ info: TitleInfo) -> SeasonInfo? {
        let seasons = info.episodes ?? []
        return seasons.first { $0.season == seasonID } ?? seasons.first
    }

    private func episodeStatus(season: Int, episode: Int) -> EpisodeChip.Status {
        let key = ProgressStore.key(pageURL: item.url, season: season, episode: episode)
        guard let e = state.progress.entry(id: key) else { return .new }
        if e.isComplete { return .watched }
        if e.duration > 0, e.position > 30 { return .inProgress(e.position / e.duration) }
        return .new
    }

    private func availableTranslators(_ info: TitleInfo) -> [Translator] {
        guard info.isSeries else { return info.translators }
        let seasons = info.episodes ?? []
        let sid = seasonID ?? seasons.first?.season
        let eps = seasons.first { $0.season == sid }?.episodes ?? []
        let eid = episodeID ?? eps.first?.episode
        let trans = eps.first { $0.episode == eid }?.translations ?? []
        // Map episode translations into Translator, de-duped, preserving order.
        var seen = Set<Int>()
        return trans.compactMap { t in
            guard !seen.contains(t.translator_id) else { return nil }
            seen.insert(t.translator_id)
            return Translator(id: t.translator_id, name: t.translator_name, premium: t.premium)
        }
    }

    private func currentQuality(_ stream: StreamResponse) -> String? {
        quality ?? stream.sortedQualities.last
    }

    private func playerTarget(_ stream: StreamResponse) -> PlayerTarget? {
        guard let q = currentQuality(stream), let url = stream.url(for: q) else { return nil }
        let isSeries = info?.isSeries == true
        let s = isSeries ? seasonID : nil
        let e = isSeries ? episodeID : nil
        let epList: [Int]? = isSeries ? selectedSeasonEpisodes() : nil
        let key = ProgressStore.key(pageURL: item.url, season: s, episode: e)
        let saved = state.progress.entry(id: key)
        let resume = (saved?.isComplete == false) ? (saved?.position ?? 0) : 0
        return PlayerTarget(
            title: titleForPlayback(), urlString: url, isLocal: false,
            subtitleURL: stream.subtitles.first?.link,
            pageURL: item.url, season: s, episode: e,
            translatorId: translatorID, quality: q,
            episodeList: epList, posterURL: info?.thumbnail ?? item.image,
            resumeAt: resume,
            originalTitle: info?.origName, year: info?.releaseYear,
            seriesName: isSeries ? info?.name : nil,
            allEpisodes: isSeries ? allEpisodeRefs() : nil)
    }

    /// Episode numbers of the currently selected season (for autoplay), or nil for movies.
    private func selectedSeasonEpisodes() -> [Int]? {
        guard info?.isSeries == true, let seasons = info?.episodes else { return nil }
        let sid = seasonID ?? seasons.first?.season
        return seasons.first { $0.season == sid }?.episodes.map { $0.episode }
    }

    /// Every episode of the series in watch order, so the player can cross season boundaries.
    private func allEpisodeRefs() -> [EpisodeRef] {
        (info?.episodes ?? []).flatMap { s in
            s.episodes.map { EpisodeRef(season: s.season, episode: $0.episode) }
        }
    }

    /// Resume position (>5s, unfinished) for the current selection, used to label the Play button.
    private var resumePosition: Double {
        let isSeries = info?.isSeries == true
        let key = ProgressStore.key(pageURL: item.url,
                                    season: isSeries ? seasonID : nil,
                                    episode: isSeries ? episodeID : nil)
        guard let e = state.progress.entry(id: key), !e.isComplete else { return 0 }
        return e.position
    }

    /// Where to pick a series back up: the most recently played episode, or — once that one is
    /// done — the episode after it (crossing into the next season). Nil when nothing has been
    /// played yet or the saved episode is no longer listed on the page.
    private func resumeEpisode(in info: TitleInfo) -> (season: Int, episode: Int)? {
        guard let last = state.progress.latestForPage(item.url),
              let s = last.season, let e = last.episode else { return nil }
        let seasons = info.episodes ?? []
        guard let si = seasons.firstIndex(where: { $0.season == s }),
              let ei = seasons[si].episodes.firstIndex(where: { $0.episode == e }) else { return nil }
        guard last.isComplete else { return (s, e) }
        let eps = seasons[si].episodes
        if ei + 1 < eps.count { return (s, eps[ei + 1].episode) }
        if si + 1 < seasons.count, let first = seasons[si + 1].episodes.first {
            return (seasons[si + 1].season, first.episode)
        }
        return (s, e)   // finished the final episode: stay on it
    }

    private func titleForPlayback() -> String {
        var t = info?.name ?? item.title
        if info?.isSeries == true, let s = seasonID, let e = episodeID { t += " · S\(s)E\(e)" }
        return t
    }

    private var seasonEpisodeTag: String? {
        guard info?.isSeries == true, let s = seasonID, let e = episodeID else { return nil }
        return "S\(s)E\(e)"
    }

    /// "1:02:03" / "12:40".
    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded(.down))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Actions

    private func selectSeason(_ s: SeasonInfo) {
        guard s.season != seasonID else { return }
        seasonID = s.season
        // Land on the first episode of that season you haven't finished.
        episodeID = s.episodes.first {
            if case .watched = episodeStatus(season: s.season, episode: $0.episode) { return false }
            return true
        }?.episode ?? s.episodes.first?.episode
        Task { await refetch() }
    }

    private func selectEpisode(_ e: Int) {
        guard e != episodeID else { return }
        episodeID = e
        Task { await refetch() }
    }

    private func markEpisodeWatched(_ info: TitleInfo, season: Int, episode: Int) {
        state.progress.record(
            id: ProgressStore.key(pageURL: item.url, season: season, episode: episode),
            title: "\(info.name) · S\(season)E\(episode)", pageURL: item.url,
            posterURL: info.thumbnail ?? item.image, season: season, episode: episode,
            translatorId: nil, quality: nil, position: 0, duration: 0, finished: true)
    }

    private func loadInfo() async {
        guard case .ready = state.sidecar.state else {
            loadError = "The helper isn't ready yet."; loading = false; return
        }
        loading = true; loadError = nil
        defer { loading = false }
        do {
            let info = try await state.api.info(url: item.url)
            self.info = info
            translatorID = info.translators.first?.id
            if info.isSeries {
                seasonID = info.episodes?.first?.season
                episodeID = info.episodes?.first?.episodes.first?.episode
                // Reopen on the episode you were watching (or the next one if you finished it).
                if let resume = resumeEpisode(in: info) {
                    seasonID = resume.season; episodeID = resume.episode
                }
            }
            // Apply the remembered translator for this title as an initial default — the one
            // explicitly picked, else the one last played — but only if it's valid for the
            // current movie/episode (refetch() re-validates regardless).
            if let remembered = state.prefs.translator(for: item.url)
                ?? state.progress.latestForPage(item.url)?.translatorId,
               availableTranslators(info).contains(where: { $0.id == remembered }) {
                translatorID = remembered
            }
            await refetch()
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func refetch() async {
        guard let info, case .ready = state.sidecar.state else { return }

        // Resolve a consistent selection BEFORE requesting. When the season changes the episode
        // is reset to nil; default it to the season's first episode, and make sure the translator
        // is one that actually exists for that episode (otherwise the sidecar errors).
        var reqSeason: Int? = nil
        var reqEpisode: Int? = nil
        var reqTranslation = translatorID
        if info.isSeries {
            let seasons = info.episodes ?? []
            let sid = seasonID ?? seasons.first?.season
            let eps = seasons.first { $0.season == sid }?.episodes ?? []
            let eid = episodeID ?? eps.first?.episode
            let avail = eps.first { $0.episode == eid }?.translations ?? []
            var tid = translatorID
            if tid == nil || !avail.contains(where: { $0.translator_id == tid }) {
                tid = avail.first?.translator_id
            }
            seasonID = sid; episodeID = eid; translatorID = tid   // keep UI consistent
            reqSeason = sid; reqEpisode = eid; reqTranslation = tid
        }

        let myID = streamRequestID &+ 1
        streamRequestID = myID
        streamLoading = true; streamError = nil; stream = nil
        defer { if streamRequestID == myID { streamLoading = false } }
        do {
            let s = try await state.api.stream(url: item.url, translation: reqTranslation,
                                               season: reqSeason, episode: reqEpisode)
            guard streamRequestID == myID else { return }   // a newer request superseded us
            stream = s
            // Resolution: keep the chosen one if still available; otherwise honour the
            // globally preferred resolution when this stream offers it, else the best.
            if let q = quality, s.videos[q] != nil {
                // keep current selection
            } else if !state.preferredQuality.isEmpty, s.videos[state.preferredQuality] != nil {
                quality = state.preferredQuality
            } else {
                quality = s.sortedQualities.last
            }
        } catch {
            guard streamRequestID == myID else { return }
            streamError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func download(_ stream: StreamResponse, info: TitleInfo) {
        guard let q = currentQuality(stream), let url = stream.url(for: q) else { return }
        state.downloads.startDownload(
            title: titleForPlayback(), pageURL: item.url, streamURL: url,
            quality: q, posterURL: info.thumbnail ?? item.image,
            seasonEpisode: seasonEpisodeTag,
            fetchURL: state.playbackURLString(for: url)   // relay when proxied, else direct
        )
    }

    /// Queue downloads for every episode in the current season, in the selected resolution
    /// (falling back to the best available per episode), skipping ones already downloaded.
    private func downloadSeason(_ info: TitleInfo, like stream: StreamResponse) async {
        guard info.isSeries, let sid = seasonID,
              let season = (info.episodes ?? []).first(where: { $0.season == sid })
        else { return }

        let desired = quality ?? stream.sortedQualities.last
        seasonDownloading = true; seasonDone = 0; seasonTotal = season.episodes.count
        defer { seasonDownloading = false }

        for ep in season.episodes {
            let seTag = "S\(sid)E\(ep.episode)"
            defer { seasonDone += 1 }

            if let dq = desired,
               state.downloads.isDownloaded(pageURL: item.url, quality: dq, seasonEpisode: seTag) {
                continue   // already have it at this quality
            }
            // Use the selected translator if this episode has it, else its first available.
            let tid = ep.translations.contains(where: { $0.translator_id == translatorID })
                ? translatorID : ep.translations.first?.translator_id
            do {
                let s = try await state.api.stream(url: item.url, translation: tid,
                                                   season: sid, episode: ep.episode)
                let q = (desired.flatMap { s.videos[$0] != nil ? $0 : nil }) ?? s.sortedQualities.last
                guard let q, let url = s.url(for: q) else { continue }
                state.downloads.startDownload(
                    title: "\(info.name) · \(seTag)", pageURL: item.url, streamURL: url,
                    quality: q, posterURL: info.thumbnail ?? item.image, seasonEpisode: seTag,
                    fetchURL: state.playbackURLString(for: url)
                )
            } catch {
                continue   // skip episodes that fail to resolve
            }
        }
    }
}

/// One episode in the title page's grid: its number, a ✓ once watched, and a thin resume bar
/// while in progress.
struct EpisodeChip: View {
    enum Status { case new, inProgress(Double), watched }

    let number: Int
    let selected: Bool
    let status: Status

    var body: some View {
        let watched: Bool = { if case .watched = status { return true } else { return false } }()
        HStack(spacing: 3) {
            Text(verbatim: "\(number)")
                .font(.callout.monospacedDigit().weight(selected ? .bold : .medium))
            if watched { Image(systemName: "checkmark").font(.caption2.bold()) }
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .foregroundStyle(selected ? Color.white : (watched ? Color.secondary : Color.primary))
        .background(selected ? Theme.accent : Color(nsColor: .quaternarySystemFill),
                    in: RoundedRectangle(cornerRadius: Theme.tileRadius))
        .overlay(alignment: .bottom) {
            if case .inProgress(let f) = status {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(selected ? Color.white : Theme.accent)
                            .frame(width: max(3, g.size.width * min(1, max(0, f))))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 7).padding(.bottom, 4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.tileRadius))
    }
}

struct Badge: View {
    let text: String
    let system: String
    var body: some View {
        Label(text, systemImage: system)
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
    }
}
