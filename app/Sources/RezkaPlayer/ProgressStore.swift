import Foundation
import Combine

/// Per-title playback progress ("Continue Watching" + resume position), persisted to
/// Application Support/RezkaPlayer/progress.json.
@MainActor
final class ProgressStore: ObservableObject {
    struct Entry: Codable, Identifiable, Hashable {
        let id: String          // stable key (see ProgressStore.key)
        var title: String
        var pageURL: String
        var posterURL: String?
        var season: Int?
        var episode: Int?
        var translatorId: Int?
        var quality: String?
        var position: Double    // seconds
        var duration: Double    // seconds
        var updatedAt: Date
        var finished: Bool

        /// Finished, or stopped so close to the end (typically in the credits) that there's
        /// nothing left worth resuming. Playback rarely reaches DidPlayToEndTime — the window gets
        /// closed once the credits roll — so `finished` alone under-reports.
        var isComplete: Bool {
            finished || (duration > 0 && duration - position < max(60, duration * 0.04))
        }
    }

    @Published private(set) var items: [Entry] = []
    private let fm = FileManager.default
    private let cap = 50

    init() { load() }

    // MARK: Key helper

    /// Stable key: the page URL for movies, or "pageURL#S{season}E{episode}" for series.
    static func key(pageURL: String, season: Int?, episode: Int?) -> String {
        if let s = season, let e = episode { return "\(pageURL)#S\(s)E\(e)" }
        return pageURL
    }

    // MARK: Public API

    /// Insert or update an entry by id, refreshing updatedAt. Drops oldest beyond the cap.
    func record(id: String, title: String, pageURL: String, posterURL: String?,
                season: Int?, episode: Int?, translatorId: Int?, quality: String?,
                position: Double, duration: Double, finished: Bool = false) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            var e = items[idx]
            e.title = title
            e.pageURL = pageURL
            e.posterURL = posterURL ?? e.posterURL
            e.season = season
            e.episode = episode
            e.translatorId = translatorId ?? e.translatorId
            e.quality = quality ?? e.quality
            e.position = position
            e.duration = duration
            e.updatedAt = Date()
            if finished { e.finished = true }
            items[idx] = e
        } else {
            items.append(Entry(
                id: id, title: title, pageURL: pageURL, posterURL: posterURL,
                season: season, episode: episode, translatorId: translatorId,
                quality: quality, position: position, duration: duration,
                updatedAt: Date(), finished: finished))
        }
        // Cap: keep the most-recently-updated `cap` entries.
        if items.count > cap {
            items.sort { $0.updatedAt > $1.updatedAt }
            items.removeLast(items.count - cap)
        }
        save()
    }

    func entry(id: String) -> Entry? { items.first { $0.id == id } }

    /// Resume fraction (0…1) to draw on a poster tile for `pageURL`, or nil when there's no
    /// meaningful unfinished progress. Uses the most-recent entry for the page (any episode).
    func fraction(forPage pageURL: String) -> Double? {
        guard let e = latestForPage(pageURL), !e.finished,
              e.duration > 0, e.position > 30 else { return nil }
        return min(1, max(0, e.position / e.duration))
    }

    /// Resumable, recently-watched entries (unfinished, meaningfully started), newest first.
    func recent(limit: Int = 30) -> [Entry] {
        items.filter { !$0.finished && $0.position > 30 }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Most recent entry (finished or not) for a given page URL, used to recall last prefs.
    func latestForPage(_ pageURL: String) -> Entry? {
        items.filter { $0.pageURL == pageURL }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    func markFinished(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].finished = true
        items[idx].updatedAt = Date()
        save()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    /// One-time repair. Progress recorded while playing a *downloaded* file used to store the media
    /// **file path** in `pageURL` (local targets carried no page URL), so Continue Watching asked
    /// HDRezka to load `/Users/…/Media/….mp4` and failed with "Couldn't load title — 404".
    /// `resolve` maps a file path back to its real page + episode. Entries it can't resolve (the
    /// download was since deleted, so the original page is unrecoverable) are left untouched rather
    /// than deleted — the Continue Watching row skips non-page URLs, so they simply stay hidden.
    func repairLocalFilePathEntries(
        resolve: (String) -> (pageURL: String, season: Int?, episode: Int?)?
    ) {
        guard items.contains(where: { !$0.pageURL.hasPrefix("http") }) else { return }
        var changed = false

        var byID: [String: Entry] = [:]
        var order: [String] = []
        func put(_ e: Entry) {
            if let existing = byID[e.id] {
                // Same episode watched both ways (streamed *and* downloaded): keep the newer.
                if e.updatedAt > existing.updatedAt { byID[e.id] = e }
            } else {
                byID[e.id] = e
                order.append(e.id)
            }
        }

        for e in items {
            guard !e.pageURL.hasPrefix("http") else { put(e); continue }
            guard let r = resolve(e.pageURL) else { put(e); continue }   // unresolvable: keep, hidden
            let season = e.season ?? r.season
            let episode = e.episode ?? r.episode
            changed = true
            put(Entry(id: Self.key(pageURL: r.pageURL, season: season, episode: episode),
                      title: e.title, pageURL: r.pageURL, posterURL: e.posterURL,
                      season: season, episode: episode, translatorId: e.translatorId,
                      quality: e.quality, position: e.position, duration: e.duration,
                      updatedAt: e.updatedAt, finished: e.finished))
        }
        guard changed else { return }
        items = order.compactMap { byID[$0] }
        save()
    }

    // MARK: Persistence

    private var file: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RezkaPlayer", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("progress.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
