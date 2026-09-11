import Foundation
import Network
import SystemConfiguration

/// The phone remote's transport: a tiny HTTP/1.1 server on the LAN (Network.framework, one
/// request per connection) that hands each request to a main-actor handler (`PhoneRemote`).
/// It listens on a fixed port so a phone's bookmark keeps working across launches, moving up a
/// port or two only if that one's taken.
final class RemoteServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    struct Response {
        var status = 200
        var type = "application/json"
        var body = Data()

        static func json<T: Encodable>(_ value: T) -> Response {
            Response(body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
        }
        static func html(_ page: String) -> Response {
            Response(type: "text/html; charset=utf-8", body: Data(page.utf8))
        }
        static func text(_ status: Int, _ message: String) -> Response {
            Response(status: status, type: "text/plain; charset=utf-8", body: Data(message.utf8))
        }
    }

    static let preferredPort: UInt16 = 47821

    private let queue = DispatchQueue(label: "RezkaPlayer.RemoteServer")
    private var listener: NWListener?
    private let handler: @MainActor (Request) -> Response
    private let onPort: @MainActor (UInt16?) -> Void

    /// `onPort` reports the port once listening (nil if no port could be had).
    init(handler: @escaping @MainActor (Request) -> Response,
         onPort: @escaping @MainActor (UInt16?) -> Void) {
        self.handler = handler
        self.onPort = onPort
    }

    func start() { queue.async { self.listen(on: Self.preferredPort, attempts: 10) } }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    /// This Mac's Bonjour name (e.g. "Samirs-MacBook-Air.local"), which stays valid when the
    /// LAN IP changes.
    static var bonjourHost: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
    }

    // MARK: Listening

    private func listen(on port: UInt16, attempts: Int) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: params, on: nwPort) else { return report(nil) }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.report(port)
            case .failed:
                l?.cancel()
                if attempts > 1 { self.listen(on: port + 1, attempts: attempts - 1) } else { self.report(nil) }
            default:
                break
            }
        }
        l.start(queue: queue)
    }

    private func report(_ port: UInt16?) {
        let onPort = onPort
        Task { @MainActor in onPort(port) }
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return c.cancel() }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = Self.parse(buf) {
                let handler = self.handler
                Task { @MainActor in
                    let response = handler(request)
                    self.send(response, on: c)
                }
            } else if done || error != nil || buf.count > 256 * 1024 {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    /// A complete request from `data`, or nil while headers/body are still arriving.
    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return nil }
        let url = URLComponents(string: "http://remote" + parts[1])
        var query: [String: String] = [:]
        url?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        return Request(method: String(parts[0]), path: url?.path ?? "/", query: query,
                       body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private func send(_ r: Response, on c: NWConnection) {
        let reason = [200: "OK", 403: "Forbidden", 404: "Not Found"][r.status] ?? "Error"
        var out = Data(("HTTP/1.1 \(r.status) \(reason)\r\n"
                        + "Content-Type: \(r.type)\r\n"
                        + "Content-Length: \(r.body.count)\r\n"
                        + "Cache-Control: no-store\r\n"
                        + "Connection: close\r\n\r\n").utf8)
        out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
