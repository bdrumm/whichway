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
    /// Not yet known: a train was about due and has not been seen leave yet, or another line's train left.
    case pending
    /// Nothing to check it against: no feed at the platform (no signal there, or none polled yet). The sensors stand
    /// alone, as before the gate, and the rider's "Not on the train" is the override.
    case unchecked
}

extension DepartureLog {
    /// Judge a pull-away felt at `ts`, as the log stands at `now`.
    ///
    /// `noTrain` needs a live feed (a poll within `aliveSec`, a train still to come at the platform) and every train
    /// at the rider's platform outside the span a pull-away at `ts` could come from: reaching the platform more than
    /// `arriveMarginSec` after it (the feed's arrival times run late as often as early), or pulling away more than
    /// `windowSec` before it. A train held past its posted time is still in the span while the feed lists the stop.
    /// `backed` when the feed saw a train of the leg's own lines leave the platform then, or had one standing there within
    /// `standingSec` before. Another line's train leaving the same platform (the G beside the F at 4 Av-9 St, Nov 5,
    /// minutes before the rider's F) backs nothing: it may be the train the rider took, or the one that
    /// shook them, so the claim waits as boarding for the rider's word or the ride's own evidence.
    func judgePullAway(at ts: Double, now: Double, aliveSec: Double = 120, arriveMarginSec: Double = 90, windowSec: Double = 120,
                       standingSec: Double = 90) -> PullAwayVerdict {
        let check = departureCheck(at: ts, windowSec: windowSec)
        if departureCheck(at: ts, windowSec: windowSec, onLegOnly: true).left { return .backed }
        let mine = entries.values.filter { $0.samePlatform }
        // the feed had a train of the leg's lines standing at the platform just before: it is the one pulling out
        func stoodThen(_ e: Entry) -> Bool { e.stoppedAtBoardTs.map { $0 >= ts - standingSec && $0 <= ts + 15 } ?? false }
        if mine.contains(where: { $0.onLeg && stoodThen($0) }) { return .backed }
        if check.left || mine.contains(where: stoodThen) { return .pending }      // another line's train: not the plan's
        guard now - lastPollTs <= aliveSec, !mine.isEmpty else { return .unchecked }
        guard check.waiting else { return .pending }
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
