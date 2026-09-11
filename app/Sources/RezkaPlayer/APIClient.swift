import Foundation

/// Thin async client over the local sidecar's JSON endpoints.
final class APIClient {
    private let sidecar: SidecarManager
    /// Returns the currently configured HDRezka mirror origin (e.g. https://hdrezka.ag).
    private let originProvider: @MainActor () -> String
    /// Returns the current HDRezka session cookies (empty when logged out).
    private let cookiesProvider: @MainActor () -> [String: String]

    init(sidecar: SidecarManager,
         originProvider: @escaping @MainActor () -> String,
         cookiesProvider: @escaping @MainActor () -> [String: String] = { [:] }) {
        self.sidecar = sidecar
        self.originProvider = originProvider
        self.cookiesProvider = cookiesProvider
    }

    // MARK: Endpoints

    struct ConfigResponse: Decodable { let ok: Bool; let proxy: Bool }

    /// Set the sidecar's process-wide proxy ("" clears it). Returns whether a proxy is active.
    @discardableResult
    func configure(proxy: String) async throws -> Bool {
        let r: ConfigResponse = try await post("/config", ["proxy": proxy])
        return r.proxy
    }

    func search(_ query: String, advanced: Bool = false, page: Int = 1) async throws -> [CatalogueItem] {
        let body: [String: Any] = ["query": query, "find_all": advanced, "page": page]
        let r: SearchResponse = try await post("/search", body)
        return r.results
    }

    func browse(collection: String, category: String, page: Int = 1,
                genre: String? = nil, year: Int? = nil, sort: String? = nil) async throws -> [CatalogueItem] {
        var body: [String: Any] = ["collection": collection, "category": category, "page": page]
        if let genre { body["genre"] = genre }
        if let year { body["year"] = year }
        if let sort { body["sort"] = sort }
        let r: BrowseResponse = try await post("/browse", body)
        return r.results
    }

    /// Title metadata. For a series, `translation` picks whose episode list comes back (each
    /// translation has its own); the sidecar falls back to the page's default translator.
    func info(url: String, translation: Int? = nil) async throws -> TitleInfo {
        var body: [String: Any] = ["url": url]
        if let translation { body["translation"] = translation }
        return try await post("/info", body)
    }

    struct LoginResponse: Decodable {
        let ok: Bool
        var cookies: [String: String]?
        var message: String?
    }

    /// Log into HDRezka. On success the returned `cookies` should be persisted and sent
    /// on subsequent requests. `origin` overrides the default mirror when provided.
    func login(origin: String? = nil, email: String, password: String) async throws -> LoginResponse {
        var body: [String: Any] = ["email": email, "password": password]
        if let origin { body["origin"] = origin }
        return try await post("/login", body)
    }

    func stream(url: String, translation: Int? = nil, season: Int? = nil, episode: Int? = nil) async throws -> StreamResponse {
        var body: [String: Any] = ["url": url]
        if let translation { body["translation"] = translation }
        if let season { body["season"] = season }
        if let episode { body["episode"] = episode }
        return try await post("/stream", body)
    }

    struct WarmResponse: Decodable { let ok: Bool }

    /// Have the sidecar resolve a CDN link's redirect and open a connection to its storage node
    /// before the player asks for it. Returns at once; the work happens in the background.
    func warm(url: String) async throws {
        let _: WarmResponse = try await post("/warm", ["url": url])
    }

    // MARK: Plumbing

    private func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        let (base, token, origin, cookies) = try await MainActor.run { () -> (URL, String, String, [String: String]) in
            guard let base = sidecar.baseURL else { throw APIError.notReady }
            return (base, sidecar.token, originProvider(), cookiesProvider())
        }

        var payload = body
        if payload["origin"] == nil { payload["origin"] = origin }
        if payload["cookies"] == nil, !cookies.isEmpty { payload["cookies"] = cookies }

        var req = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 45

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(code) {
            if let err = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw APIError.server(err.error, type: err.type)
            }
            throw APIError.server("HTTP \(code)", type: nil)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.transport("Bad response: \(error.localizedDescription)")
        }
    }
}
