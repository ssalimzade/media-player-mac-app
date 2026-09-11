import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case home, films, series, cartoons, animation, search, watchLater, history, downloads

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Now Watching"
        case .films: return "Films"
        case .series: return "Series"
        case .cartoons: return "Cartoons"
        case .animation: return "Anime"
        case .search: return "Search"
        case .watchLater: return "Watch Later"
        case .history: return "History"
        case .downloads: return "Downloads"
        }
    }
    var systemImage: String {
        switch self {
        case .home: return "flame"
        case .films: return "film"
        case .series: return "tv"
        case .cartoons: return "teddybear"
        case .animation: return "sparkles"
        case .search: return "magnifyingglass"
        case .watchLater: return "star"
        case .history: return "clock.arrow.circlepath"
        case .downloads: return "arrow.down.circle"
        }
    }
    /// HDRezka category path for catalogue sections (nil for non-catalogue).
    var category: String? {
        switch self {
        case .films: return "films"
        case .series: return "series"
        case .cartoons: return "cartoons"
        case .animation: return "animation"
        default: return nil
        }
    }
}

/// A pushed video target (streaming or local file).
struct PlayerTarget: Hashable {
    let title: String
    let urlString: String
    let isLocal: Bool
    var subtitleURL: String? = nil

    // Progress / resume / autoplay context (defaults keep existing call sites compiling).
    var pageURL: String? = nil
    var season: Int? = nil
    var episode: Int? = nil
    var translatorId: Int? = nil
    var quality: String? = nil
    var episodeList: [Int]? = nil
    var posterURL: String? = nil
    var resumeAt: Double = 0

    // Trakt scrobble context: the original (non-localized) title + release year match
    // Trakt's catalogue far better than the Russian display title.
    var originalTitle: String? = nil
    var year: Int? = nil

    /// For local playback: which download this is, so the player can find the next downloaded
    /// episode. Nil for streams, which use `episodeList` instead.
    var downloadID: UUID? = nil

    /// Series display name (without the SxEy suffix), so the player can retitle as it advances.
    var seriesName: String? = nil
    /// Every episode of the series in watch order (streams only), so previous/next and the
    /// player's episode list can cross season boundaries. Nil falls back to `episodeList`.
    var allEpisodes: [EpisodeRef]? = nil

    /// Whether this target is a series (true when a season/episode is set).
    var isSeries: Bool { season != nil || episode != nil }
}

/// A (season, episode) pair in a series' watch order.
struct EpisodeRef: Hashable {
    let season: Int
    let episode: Int
    var tag: String { "S\(season)E\(episode)" }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var selection: SidebarSection = .home
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Browse") {
                    ForEach([SidebarSection.home, .films, .series, .cartoons, .animation]) { row($0) }
                }
                Section("Library") {
                    ForEach([SidebarSection.search, .watchLater, .history, .downloads]) { row($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) { SidecarStatusBar() }
        } detail: {
            NavigationStack(path: $path) {
                sectionRoot
                    .navigationDestination(for: CatalogueItem.self) { item in
                        DetailView(item: item)
                    }
                    .navigationDestination(for: PlayerTarget.self) { target in
                        PlayerView(target: target)
                    }
            }
        }
        .onChange(of: selection) { _, _ in path = NavigationPath() }
        .sheet(isPresented: $state.showCommandPalette) {
            CommandPalette()
        }
        .onChange(of: state.pendingSection) { _, newValue in
            guard let section = newValue else { return }
            selection = section
            path = NavigationPath()
            state.pendingSection = nil
        }
        .onChange(of: state.pendingItem) { _, newValue in
            guard let item = newValue else { return }
            // A phone-remote pick replaces whatever's open (a playing episode saves on the way out).
            if state.autoplayPage == item.url { path = NavigationPath() }
            path.append(item)
            state.pendingItem = nil
        }
        .onChange(of: state.pendingPlayer) { _, newValue in
            guard let target = newValue else { return }
            path.append(target)
            state.pendingPlayer = nil
        }
    }

    /// A sidebar row with an optional trailing count badge.
    @ViewBuilder private func row(_ section: SidebarSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .badge(badgeCount(section))
            .tag(section)
    }

    /// Trailing badge value per section (0 hides the badge automatically).
    private func badgeCount(_ section: SidebarSection) -> Int {
        switch section {
        case .watchLater: return state.bookmarks.items.count
        case .downloads:  return state.downloads.items.filter { $0.state == .downloading }.count
        default:          return 0
        }
    }

    @ViewBuilder private var sectionRoot: some View {
        switch selection {
        case .home:
            CatalogueView(mode: .home)
        case .films, .series, .cartoons, .animation:
            CatalogueView(mode: .category(selection.category!, title: selection.title))
        case .search:
            SearchView()
        case .watchLater:
            WatchLaterView()
        case .history:
            HistoryView()
        case .downloads:
            DownloadsView()
        }
    }
}

/// Small status pill showing whether the Python helper is up.
struct SidecarStatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if case .failed = state.sidecar.state {
                Button("Retry") { state.sidecar.restart() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var color: Color {
        switch state.sidecar.state {
        case .ready: return .green
        case .starting: return .yellow
        case .stopped: return .gray
        case .failed: return .red
        }
    }
    private var label: String {
        switch state.sidecar.state {
        case .ready(let p): return "Helper ready · :\(p)"
        case .starting: return "Starting helper…"
        case .stopped: return "Helper stopped"
        case .failed(let m): return m
        }
    }
}
