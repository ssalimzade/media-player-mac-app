import Foundation
import Combine
import UserNotifications

enum DownloadState: String, Codable {
    case downloading, completed, failed, paused
}

struct DownloadItem: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var pageURL: String          // HDRezka page this came from
    var streamURL: String        // direct .mp4 that was downloaded
    var quality: String
    var posterURL: String?
    var fileName: String         // relative file name in the media dir
    var state: DownloadState
    var bytesReceived: Int64
    var totalBytes: Int64
    var addedAt: Date
    var seasonEpisode: String?   // e.g. "S1E3" for series

    var progress: Double {
        totalBytes > 0 ? Double(bytesReceived) / Double(totalBytes) : 0
    }

    /// `"S1E3"` → `(season: 1, episode: 3)`; nil for movies (or an unparseable label).
    var seasonEpisodeNumbers: (season: Int, episode: Int)? {
        guard let se = seasonEpisode, se.hasPrefix("S"),
              let eIdx = se.firstIndex(of: "E"),
              let season = Int(se[se.index(after: se.startIndex)..<eIdx]),
              let episode = Int(se[se.index(after: eIdx)...]) else { return nil }
        return (season, episode)
    }
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    /// Total bytes currently used on disk by `Media/`, refreshed after downloads/deletes.
    @Published private(set) var diskUsage: Int64 = 0

    /// Storage cap in bytes; downloads are auto-cleaned (oldest completed first) when the
    /// total on-disk size exceeds this. `0` (or negative) means unlimited.
    var capBytes: Int64 = 0 {
        didSet { enforceCap(maxBytes: capBytes) }
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private var taskToItem: [Int: UUID] = [:]
    /// Resume data captured when a download is paused (cancel-by-producing-resume-data).
    private var resumeData: [UUID: Data] = [:]
    /// Task ids we cancelled intentionally for a pause, so the completion delegate
    /// doesn't mark them failed.
    private var pausingTasks: Set<Int> = []
    /// When each task last published its byte count. URLSession reports every few KB, and each
    /// publish re-rendered the whole app (AppState re-publishes this store) and rewrote
    /// library.json — the UI crawled while anything downloaded. Twice a second is plenty.
    private var lastProgressPublish: [Int: Date] = [:]
    private let fm = FileManager.default

    override init() {
        super.init()
        load()
        refreshDiskUsage()
    }

    // MARK: Paths

    private var appSupportDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RezkaPlayer", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var mediaDir: URL {
        let d = appSupportDir.appendingPathComponent("Media", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var libraryFile: URL { appSupportDir.appendingPathComponent("library.json") }

    func item(withID id: UUID) -> DownloadItem? {
        items.first { $0.id == id }
    }

    /// A series' *downloaded* episodes in watch order — season, then episode, compared
    /// numerically (so S1E9 comes before S1E10) — one per episode. Only completed downloads
    /// qualify: previous/next in the player has to be watchable offline to be worth offering.
    func downloadedEpisodes(ofPage pageURL: String) -> [DownloadItem] {
        var seen = Set<String>()
        return items
            .compactMap { item -> (DownloadItem, Int, Int)? in
                guard item.state == .completed, item.pageURL == pageURL,
                      let n = item.seasonEpisodeNumbers else { return nil }
                return (item, n.season, n.episode)
            }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .compactMap { seen.insert("\($0.1)x\($0.2)").inserted ? $0.0 : nil }
    }

    func localURL(for item: DownloadItem) -> URL {
        mediaDir.appendingPathComponent(item.fileName)
    }

    // MARK: Public API

    /// Begin downloading a stream. `streamURL` is the real CDN URL we store for reference;
    /// `fetchURL` is what we actually GET (the sidecar relay when a proxy is active, so the
    /// bytes egress through the proxy). Defaults to `streamURL` when not proxied.
    func startDownload(title: String, pageURL: String, streamURL: String,
                       quality: String, posterURL: String?, seasonEpisode: String? = nil,
                       fetchURL: String? = nil) {
        let id = UUID()
        let fileName = "\(id.uuidString).mp4"
        var item = DownloadItem(
            id: id, title: title, pageURL: pageURL, streamURL: streamURL,
            quality: quality, posterURL: posterURL, fileName: fileName,
            state: .downloading, bytesReceived: 0, totalBytes: 0,
            addedAt: Date(), seasonEpisode: seasonEpisode
        )
        items.insert(item, at: 0)
        save()

        guard let url = URL(string: fetchURL ?? streamURL) else {
            item.state = .failed
            update(item)
            return
        }
        let task = session.downloadTask(with: url)
        taskToItem[task.taskIdentifier] = id
        task.resume()
    }

    func delete(_ item: DownloadItem) {
        // Cancel any in-flight task for this item before removing it.
        if let tid = taskToItem.first(where: { $0.value == item.id })?.key {
            taskToItem[tid] = nil
            pausingTasks.remove(tid)
            session.getAllTasks { tasks in
                tasks.first { $0.taskIdentifier == tid }?.cancel()
            }
        }
        resumeData[item.id] = nil
        try? fm.removeItem(at: localURL(for: item))
        items.removeAll { $0.id == item.id }
        save()
        refreshDiskUsage()
    }

    /// Pause an in-progress download, capturing resume data so it can continue later.
    func pause(_ item: DownloadItem) {
        guard item.state == .downloading,
              let tid = taskToItem.first(where: { $0.value == item.id })?.key
        else { return }
        pausingTasks.insert(tid)
        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskIdentifier == tid })
                    as? URLSessionDownloadTask else {
                Task { @MainActor in self.pausingTasks.remove(tid) }
                return
            }
            task.cancel(byProducingResumeData: { data in
                Task { @MainActor in
                    self.taskToItem[tid] = nil
                    self.pausingTasks.remove(tid)
                    if let data { self.resumeData[item.id] = data }
                    guard var it = self.items.first(where: { $0.id == item.id }) else { return }
                    it.state = .paused
                    self.update(it)
                }
            })
        }
    }

    /// Resume a previously paused download. Uses captured resume data when available,
    /// otherwise restarts the transfer from the original URL.
    func resume(_ item: DownloadItem) {
        guard item.state == .paused else { return }
        var it = item
        it.state = .downloading
        update(it)

        let task: URLSessionDownloadTask
        if let data = resumeData[item.id] {
            task = session.downloadTask(withResumeData: data)
            resumeData[item.id] = nil
        } else if let url = URL(string: item.streamURL) {
            task = session.downloadTask(with: url)
        } else {
            it.state = .failed
            update(it)
            return
        }
        taskToItem[task.taskIdentifier] = item.id
        task.resume()
    }

    func isDownloaded(pageURL: String, quality: String, seasonEpisode: String?) -> Bool {
        items.contains {
            $0.pageURL == pageURL && $0.quality == quality
            && $0.seasonEpisode == seasonEpisode && $0.state == .completed
        }
    }

    // MARK: Storage management

    /// On-disk size of a single item's media file, falling back to the recorded
    /// `totalBytes` when the file is missing/unreadable.
    func fileSize(of item: DownloadItem) -> Int64 {
        if let attrs = try? fm.attributesOfItem(atPath: localURL(for: item).path),
           let size = attrs[.size] as? NSNumber {
            return size.int64Value
        }
        return item.totalBytes
    }

    /// Sum of actual file sizes in `Media/` (per item, with `totalBytes` fallback).
    func totalBytesOnDisk() -> Int64 {
        items.reduce(0) { $0 + fileSize(of: $1) }
    }

    /// Recompute and publish `diskUsage` so the UI can react.
    func refreshDiskUsage() {
        diskUsage = totalBytesOnDisk()
    }

    /// Completed downloads sorted by on-disk size, largest first.
    func largestDownloads(limit: Int) -> [DownloadItem] {
        items
            .filter { $0.state == .completed }
            .sorted { fileSize(of: $0) > fileSize(of: $1) }
            .prefix(limit)
            .map { $0 }
    }

    /// Delete every item matching `predicate` (reuses `delete(_:)`).
    @discardableResult
    func deleteMatching(_ predicate: (DownloadItem) -> Bool) -> Int {
        let victims = items.filter(predicate)
        victims.forEach { delete($0) }
        return victims.count
    }

    /// Completed downloads whose page URL is in the watched set.
    func watchedDownloads(isWatched: (String) -> Bool) -> [DownloadItem] {
        items.filter { $0.state == .completed && isWatched($0.pageURL) }
    }

    /// If the total on-disk size exceeds `maxBytes`, delete completed downloads
    /// oldest-first (by `addedAt`) until back under the cap. No-op when `maxBytes <= 0`.
    func enforceCap(maxBytes: Int64) {
        guard maxBytes > 0 else { return }
        var used = totalBytesOnDisk()
        guard used > maxBytes else { return }
        let candidates = items
            .filter { $0.state == .completed }
            .sorted { $0.addedAt < $1.addedAt }
        for item in candidates {
            if used <= maxBytes { break }
            let size = fileSize(of: item)
            delete(item)
            used -= size
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data)
        else { return }
        // Anything left "downloading" from a previous run is stale -> mark failed.
        items = decoded.map { var i = $0; if i.state == .downloading { i.state = .failed }; return i }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: libraryFile, options: .atomic)
        }
    }

    /// `persist: false` for byte-count ticks — the file only needs the state changes.
    private func update(_ item: DownloadItem, persist: Bool = true) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
            if persist { save() }
        }
    }

    private func item(forTask id: Int) -> DownloadItem? {
        guard let uuid = taskToItem[id] else { return nil }
        return items.first { $0.id == uuid }
    }

    // MARK: Notifications

    /// Post a local "download complete" notification, guarded by authorization.
    private func notifyDownloadComplete(title: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Download complete"
            content.body = title
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
            center.add(req, withCompletionHandler: nil)
        }
    }
}

// URLSession delegate callbacks arrive on the session's delegate queue (not main).
extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        let tid = downloadTask.taskIdentifier
        Task { @MainActor in
            let now = Date()
            if let last = self.lastProgressPublish[tid], now.timeIntervalSince(last) < 0.5 { return }
            self.lastProgressPublish[tid] = now
            guard var it = self.item(forTask: tid) else { return }
            it.bytesReceived = totalBytesWritten
            it.totalBytes = totalBytesExpectedToWrite
            self.update(it, persist: false)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        let tid = downloadTask.taskIdentifier
        // The temp file is removed as soon as this method returns, so move it to a stable
        // staging path *synchronously* now, then promote to the final destination on main.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("rezka-\(tid)-\(UUID().uuidString).mp4")
        var moved = false
        do {
            try FileManager.default.moveItem(at: location, to: staging)
            moved = true
        } catch {
            moved = false
        }
        Task { @MainActor in
            guard var it = self.item(forTask: tid) else {
                try? FileManager.default.removeItem(at: staging)
                return
            }
            let dest = self.localURL(for: it)
            try? self.fm.removeItem(at: dest)
            if moved, (try? self.fm.moveItem(at: staging, to: dest)) != nil {
                it.state = .completed
                self.notifyDownloadComplete(title: it.title)
                self.update(it)
                self.refreshDiskUsage()
                // Auto-cleanup oldest completed downloads if we're over the cap.
                self.enforceCap(maxBytes: self.capBytes)
            } else {
                it.state = .failed
                self.update(it)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               didCompleteWithError error: Error?) {
        let tid = task.taskIdentifier
        Task { @MainActor in
            // Intentional pause cancellation: leave the item in .paused, don't fail it.
            if self.pausingTasks.contains(tid) {
                self.taskToItem[tid] = nil
                return
            }
            guard error != nil, var it = self.item(forTask: tid) else {
                self.taskToItem[tid] = nil
                return
            }
            self.taskToItem[tid] = nil
            if it.state != .completed && it.state != .paused { it.state = .failed }
            self.update(it)
        }
    }
}
