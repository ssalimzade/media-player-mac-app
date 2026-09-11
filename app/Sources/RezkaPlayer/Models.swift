import Foundation

// MARK: - Shared small types

struct HdType: Codable, Hashable {
    let name: String?
    let type: String?
}

struct Rating: Codable, Hashable {
    let value: Double
    let votes: Int?
}

// MARK: - Catalogue / search items

/// One poster in a catalogue grid or search result list.
struct CatalogueItem: Codable, Hashable, Identifiable {
    let title: String
    let url: String
    var image: String?
    var rating: Double?
    var category: HdType?
    var info: String?
    var postId: String?      // HDRezka post id when available

    /// Stable SwiftUI identity (the page URL is unique).
    var id: String { url }

    enum CodingKeys: String, CodingKey {
        case title, url, image, rating, category, info
        case postId = "id"
    }
}

struct SearchResponse: Codable { let results: [CatalogueItem] }
struct BrowseResponse: Codable { let results: [CatalogueItem] }

// MARK: - Title details

struct Translator: Codable, Hashable, Identifiable {
    let id: Int
    // HDRezka's default/original audio track can come back with no translator name;
    // keep it optional so a null doesn't fail decoding the whole title.
    let name: String?
    let premium: Bool

    /// Non-empty label for the picker (falls back when HDRezka omits the name).
    var displayName: String {
        let n = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "Original" : n
    }
}

struct EpisodeTranslation: Codable, Hashable {
    let translator_id: Int
    var translator_name: String?
    let premium: Bool
}

struct EpisodeInfo: Codable, Hashable, Identifiable {
    let episode: Int
    let episode_text: String
    let translations: [EpisodeTranslation]
    var id: Int { episode }
}

struct SeasonInfo: Codable, Hashable, Identifiable {
    let season: Int
    let season_text: String
    let episodes: [EpisodeInfo]
    var id: Int { season }
}

struct TitleInfo: Codable, Hashable {
    let id: Int
    let url: String
    let name: String
    var names: [String]?
    var origName: String?
    var description: String?
    var thumbnail: String?
    var thumbnailHQ: String?
    var releaseYear: Int?
    var type: HdType?
    var category: HdType?
    var rating: Rating?
    let isSeries: Bool
    var translators: [Translator]
    var episodes: [SeasonInfo]?
    /// Whose episode list `episodes` is (series only) — the sidecar lists one translator's at a
    /// time, as fetching every translator's cost a request each.
    var episodesTranslator: Int?
    var similar: [CatalogueItem]?
}

// MARK: - Streams

struct Subtitle: Codable, Hashable, Identifiable {
    let code: String
    let title: String
    let link: String
    var id: String { code }
}

struct StreamResponse: Codable {
    var name: String?
    var season: Int?
    var episode: Int?
    var translatorId: Int?
    /// quality label -> list of mirror URLs, e.g. "720p": ["https://.../720.mp4"]
    var videos: [String: [String]]
    var subtitles: [Subtitle]

    /// Resolutions sorted ascending by their numeric height.
    var sortedQualities: [String] {
        videos.keys.sorted { Quality.height($0) < Quality.height($1) }
    }

    /// Best (highest) resolution URL.
    func bestURL() -> (quality: String, url: String)? {
        guard let q = sortedQualities.last, let u = videos[q]?.first else { return nil }
        return (q, u)
    }

    func url(for quality: String) -> String? { videos[quality]?.first }
}

enum Quality {
    /// A comparable height for a quality label. HDRezka mixes styles: "720p", "1080p Ultra"
    /// (ranked just above plain 1080p), and "2K"/"4K" (1440/2160 — reading only the leading
    /// digits sorted those *below* 360p, so "best" and "lowest" picked the wrong streams).
    static func height(_ label: String) -> Int {
        let digits = Int(label.prefix { $0.isNumber }) ?? 0
        let rest = label.drop { $0.isNumber }.trimmingCharacters(in: .whitespaces).lowercased()
        var h = digits
        if rest.hasPrefix("k") { h = digits == 2 ? 1440 : digits * 540 }   // 4K → 2160, 8K → 4320
        if rest.contains("ultra") { h += 1 }
        return h
    }
}

// MARK: - API error envelope

struct APIErrorBody: Codable {
    let error: String
    var type: String?
}

enum APIError: LocalizedError {
    case server(String, type: String?)
    case transport(String)
    case notReady

    var errorDescription: String? {
        switch self {
        case .server(let m, let t): return t.map { "\($0): \(m)" } ?? m
        case .transport(let m): return m
        case .notReady: return "The HDRezka helper isn't running yet."
        }
    }
}
