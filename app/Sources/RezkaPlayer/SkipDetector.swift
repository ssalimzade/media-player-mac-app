import Foundation
import AVFoundation
import Accelerate
import CryptoKit

/// One episode as an input to intro/credits detection.
struct SkipEpisode: Hashable, Sendable {
    /// `ProgressStore`-style key ("pageURL#S1E2"); markers are stored under it.
    let key: String
    let location: Location

    enum Location: Hashable, Sendable {
        /// A completed download.
        case file(URL)
        /// A stream, resolved on demand (CDN links are short-lived).
        case stream(pageURL: String, season: Int, episode: Int, translator: Int?)
    }

    /// Identity of the audio itself, for the fingerprint cache: a different translation is a
    /// different soundtrack.
    var cacheID: String {
        switch location {
        case .file: return key + "#local"
        case .stream(_, _, _, let t): return key + "#t\(t ?? 0)"
        }
    }
}

/// Finds intros and closing credits by comparing the audio of neighbouring episodes. The opening
/// theme (and usually the end-credits music) is the same recording in every episode of a
/// season, so the longest stretch of audio two episodes share near their start is the intro, and
/// near their end the credits — the approach Plex and Jellyfin use. Fingerprints are a small
/// Philips-style (Haitsma–Kalker) sub-band energy hash computed with Accelerate, so there is
/// nothing extra (ffmpeg, chromaprint) to bundle.
///
/// `AVAssetReader` refuses non-local URLs, so for a streamed episode only the byte ranges that
/// hold the analysed windows are fetched into a sparse local file — the holes take no disk space
/// and the rest of the video is never downloaded. Downloads are read in place.
actor SkipDetector {
    typealias StreamResolver = @MainActor (_ pageURL: String, _ season: Int, _ episode: Int,
                                           _ translator: Int?) async throws -> URL

    private let store: SkipStore
    private let resolveStream: StreamResolver
    private var work: Task<Void, Never>?

    init(store: SkipStore, resolveStream: @escaping StreamResolver) {
        self.store = store
        self.resolveStream = resolveStream
        Self.removeStaleSparseFiles()
    }

    /// Sparse copies are deleted after each run, but a crash mid-run would leave them behind
    /// (tens of MB each). Nothing is running yet when the detector is created, so clear them all.
    private static func removeStaleSparseFiles() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("rezka-skip-") {
            try? fm.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    // MARK: Tunables

    /// Only look for an intro in the first quarter of an episode, and at most this far in.
    static let introWindowMax: Double = 7 * 60
    /// Look for credits in the last fifth of an episode, at most this long.
    static let creditsWindowMax: Double = 4 * 60
    static let introMinLength: Double = 12
    static let introMaxLength: Double = 150
    static let creditsMinLength: Double = 15

    // MARK: Entry point

    /// Make sure `current` (and the episode after it) have markers, comparing against
    /// `neighbours` — ordered by preference, the next episode first. Supersedes any analysis
    /// still running for a previous episode. Cheap when everything is already known.
    func prepare(current: SkipEpisode, neighbours: [SkipEpisode]) {
        let previous = work
        previous?.cancel()
        work = Task {
            await previous?.value
            await self.run(current: current, neighbours: neighbours)
        }
    }

    private func run(current: SkipEpisode, neighbours: [SkipEpisode]) async {
        let session = Session(resolveStream: resolveStream)
        defer { session.close() }

        // 1) The episode being watched, against its neighbours until both parts are settled.
        var introTried = false, creditsTried = false
        for ref in neighbours where !Task.isCancelled {
            let (i, c) = await compare(current, ref, session: session)
            introTried = introTried || i
            creditsTried = creditsTried || c
            if await isSettled(current) { break }
        }
        // Tried every neighbour and found nothing: remember that, so it isn't redone each time.
        let key = current.key
        await store.update(key) { m in
            if introTried { m.introChecked = true }
            if creditsTried { m.creditsChecked = true }
        }

        // 2) Pre-analyse the next episode against this one, so auto-advance has markers ready.
        if let next = neighbours.first, !Task.isCancelled, !(await isSettled(next)) {
            _ = await compare(next, current, session: session)
        }
    }

    private func isSettled(_ ep: SkipEpisode) async -> Bool {
        let m = await store.markers(for: ep.key)
        return (m?.introChecked ?? false) && (m?.creditsChecked ?? false)
    }

    /// Compare two episodes' heads (intro) and tails (credits), storing whatever is found for
    /// both. Returns which comparisons actually ran (both fingerprints available).
    private func compare(_ a: SkipEpisode, _ b: SkipEpisode,
                         session: Session) async -> (intro: Bool, credits: Bool) {
        var ranIntro = false, ranCredits = false
        let ma = await store.markers(for: a.key)

        if !(ma?.introChecked ?? false),
           let pa = await prints(a, .head, session), let pb = await prints(b, .head, session) {
            ranIntro = true
            if let seg = Self.longestShared(pa.bits, pb.bits,
                                            minFrames: Self.frames(Self.introMinLength),
                                            maxFrames: Self.frames(Self.introMaxLength)) {
                let (aStart, aEnd) = Self.span(seg.a, in: pa)
                let (bStart, bEnd) = Self.span(seg.b, in: pb)
                await store.update(a.key) { m in
                    m.introStart = aStart; m.introEnd = aEnd; m.introChecked = true
                }
                if await store.markers(for: b.key)?.intro == nil {
                    await store.update(b.key) { m in
                        m.introStart = bStart; m.introEnd = bEnd; m.introChecked = true
                    }
                }
            }
        }

        if !(ma?.creditsChecked ?? false), !Task.isCancelled,
           let pa = await prints(a, .tail, session), let pb = await prints(b, .tail, session) {
            ranCredits = true
            if let seg = Self.longestShared(pa.bits, pb.bits,
                                            minFrames: Self.frames(Self.creditsMinLength),
                                            maxFrames: Int.max) {
                let aStart = Self.span(seg.a, in: pa).start
                let bStart = Self.span(seg.b, in: pb).start
                await store.update(a.key) { m in m.creditsStart = aStart; m.creditsChecked = true }
                if await store.markers(for: b.key)?.creditsStart == nil {
                    await store.update(b.key) { m in m.creditsStart = bStart; m.creditsChecked = true }
                }
            }
        }
        return (ranIntro, ranCredits)
    }

    // MARK: Fingerprints (cached on disk per episode + soundtrack)

    enum Part: String, Codable { case head, tail }

    struct PartPrint: Codable {
        /// Seconds from the start of the episode where `bits[0]` sits.
        let start: Double
        /// One 32-bit hash per frame; 0 marks a silent frame (never matched).
        let bits: [UInt32]
    }

    private func prints(_ ep: SkipEpisode, _ part: Part, _ session: Session) async -> PartPrint? {
        let cache = Self.cacheURL(ep.cacheID, part)
        if let data = try? Data(contentsOf: cache),
           let p = try? JSONDecoder().decode(PartPrint.self, from: data) {
            return p
        }
        do {
            let media = try await session.media(for: ep)
            let window: (start: Double, length: Double) = {
                let d = media.duration
                switch part {
                case .head: return (0, min(d * 0.25, Self.introWindowMax))
                case .tail:
                    let len = min(d * 0.2, Self.creditsWindowMax)
                    return (max(0, d - len), len)
                }
            }()
            let pcm = try await media.decode(from: window.start, length: window.length)
            let p = PartPrint(start: window.start, bits: Self.fingerprint(pcm))
            guard !p.bits.isEmpty else { return nil }
            if let data = try? JSONEncoder().encode(p) { try? data.write(to: cache, options: .atomic) }
            return p
        } catch {
            return nil
        }
    }

    private static func cacheURL(_ id: String, _ part: Part) -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RezkaPlayer/Fingerprints", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(hash)-\(part.rawValue).json")
    }

    // MARK: Fingerprinting

    static let sampleRate: Double = 11025
    private static let frameSize = 4096          // ~0.37 s
    private static let hop = 1365                // ~0.124 s between frames
    static var hopSeconds: Double { Double(hop) / sampleRate }
    private static let bandCount = 33            // 33 bands → 32 difference bits

    static func frames(_ seconds: Double) -> Int { Int(seconds / hopSeconds) }

    /// Seconds (from the episode start) covered by a matched frame span.
    private static func span(_ r: ClosedRange<Int>, in p: PartPrint) -> (start: Double, end: Double) {
        (p.start + Double(r.lowerBound) * hopSeconds,
         p.start + Double(r.upperBound + 1) * hopSeconds)
    }

    /// Haitsma–Kalker fingerprint: per frame, energies in 33 log-spaced bands (300–2000 Hz);
    /// bit m is the sign of the band-energy difference, differenced again against the previous
    /// frame. Robust to level changes and re-encoding, and cheap to compare (XOR + popcount).
    static func fingerprint(_ x: [Float]) -> [UInt32] {
        let n = frameSize, half = n / 2
        guard x.count >= n + hop else { return [] }
        let log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let binHz = sampleRate / Double(n)
        let edges: [Int] = (0...bandCount).map { k in
            Int(300 * pow(2000.0 / 300.0, Double(k) / Double(bandCount)) / binHz)
        }

        let frameCount = (x.count - n) / hop + 1
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        var prev = [Float](repeating: 0, count: bandCount)
        var cur = [Float](repeating: 0, count: bandCount)
        var bits = [UInt32](repeating: 0, count: frameCount)
        var energy = [Float](repeating: 0, count: frameCount)

        x.withUnsafeBufferPointer { xp in
            for f in 0..<frameCount {
                vDSP_vmul(xp.baseAddress! + f * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                                      &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
                var total: Float = 0
                for b in 0..<bandCount {
                    var s: Float = 0
                    for k in edges[b]..<max(edges[b] + 1, edges[b + 1]) { s += mags[k] }
                    cur[b] = s
                    total += s
                }
                energy[f] = total
                if f > 0 {
                    var v: UInt32 = 0
                    for m in 0..<(bandCount - 1) {
                        let d = (cur[m] - cur[m + 1]) - (prev[m] - prev[m + 1])
                        if d > 0 { v |= 1 << UInt32(m) }
                    }
                    bits[f] = v
                }
                swap(&prev, &cur)
            }
        }

        // Silence (and near-silence) hashes to noise or all-zeros; blank it so two quiet
        // stretches never count as "shared audio".
        let sorted = energy.sorted()
        let floor = max(sorted[sorted.count / 2] * 0.001, .leastNormalMagnitude)
        for f in 0..<frameCount where energy[f] < floor { bits[f] = 0 }
        bits[0] = 0
        return bits
    }

    // MARK: Matching

    struct Shared { let a: ClosedRange<Int>; let b: ClosedRange<Int> }

    /// Longest stretch of audio the two fingerprints share, at any time offset. A frame pair
    /// matches when ≤10 of 32 bits differ (unrelated audio: ~16); a run tolerates ~1.5 s gaps
    /// (a voice-over line across the theme) but must be at least half matches.
    static func longestShared(_ a: [UInt32], _ b: [UInt32], minFrames: Int, maxFrames: Int) -> Shared? {
        let maxBits = 10, maxGap = 12
        var best: Shared?
        var bestLen = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                for shift in -(b.count - 1)..<a.count {           // a[i] ↔ b[i - shift]
                    let lo = max(0, shift), hi = min(a.count, b.count + shift)
                    guard hi - lo >= minFrames else { continue }
                    var start = -1, last = -1, hits = 0
                    var i = lo
                    while i <= hi {
                        let isHit: Bool
                        if i < hi {
                            let x = ap[i], y = bp[i - shift]
                            isHit = x != 0 && y != 0 && (x ^ y).nonzeroBitCount <= maxBits
                        } else {
                            isHit = false
                        }
                        // A run ends at the end of the overlap, or once the gap since its last
                        // hit grows past `maxGap`.
                        if start >= 0 && (i == hi || i - last > maxGap) {
                            let len = last - start + 1
                            if len >= minFrames, len <= maxFrames, hits * 2 >= len, len > bestLen {
                                bestLen = len
                                best = Shared(a: start...last, b: (start - shift)...(last - shift))
                            }
                            start = -1
                        }
                        if isHit {
                            if start < 0 { start = i; hits = 0 }
                            last = i
                            hits += 1
                        }
                        i += 1
                    }
                }
            }
        }
        return best
    }
}

// MARK: - Media access

extension SkipDetector {
    enum Failure: Error { case noAudio, noRangeSupport, unreadable }

    /// Opened media for one analysis run: streams become sparse temp files that are reused
    /// between the head and tail passes, then deleted.
    final class Session {
        private let resolveStream: StreamResolver
        private var opened: [String: Media] = [:]

        init(resolveStream: @escaping StreamResolver) { self.resolveStream = resolveStream }

        func media(for ep: SkipEpisode) async throws -> Media {
            if let m = opened[ep.cacheID] { return m }
            let m: Media
            switch ep.location {
            case .file(let url):
                m = try await Media.local(url)
            case .stream(let page, let s, let e, let t):
                let remote = try await resolveStream(page, s, e, t)
                m = try await Media.sparse(remote)
            }
            opened[ep.cacheID] = m
            return m
        }

        func close() {
            for m in opened.values { m.discard() }
            opened.removeAll()
        }
    }

    final class Media {
        let fileURL: URL
        let duration: Double
        private let asset: AVURLAsset     // held strongly: a track only weakly references it
        private let track: AVAssetTrack
        private let remote: URL?          // set for sparse copies of a stream
        private let totalBytes: Int64
        private var fetched: [ClosedRange<Int64>] = []

        private init(fileURL: URL, duration: Double, asset: AVURLAsset, track: AVAssetTrack,
                     remote: URL?, totalBytes: Int64, fetched: [ClosedRange<Int64>]) {
            self.fileURL = fileURL; self.duration = duration; self.asset = asset; self.track = track
            self.remote = remote; self.totalBytes = totalBytes; self.fetched = fetched
        }

        static func local(_ url: URL) async throws -> Media {
            let (asset, track, d) = try await open(url)
            return Media(fileURL: url, duration: d, asset: asset, track: track,
                         remote: nil, totalBytes: 0, fetched: [])
        }

        /// A same-size local file holding just the container header (moov) of `remote`; the
        /// sample data is filled in per analysis window by `decode`.
        static func sparse(_ remote: URL) async throws -> Media {
            let probe: Int64 = 4 << 20
            let (head, total) = try await fetch(remote, 0...(probe - 1))
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("rezka-skip-\(UUID().uuidString).mp4")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let fh = try FileHandle(forWritingTo: file)
            try fh.truncate(atOffset: UInt64(total))
            try fh.seek(toOffset: 0)
            try fh.write(contentsOf: head)
            var fetched = [0...Int64(head.count - 1)]

            // moov is usually up front ("fast start"); if not, it's at the end.
            var opened = try? await open(file)
            if opened == nil, total > probe {
                let range = (total - probe)...(total - 1)
                let (tail, _) = try await fetch(remote, range)
                try fh.seek(toOffset: UInt64(range.lowerBound))
                try fh.write(contentsOf: tail)
                fetched.append(range)
                opened = try? await open(file)
            }
            try fh.close()
            guard let (asset, track, d) = opened else {
                try? FileManager.default.removeItem(at: file)
                throw Failure.unreadable
            }
            return Media(fileURL: file, duration: d, asset: asset, track: track, remote: remote,
                         totalBytes: total, fetched: fetched)
        }

        private static func open(_ file: URL) async throws -> (AVURLAsset, AVAssetTrack, Double) {
            let asset = AVURLAsset(url: file)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw Failure.noAudio
            }
            let d = try await asset.load(.duration).seconds
            guard d.isFinite, d > 0 else { throw Failure.unreadable }
            return (asset, track, d)
        }

        /// Optional trace of range fetches and retries (unset in the app; diagnostics set it).
        static var log: ((String) -> Void)?

        /// Mono float PCM at `sampleRate` for [start, start + length).
        func decode(from start: Double, length: Double) async throws -> [Float] {
            guard remote != nil else { return try read(from: start, length: length) }
            try await fill(from: start, to: start + length, generous: false)
            do {
                return try read(from: start, length: length)
            } catch {
                // The sample table's offsets fell short somewhere: take a generous,
                // bitrate-proportional range around the window and try once more.
                Self.log?("decode \(Int(start))s+\(Int(length))s failed (\(error.localizedDescription)); widening")
                try await fill(from: start, to: start + length, generous: true)
                return try read(from: start, length: length)
            }
        }

        private func read(from start: Double, length: Double) throws -> [Float] {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: SkipDetector.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            out.alwaysCopiesSampleData = false
            reader.add(out)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                           duration: CMTime(seconds: length, preferredTimescale: 600))
            guard reader.startReading() else { throw reader.error ?? Failure.unreadable }
            var pcm: [Float] = []
            pcm.reserveCapacity(Int(length * SkipDetector.sampleRate) + 8192)
            while let sb = out.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                let bytes = CMBlockBufferGetDataLength(block)
                let old = pcm.count
                pcm.append(contentsOf: repeatElement(0, count: bytes / 4))
                pcm.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: (bytes / 4) * 4,
                                                   destination: raw.baseAddress! + old * 4)
                }
            }
            if reader.status == .failed, pcm.isEmpty { throw reader.error ?? Failure.unreadable }
            return pcm
        }

        /// Fetch the bytes holding audio for [t0, t1] into the sparse file. The sample table
        /// says exactly where those audio chunks live; the video interleaved between them comes
        /// along, but nothing outside the window does.
        private func fill(from t0: Double, to t1: Double, generous: Bool) async throws {
            guard let remote else { return }
            var lo: Int64, hi: Int64
            // Asking for the sample at exactly the end can land anywhere; stay inside the track.
            let end = min(t1, duration - 0.5)
            if !generous,
               let c0 = track.makeSampleCursor(presentationTimeStamp: CMTime(seconds: t0, preferredTimescale: 600)),
               let c1 = track.makeSampleCursor(presentationTimeStamp: CMTime(seconds: end, preferredTimescale: 600)),
               c1.currentChunkStorageRange.offset >= c0.currentChunkStorageRange.offset {
                let r0 = c0.currentChunkStorageRange, r1 = c1.currentChunkStorageRange
                lo = r0.offset - (1 << 20)          // slack for interleaving / decoder priming
                hi = r1.offset + r1.length + (1 << 20)
            } else {
                // No usable sample cursor (or a retry): estimate from the average bitrate.
                let bps = Double(totalBytes) / duration
                lo = Int64(t0 * bps * 0.8) - (4 << 20)
                hi = Int64(t1 * bps * 1.2) + (4 << 20)
            }
            if t1 >= duration - 1 { hi = totalBytes - 1 }   // a window at the end takes the rest
            lo = max(0, lo); hi = min(totalBytes - 1, max(lo, hi))
            Self.log?("fill \(Int(t0))–\(Int(t1))s → bytes \(lo)–\(hi) (\((hi - lo) >> 20) MB)\(generous ? " generous" : "")")

            // Skip what's already on disk (the moov probe, or an overlapping earlier window).
            for gap in missing(lo...hi) {
                try Task.checkCancellation()
                let (data, _) = try await Self.fetch(remote, gap)
                let fh = try FileHandle(forWritingTo: fileURL)
                try fh.seek(toOffset: UInt64(gap.lowerBound))
                try fh.write(contentsOf: data)
                try fh.close()
                fetched.append(gap.lowerBound...(gap.lowerBound + Int64(data.count) - 1))
            }
        }

        private func missing(_ want: ClosedRange<Int64>) -> [ClosedRange<Int64>] {
            var gaps: [ClosedRange<Int64>] = []
            var cursor = want.lowerBound
            for r in fetched.sorted(by: { $0.lowerBound < $1.lowerBound }) where r.upperBound >= cursor {
                if r.lowerBound > want.upperBound { break }
                if r.lowerBound > cursor { gaps.append(cursor...(r.lowerBound - 1)) }
                cursor = max(cursor, r.upperBound + 1)
                if cursor > want.upperBound { break }
            }
            if cursor <= want.upperBound { gaps.append(cursor...want.upperBound) }
            return gaps
        }

        /// One HTTP Range request. Returns the bytes and the resource's total size.
        private static func fetch(_ url: URL, _ range: ClosedRange<Int64>) async throws -> (Data, Int64) {
            var req = URLRequest(url: url)
            req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            // HDRezka's CDN expects a browser-like User-Agent (harmless for the local relay).
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                         + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 60
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 206,
                  let cr = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = Int64(cr.split(separator: "/").last ?? "") else {
                throw Failure.noRangeSupport
            }
            return (data, total)
        }

        func discard() {
            if remote != nil { try? FileManager.default.removeItem(at: fileURL) }
        }
    }
}
