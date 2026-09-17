import Foundation
import Combine

/// Spawns and supervises the Python sidecar that does all HDRezka scraping.
///
/// The app launches `server.py` on 127.0.0.1 with port 0 (OS-assigned), reads the
/// `SIDECAR_READY host=.. port=..` line it prints, and then talks to it over HTTP.
/// A random per-launch token is passed via env and required on every request.
@MainActor
final class SidecarManager: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case ready(port: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    /// Shared secret required by the sidecar (X-Auth-Token header).
    let token = UUID().uuidString

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?

    var baseURL: URL? {
        if case .ready(let port) = state {
            return URL(string: "http://127.0.0.1:\(port)")
        }
        return nil
    }

    /// The bound port once ready (used to build LAN-reachable relay URLs for AirPlay).
    var port: Int? {
        if case .ready(let p) = state { return p }
        return nil
    }

    // MARK: Resolved paths (overridable in Settings)

    static var defaultSidecarDir: String {
        if let v = UserDefaults.standard.string(forKey: "sidecarDir"), !v.isEmpty { return v }
        // Dev default: this checkout's sidecar/ folder, derived from where this file sat at
        // compile time, so a source build works on any machine without per-dev setup. (It used
        // to be one developer's absolute home path, which left every other checkout with a dead
        // sidecar and a silent "Nothing here yet".) Release builds prefer the bundled frozen
        // sidecar and never reach this; override via Settings → Sidecar folder if needed.
        let repoRoot = URL(fileURLWithPath: #filePath)   // <repo>/app/Sources/RezkaPlayer/Sidecar.swift
            .deletingLastPathComponent()                 // <repo>/app/Sources/RezkaPlayer
            .deletingLastPathComponent()                 // <repo>/app/Sources
            .deletingLastPathComponent()                 // <repo>/app
            .deletingLastPathComponent()                 // <repo>
        return repoRoot.appendingPathComponent("sidecar").path
    }

    private var sidecarDir: String { Self.defaultSidecarDir }

    private var pythonPath: String {
        if let v = UserDefaults.standard.string(forKey: "pythonPath"), !v.isEmpty { return v }
        let venv = (sidecarDir as NSString).appendingPathComponent(".venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: venv) { return venv }
        return "/usr/bin/env"   // will resolve `python3` from PATH
    }

    private var serverScript: String {
        (sidecarDir as NSString).appendingPathComponent("server.py")
    }

    // MARK: Lifecycle

    /// A frozen sidecar binary bundled in the .app (distribution builds), if present.
    private var bundledSidecarExe: String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let path = res.appendingPathComponent("sidecar/rezka-sidecar/rezka-sidecar").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    func start() {
        guard process == nil else { return }

        // Prefer the bundled frozen sidecar (distribution); otherwise run from source via the
        // dev venv/python (development). This is what makes a shipped .app self-contained.
        let exe: String
        let args: [String]
        // Bind on 0.0.0.0 (not just loopback) so an AirPlay receiver (Apple TV / smart TV) can
        // reach the /relay endpoint over the LAN and pull video through this Mac. Every endpoint
        // is token-guarded (X-Auth-Token / the relay's `t` param), so LAN exposure stays gated.
        if let bundled = bundledSidecarExe {
            exe = bundled
            args = ["--host", "0.0.0.0", "--port", "0"]
        } else {
            guard FileManager.default.fileExists(atPath: serverScript) else {
                state = .failed("Sidecar not found at \(serverScript). Set the path in Settings.")
                return
            }
            let py = pythonPath
            if py == "/usr/bin/env" {
                exe = py
                args = ["python3", serverScript, "--host", "0.0.0.0", "--port", "0"]
            } else {
                exe = py
                args = [serverScript, "--host", "0.0.0.0", "--port", "0"]
            }
        }
        state = .starting

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["REZKA_SIDECAR_TOKEN"] = token
        env["PYTHONUNBUFFERED"] = "1"
        env["REZKA_SIDECAR_MANAGED"] = "1"   // enables the stdin-EOF watchdog in server.py
        proc.environment = env

        let out = Pipe(); let err = Pipe(); let inn = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // We keep the write end of stdin open; if the app dies, it closes and the
        // sidecar's stdin watchdog sees EOF and exits (no orphaned Python).
        proc.standardInput = inn
        self.stdoutPipe = out
        self.stderrPipe = err
        self.stdinPipe = inn

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.handleStdout(line) }
        }

        // Drain stderr and discard. The sidecar logs a line per HTTP request; if nobody reads the
        // pipe it fills (~64 KB) and the sidecar blocks on write — which stalls playback, since
        // streaming a video issues hundreds of Range requests.
        err.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                self?.process = nil
                if case .ready = self?.state {
                    self?.state = .failed("Helper exited (code \(p.terminationStatus)).")
                } else if case .starting = self?.state {
                    self?.state = .failed("Helper failed to start (code \(p.terminationStatus)).")
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
        } catch {
            state = .failed("Could not launch Python: \(error.localizedDescription)")
        }
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        stdinPipe = nil
        state = .stopped
    }

    /// Restart, e.g. after the user changes the sidecar path in Settings.
    func restart() {
        stop()
        start()
    }

    private func handleStdout(_ chunk: String) {
        for line in chunk.split(separator: "\n") {
            if line.hasPrefix("SIDECAR_READY") {
                // SIDECAR_READY host=127.0.0.1 port=54321
                if let portTok = line.split(separator: " ").first(where: { $0.hasPrefix("port=") }),
                   let port = Int(portTok.dropFirst("port=".count)) {
                    self.state = .ready(port: port)
                }
            }
        }
    }
}
