import Foundation
import Combine

/// Detected intro / closing-credits positions per episode, keyed like `ProgressStore`
/// ("pageURL#S1E2"), persisted to Application Support/RezkaPlayer/skipmarkers.json.
/// Written by `SkipDetector`; read by the player to auto-skip.
@MainActor
final class SkipStore: ObservableObject {
    struct Markers: Codable, Hashable {
        /// Intro span, in seconds from the start of the episode, when one was found.
        var introStart: Double?
        var introEnd: Double?
        /// Where the closing credits begin (seconds from the start), when found.
        var creditsStart: Double?
        /// Set once detection has run to completion (found or not) so it isn't redone on
        /// every playback. A network failure leaves these false so it's retried next time.
        var introChecked: Bool
        var creditsChecked: Bool
        /// Neighbouring episodes this one's intro has been compared with (their keys) — see
        /// `SkipDetector.introPairsWanted`.
        var introPairs: [String]?
        /// Every neighbour on offer was tried without reaching that many.
        var introExhausted: Bool?
        var updatedAt: Date
        /// The detector revision that found these. Older markers are dropped on load and found
        /// again — from the cached fingerprints, so that downloads nothing.
        var version: Int?
        static let currentVersion = 2

        init() {
            introChecked = false
            creditsChecked = false
            updatedAt = Date()
        }

        var intro: ClosedRange<Double>? {
            guard let s = introStart, let e = introEnd, e > s else { return nil }
            return s...e
        }
    }

    @Published private(set) var items: [String: Markers] = [:]
    private let fm = FileManager.default

    init() { load() }

    func markers(for key: String) -> Markers? { items[key] }

    func update(_ key: String, _ change: (inout Markers) -> Void) {
        var m = items[key] ?? Markers()
        change(&m)
        m.updatedAt = Date()
        m.version = Markers.currentVersion
        items[key] = m
        save()
    }

    /// Forget everything detected for an episode (it'll be re-detected on next playback).
    func reset(_ key: String) {
        items[key] = nil
        save()
    }

    // MARK: Persistence

    private var file: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RezkaPlayer", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("skipmarkers.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: Markers].self, from: data) else { return }
        items = decoded.filter { $0.value.version == Markers.currentVersion }
        if items.count != decoded.count { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
