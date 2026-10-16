import Foundation

/// Where the episode really is — and whether to believe what the player reports.
///
/// Over AirPlay the receiver, not this Mac, fetches and plays the URL. When its session lapses
/// (a Fire TV drops it after a pause, and minutes before it gets round to saying so) it simply
/// re-fetches from byte 0 on resume, and the playhead reappears at 0:00 with nothing to announce
/// it. Taking that at face value is what lost people's place and restarted episodes from the top.
///
/// So every observation of the playhead goes through `observe`, which keeps `lastPlaying` — the
/// last position seen while playback was genuinely running — and says when a jump to the start
/// was not asked for. It is a plain reference box on purpose: a `@State` struct would invalidate
/// the SwiftUI view on every tick.
///
/// Held per episode; `reset()` between them.
final class Playhead {
    enum Verdict: Equatable {
        /// The reported position is real.
        case believe
        /// The stream went back to the start by itself. Seek back to this position.
        case putBack(to: Double)
    }

    /// Positions below this count as "at the very start of the episode".
    static let topOfEpisode: Double = 5
    /// Only a minute or more of watching is worth defending; below that, a jump to the start
    /// costs nothing to sit through.
    static let worthKeeping: Double = 60
    /// How long the playhead must sit at the start, paused, to read as a deliberate rewind.
    /// A stream that restarts itself blips through the start and plays on; someone who scrubbed
    /// there leaves it sitting.
    static let deliberateRewindDwell: TimeInterval = 1.5
    /// Back at the start this soon after a put-back that *worked* means the viewer dragged it
    /// there again: a receiver that has just honoured a seek has a live session and no reason to
    /// restart. (Its restarts come after its session lapses — minutes of pause.)
    static let insistWindow: TimeInterval = 20
    /// Put-backs the receiver may refuse (never land) before we stop trying.
    static let putBackBudget = 3
    /// Ordinary playback for this long earns the budget back.
    static let budgetRenewedAfter: TimeInterval = 60
    /// How long a seek we asked for may take to land (a TV can be slow) before being judged.
    static let seekSettles: TimeInterval = 8
    /// How close to its target a seek must read to count as landed.
    static let landedWithin: Double = 3

    /// The last position seen while playback was actually running: where the episode really is.
    private(set) var lastPlaying: Double = 0
    /// This item has played over AirPlay at some point — it stays set for the rest of the episode,
    /// because a receiver drops the session *before* reporting its fake end (seen minutes apart),
    /// so "are we on AirPlay right now?" says nothing about who sent the end.
    var onAirPlay = false
    /// Where the playhead stands while paused, and since when it has been sitting near the start.
    private(set) var pausedAt: Double?
    private(set) var sittingAtTopSince: Date?
    /// A seek we asked for and haven't yet seen land. Until it does, nothing reported is learned:
    /// a TV mid-seek can still read 0:00, and learning that would erase the place we're restoring.
    private var seek: (target: Double, deadline: Date, isPutBack: Bool)?
    private(set) var putBacks = 0
    private var lastPutBackAt = Date.distantPast
    private var lastPutBackLandedAt = Date.distantPast
    /// The last end we disbelieved (AVFoundation can post the notification twice for one item).
    var lastDisbelievedEnd = Date.distantPast
    /// Something worth writing to the player log, set by the last `observe`. Read and clear it.
    var note: String?

    func reset() {
        lastPlaying = 0
        onAirPlay = false
        pausedAt = nil
        sittingAtTopSince = nil
        seek = nil
        putBacks = 0
        lastPutBackAt = .distantPast
        lastPutBackLandedAt = .distantPast
        lastDisbelievedEnd = .distantPast
        note = nil
    }

    /// Call right before any seek this app initiates, with where it's going.
    func expectSeek(to target: Double, now: Date = Date()) {
        seek = (max(0, target), now.addingTimeInterval(Self.seekSettles), false)
    }

    /// A seek to a spot the viewer chose (the phone remote): that *is* where the episode is now,
    /// even if they chose the very start.
    func movedOnPurpose(to position: Double, now: Date = Date()) {
        lastPlaying = max(0, position)
        expectSeek(to: position, now: now)
    }

    /// Every observation of the playhead goes through here.
    func observe(position: Double, playing: Bool, now: Date = Date()) -> Verdict {
        note = nil
        if let s = seek {
            if abs(position - s.target) < Self.landedWithin {
                // Landed: where we sent it is where the episode is now, even near the start.
                seek = nil
                lastPlaying = position
                if s.isPutBack { lastPutBackLandedAt = now }
            } else if now < s.deadline {
                return .believe                                     // in flight: learn nothing
            } else {
                seek = nil
                // Our put-back never took and it's still far behind: the receiver refused it.
                if s.isPutBack, playing, position < s.target - 30 {
                    return putBack(from: position, now: now, why: "the last put-back didn't take")
                }
            }
        }

        guard playing else {
            pausedAt = position
            if position < Self.topOfEpisode {
                if sittingAtTopSince == nil { sittingAtTopSince = now }
            } else {
                sittingAtTopSince = nil
            }
            return .believe
        }

        // Taking the new position as gospel would erase where we were, so check it first.
        if looksRestarted(at: position) {
            if let since = sittingAtTopSince, now.timeIntervalSince(since) > Self.deliberateRewindDwell {
                note = "playing from \(Self.stamp(position)) after sitting there — a deliberate rewind"
            } else if now.timeIntervalSince(lastPutBackLandedAt) < Self.insistWindow {
                note = "back at \(Self.stamp(position)) right after being put back — taken as meant"
            } else {
                return putBack(from: position, now: now, why: nil)
            }
        }
        lastPlaying = position
        sittingAtTopSince = nil
        // A stretch of ordinary playback earns the budget back, so a restart much later is still
        // caught — without letting a receiver stuck at 0:00 loop forever.
        if putBacks > 0, position > Self.worthKeeping,
           now.timeIntervalSince(lastPutBackAt) > Self.budgetRenewedAfter {
            putBacks = 0
        }
        return .believe
    }

    private func putBack(from position: Double, now: Date, why: String?) -> Verdict {
        guard putBacks < Self.putBackBudget else {
            note = "back at \(Self.stamp(position)) again — \(Self.putBackBudget) put-backs spent,"
                + " leaving it there"
            lastPlaying = position
            sittingAtTopSince = nil
            return .believe
        }
        putBacks += 1
        lastPutBackAt = now
        sittingAtTopSince = nil
        seek = (lastPlaying, now.addingTimeInterval(Self.seekSettles), true)
        note = "playback reappeared at \(Self.stamp(position)) — it was at \(Self.stamp(lastPlaying))"
            + "; putting it back (\(putBacks) of \(Self.putBackBudget)"
            + (why.map { ", \($0)" } ?? "") + ")"
        return .putBack(to: lastPlaying)
    }

    /// At the start of the episode with real watching behind it — suspicious wherever it came
    /// from, and never a position worth saving as the resume point.
    func looksRestarted(at position: Double) -> Bool {
        onAirPlay && position < Self.topOfEpisode && lastPlaying > Self.worthKeeping
    }

    /// The position worth saving. While a seek we asked for is still landing, where it's going;
    /// while the stream sits at the start after restarting itself, where it was. Either way the
    /// 0:00 a TV reads meanwhile is a lie the resume point must not learn.
    func trustedPosition(_ position: Double) -> Double {
        if let s = seek { return s.target }
        return looksRestarted(at: position) ? lastPlaying : position
    }

    private static func stamp(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
