import Foundation

// Is the rider still on the train the phone has them on? The feed says where that train is; the phone's own motion
// says whether it moved with it. A train cannot run from one station to the next without pulling away and braking,
// and the phone feels each as a sustained push; a rider on a platform feels none (a platform shakes as trains pass,
// which is why shaking proves nothing here: Nov 9 at Jay St, three minutes on the platform read as riding on).
//
// Two rules follow, and both hold whatever the line or the station:
//   1. The route in hand is the prior at its own stops. Once the train has gone past the stop the route leaves it at,
//      the rider got off there unless the phone felt the train run on. Staying on is a claim that needs evidence;
//      getting off as planned needs none (a step across the platform is invisible to the sensors).
//      The route's own timing is part of that prior: once the train has left the stop the route leaves it at (by the
//      feed) and no push has been felt since it got there, the rider is off there now, not one stop later (Nov 10 at
//      Jay St: the call waited for the F to reach York St, the rider was on the A by then, and the A was dated from
//      that late moment and taken for the one behind). A stay-on the phone feels later still undoes it.
//   2. A ride only moves the rider forward. "Not on a train", said after the train has run on from where it was
//      boarded with the phone on it, puts the rider at the stop the pushes ended at, never back at the boarding
//      platform (Nov 9: put back at 4 Av-9 St twelve minutes and four stops after leaving it, and the next pull-away
//      read as a G leaving there).

/// What the phone's motion says once the train in hand has gone past the stop the route leaves it at.
enum PastStopVerdict: Equatable {
    /// The train has not reached the stop beyond yet (or one push was felt and one more stop will tell).
    case waiting
    /// The phone felt the train run on: the rider stayed on past the stop.
    case stayedOn
    /// No train's push since the stop: the rider got off there, unfelt, when the train reached it.
    case steppedOff(at: Double)
    /// Pushes, but they begin with a connection pulling away from the change platform: the rider got off at the stop
    /// and is on that connection (a step onto a train standing across the platform).
    case tookConnection(offAt: Double, pullAwayTs: Double)
}

/// What the phone's motion says of a felt pull-away nothing has backed yet (`TripTracker.boardingPending`).
enum PendingRideVerdict: Equatable {
    /// Too early to tell.
    case open
    /// The train ran on with the phone: pushes after the pull-away, as every ride between two stations has.
    case rides
    /// No push since the pull-away for longer than any real ride goes without one: the rider is still on the platform
    /// (Nov 5 at 4 Av-9 St: a B's pull-away claimed, then nothing for six minutes until the rider's own train left).
    case notARide
}

struct RideContinuity {
    /// Pushes count from this long after the train reached the stop: its braking into it is over by then.
    var afterArrivalSec = 15.0
    /// And to this long after it reached a stop beyond: its braking into that one.
    var afterNextSec = 30.0
    /// The stop beyond counts as reached this long after the train's moment there (the feed's time is an estimate).
    var settleSec = 20.0
    /// A train running from one stop to the next is felt as at least this many sustained pushes (away, and braking).
    var pushesForRunning = 2
    /// A ride the phone is on is felt as pushes after its pull-away: across every stored ride the first came within
    /// 155 s of it (one at 223 s, none later), and no ride went 275 s between two. A pending pull-away with none for
    /// this long was not a ride.
    var rideQuietSec = 270.0
    /// And this many confirm one.
    var pushesForRide = 2

    /// A pull-away felt at `departedTs`, waiting to be backed: does the motion since say the phone is on that train?
    /// Pushes count from `afterArrivalSec` after it (the pull-away's own push is the claim, not evidence for it).
    func pendingRide(departedTs: Double, pushTimes: [Double], now: Double) -> PendingRideVerdict {
        let since = pushTimes.filter { $0 > departedTs + afterArrivalSec && $0 <= now }
        if since.count >= pushesForRide { return .rides }
        if since.isEmpty, now - departedTs >= rideQuietSec { return .notARide }
        return .open
    }

    /// A push this near a connection's pull-away from the change platform is that connection's.
    var connectionWindowSec = 30.0
    /// Off at the change by the route's timing: no push from `afterArrivalSec` after the train reached the stop for at
    /// least this long, and until `leftGraceSec` after the feed has it leaving there.
    var offQuietSec = 45.0
    var leftGraceSec = 20.0
    /// A span between two polls in which a connection left the platform counts only when the polls were this close.
    var maxLeftSpanSec = 120.0

    /// A push at `p` is a connection pulling away from the change platform: near the feed's time for one, or inside the
    /// span between the last poll that still listed it at the platform and the first that had it gone.
    func isConnection(_ p: Double, pullAways: [Double], left: [PollSpan]) -> Bool {
        pullAways.contains { abs($0 - p) <= connectionWindowSec }
            || left.contains { $0.to - $0.from <= maxLeftSpanSec && p >= $0.from - connectionWindowSec / 2 && p <= $0.to + connectionWindowSec / 2 }
    }

    /// A connection's pull-away explains a push even when the train in hand might have pulled away then too, unless the
    /// train in hand fits the push this much better: the route is the prior at its change (Nov 11 at Jay St: the C left
    /// a minute after the F, both inside the feed's error, and the phone kept the rider on the F).
    var planBiasSec = 30.0
    /// And no connection explains a push this far outside every window it could have left in.
    var maxConnectionMissSec = 45.0

    /// The first push after the stop is better put to a connection leaving the change platform (`connectionWindows`, from
    /// `DepartureLog.departureWindows`) than to the train in hand pulling away (`trainWindow`: from when it could first
    /// leave to when the feed last could have had it there), the plan winning a tie. Lag-tolerant both ways, so it does
    /// not hang on which poll happened to catch which train (Nov 11: the same trip read as the C or as the F by a poll
    /// 15 s later or sooner).
    func connectionExplains(_ p: Double, connectionWindows: [PollSpan], trainWindow: PollSpan?) -> Bool {
        func miss(_ w: PollSpan) -> Double { p < w.from ? w.from - p : p > w.to ? p - w.to : 0 }
        guard let dC = connectionWindows.map(miss).min(), dC <= maxConnectionMissSec else { return false }
        return dC <= trainWindow.map(miss).map { $0 + planBiasSec } ?? .infinity
    }

    /// `atStopTs`: the moment the train in hand reached the stop the route leaves it at (at the platform, not the
    /// feed's time). `laterStopTs`: its moments at the stops beyond, in order, as far as the feed has told.
    /// `pushTimes`: when each sustained push the phone felt began (`TripTracker.pushRuns`). `connectionPullAways`:
    /// when each train of the next leg's lines pulled away from the change platform, by the feed; `connectionLeft`: the
    /// poll spans in which each left. `trainLeavesTs`: when the train in hand left the stop, by the feed (nil: wait for
    /// the stop beyond, as before the timing rule).
    func pastStop(atStopTs: Double, laterStopTs: [Double], pushTimes: [Double], connectionPullAways: [Double] = [], connectionLeft: [PollSpan] = [],
                  connectionWindows: [PollSpan] = [], trainWindow: PollSpan? = nil, trainLeavesTs: Double? = nil, now: Double) -> PastStopVerdict {
        let from = atStopTs + afterArrivalSec
        let since = pushTimes.filter { $0 >= from && $0 <= now }
        // the route's own connection leaving as the pushes begin: the plan explains them, so the plan stands. Staying on
        // needs the first push to be the train in hand's, not merely a push: a rider on the connection feels the same
        // runs between stations as one on the train in hand.
        if let p = since.first, isConnection(p, pullAways: connectionPullAways, left: connectionLeft)
            || connectionExplains(p, connectionWindows: connectionWindows, trainWindow: trainWindow) {
            return .tookConnection(offAt: atStopTs, pullAwayTs: p)
        }
        let reached = laterStopTs.sorted().filter { $0 > atStopTs && $0 + settleSec <= now }
        guard let first = reached.first else {
            // the route's timing: the train has left the change and nothing has pushed the phone since it got there, so
            // the rider stood on the platform as it went (or stepped onto a train that has not moved yet)
            if since.isEmpty, let leaves = trainLeavesTs, now >= max(atStopTs + offQuietSec, leaves + leftGraceSec) { return .steppedOff(at: atStopTs) }
            return .waiting
        }
        let toFirst = pushTimes.filter { $0 >= from && $0 <= first + afterNextSec }
        if toFirst.count >= pushesForRunning { return .stayedOn }
        if toFirst.isEmpty { return .steppedOff(at: atStopTs) }
        // one push: the feed's time for the stop may run early and the push be the braking into it; one more stop tells
        guard reached.count >= 2 else { return .waiting }
        let toSecond = pushTimes.filter { $0 >= from && $0 <= reached[1] + afterNextSec }
        return toSecond.count > pushesForRunning ? .stayedOn : .steppedOff(at: atStopTs)
    }

    /// The first train of the connection that left the change platform after `afterTs` and by `byTs` (its pull-away by
    /// the feed): the one a rider who got off at `afterTs` and was moving with a train by `byTs` stepped onto. The
    /// route's timing again: the rider takes the first connection that comes, not the one the phone first noticed.
    func firstConnection(after afterTs: Double, by byTs: Double, pullAways: [Double]) -> Double? {
        pullAways.sorted().first { $0 >= afterTs && $0 <= byTs }
    }

    /// A ride over `stops` station stops is felt as at least this many pushes: one per run between stops (a phone held
    /// in the hand feels fewer than one in a pocket; Oct 21: 12 over 12 stops), and never fewer than `minRidePushes`,
    /// which a wait on a platform does not reach.
    var minRidePushes = 3

    /// "Not on a train", said on a ride that began at `departedTs`: the stop the rider left the train `c` at, when the
    /// phone rode it on from the boarding platform. The train's last push the phone felt was its braking into that
    /// stop, so it is the first stop the train reached from a little before that push on, else the last it has
    /// reached, and the pushes felt on the way there must be a ride's (`minRidePushes`, one per stop at least).
    /// nil when nothing says the phone ever left the platform: the pull-away was not a train, and the leg starts over.
    func stopLeftAt(_ c: BoardingCandidate, departedTs: Double, pushTimes: [Double], now: Double) -> (idx: Int, ts: Double)? {
        let pushes = pushTimes.filter { $0 > departedTs + afterArrivalSec && $0 <= now }
        guard let last = pushes.last else { return nil }
        let reached = c.stopTs.filter { $0.key > c.boardIdx }
            .map { (idx: $0.key, ts: PlatformTiming.atPlatform($0.value, route: c.route)) }
            .filter { $0.ts > departedTs && $0.ts <= now }
            .sorted { $0.idx < $1.idx }
        guard let stop = reached.first(where: { $0.ts >= last - 45 }) ?? reached.last else { return nil }
        guard pushes.count >= max(minRidePushes, stop.idx - c.boardIdx) else { return nil }
        return stop
    }
}
