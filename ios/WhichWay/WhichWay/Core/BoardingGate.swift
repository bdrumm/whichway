import Foundation

// No single sensor reading puts the rider on a train. A pull-away felt in the pocket is a claim; the feed's trains at
// the rider's platform back it, or show that no train could have made it. Until Nov 5 a felt pull-away moved the trip
// to "on the train" at once and the feed was asked only 100 s later, so the Live Activity showed the rider riding
// while they still stood on the platform (Oct 28 at 4 Av-9 St and Jay St, Nov 2 and Nov 5 at 4 Av-9 St: a train on
// another track, three to five minutes before theirs), and the rider's own "Not on the train" tap got there first.

/// What the feed says of a pull-away felt at the rider's platform.
enum PullAwayVerdict: Equatable {
    /// A train at the rider's own platform left then (or stood there and has gone since): the ride is on.
    case backed
    /// No train at the rider's own platform could have made it: the nearest one was still on its way, or long gone.
    case noTrain
    /// Not yet known: the feed is quiet here, or a train was about due and has not been seen leave yet.
    case pending
}

extension DepartureLog {
    /// Judge a pull-away felt at `ts`, as the log stands at `now`.
    ///
    /// `noTrain` needs a live feed (a poll within `aliveSec`, a train still to come at the platform) and every train
    /// at the rider's platform outside the span a pull-away at `ts` could come from: reaching the platform more than
    /// `arriveMarginSec` after it (the feed's arrival times run late as often as early), or pulling away more than
    /// `windowSec` before it. A train held past its posted time is still in the span while the feed lists the stop.
    /// `backed` when the feed saw a train leave the platform then, or had one standing there within `standingSec` before.
    func judgePullAway(at ts: Double, now: Double, aliveSec: Double = 120, arriveMarginSec: Double = 90, windowSec: Double = 120,
                       standingSec: Double = 90) -> PullAwayVerdict {
        let check = departureCheck(at: ts, windowSec: windowSec)
        if check.left { return .backed }
        let mine = entries.values.filter { $0.samePlatform }
        // the feed had a train standing at the platform just before: it is the one pulling out
        if mine.contains(where: { e in e.stoppedAtBoardTs.map { $0 >= ts - standingSec && $0 <= ts + 15 } ?? false }) { return .backed }
        guard now - lastPollTs <= aliveSec, check.waiting, !mine.isEmpty else { return .pending }
        // a train in the span: it may be the one (at the platform, held there, or leaving about then), so the feed's
        // later check says
        let inSpan = mine.contains { e in
            let passed = (e.progressIdx ?? e.boardIdx) > e.boardIdx
            if PlatformTiming.atPlatform(e.boardTs, route: e.route) > ts + arriveMarginSec { return false }   // still on its way
            if passed, PlatformTiming.pullsAway(e.boardTs, route: e.route) < ts - windowSec { return false }   // gone well before
            return true
        }
        return inSpan ? .pending : .noTrain
    }
}
