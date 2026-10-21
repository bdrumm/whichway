import Foundation

// A faster way on from where the rider is, while a route is under way: the routes are weighed from the rider's
// assumed place (on the way to the first platform, on the train the phone believes they are on, or between trains
// at the change), with the trains as the predicted boards have them, so offline the forecast kept on the phone
// stands in for the feed.

/// Where the rider is taken to be on the route in progress.
enum RiderPosition {
    /// On the way to the first platform, or at it: `reachTs` is when they can be on it (nil at the station, or
    /// where they are is not known: every train on the board is in reach).
    case toOrigin(reachTs: Double?)
    /// On leg `leg`'s train: the one the phone settled on or the rider named, else the plan's.
    case onTrain(leg: Int, boarded: BoardingCandidate)
    /// Off leg `leg - 1`'s train, at the change, waiting for leg `leg`'s.
    case atChange(leg: Int)
}

/// A route that gets the rider in sooner than the one they are on, from where they are now.
struct FasterRoute {
    var option: PathOption
    var itinerary: Itinerary
    var currentArriveTs: Double
    var savedSec: Double { currentArriveTs - itinerary.arriveTs }
    /// The first thing the rider does differently: the stop where they leave the train in hand (on the train), the
    /// first train they board otherwise.
    var actionTs: Double
}

enum Reroute {
    /// A faster route is offered when it saves at least this much.
    static let offerSec = 120.0
    /// One on offer stays while it still saves this much, so a minute's swing in the feed does not make it blink.
    static let keepSec = 60.0
    /// Another replaces the one on offer only when it is this much faster again.
    static let replaceSec = 60.0
    /// The first step off the route in hand must be at least this far off, so the rider can act on it.
    static let reactSec = 45.0
}

/// `p` goes on from where the rider is on `current`: from the same first station on the way there; on the train,
/// the same stations ridden on the legs behind, the same boarding station and the line of the train in hand on the
/// leg ridden now; at the change, the same first leg and a next leg from the same station. `station` maps a stop
/// to its complex.
func continuesFrom(_ p: PathOption, current: PathOption, at pos: RiderPosition, station: (String) -> String) -> Bool {
    func sameBehind(_ n: Int) -> Bool {
        guard p.legs.count > n, current.legs.count > n else { return false }
        for i in 0..<n where station(p.legs[i].from) != station(current.legs[i].from) || station(p.legs[i].to) != station(current.legs[i].to) { return false }
        return true
    }
    guard !p.legs.isEmpty, !current.legs.isEmpty else { return false }
    switch pos {
    case .toOrigin:
        return station(p.legs[0].from) == station(current.legs[0].from)
    case let .onTrain(leg, c):
        guard sameBehind(leg), p.legs[leg].keys.contains(c.key) else { return false }
        return station(p.legs[leg].from) == station(current.legs[leg].from)
    case let .atChange(leg):
        guard leg > 0, sameBehind(leg) else { return false }
        return station(p.legs[leg].from) == station(current.legs[leg].from)
    }
}

/// The itinerary on `option` from where the rider is, on trains in the feed (or the forecast kept offline) only:
/// nil where a leg still to ride has no train to name, so a route is never offered on the timetable's guess. On
/// the train, the itinerary keeps the train in hand and the connections it makes; at the change, a next leg from
/// another platform of the station counts the walk to it.
func itineraryFromHere(boards: [String: LineBoard], schedule: ClientSchedule, option: PathOption, at pos: RiderPosition,
                       current: PathOption, now: Double) -> Itinerary? {
    switch pos {
    case let .toOrigin(reachTs):
        guard let it = pathTrips(boards: boards, schedule: schedule, option: option, now: now, maxN: 1, reachTs: reachTs).first,
              it.legs.count == option.legs.count else { return nil }
        // nothing in reach in the feed, `pathTrips` offers the next train anyway: not a train to send the rider for
        if let r = reachTs, it.boardTs + reachDoorsSec < r { return nil }
        return it
    case let .onTrain(leg, c):
        guard let ix = option.legs[leg].idx[c.key], let t = boards[c.key]?.trains.first(where: { $0.id == c.trainId }),
              t.points.contains(where: { $0.idx == ix.to }) else { return nil }      // the train is past where this route leaves it
        guard let it = ridingItinerary(boards: boards, schedule: schedule, option: option, leg: leg, boarded: c, now: now),
              it.legs.count == option.legs.count - leg else { return nil }
        return it
    case let .atChange(leg):
        guard option.legs.indices.contains(leg), current.legs.indices.contains(leg) else { return nil }
        // another platform than the one the route in hand changes to: the walk across the station first
        let walk = option.legs[leg].from == current.legs[leg].from ? 0 : (option.transfer?.plannedSec ?? 0)
        guard var it = connectionItinerary(boards: boards, schedule: schedule, option: option, leg: leg, now: now + walk) else { return nil }
        it.totalSec = it.arriveTs - now
        return it
    }
}

/// The current route's own itinerary from where the rider is: the same reading as the planner's card (the
/// timetable stands in for a connection not in the feeds yet).
func currentItinerary(boards: [String: LineBoard], schedule: ClientSchedule, option: PathOption, at pos: RiderPosition, now: Double) -> Itinerary? {
    switch pos {
    case let .toOrigin(reachTs):
        return pathTrips(boards: boards, schedule: schedule, option: option, now: now, maxN: 1, reachTs: reachTs).first
    case let .onTrain(leg, c):
        return ridingItinerary(boards: boards, schedule: schedule, option: option, leg: leg, boarded: c, now: now)
    case let .atChange(leg):
        return connectionItinerary(boards: boards, schedule: schedule, option: option, leg: leg, now: now)
    }
}

/// The first step on `it` that differs from the route in hand: on the train, getting off it (unless both routes
/// leave it at the same stop, then the next boarding); otherwise the first boarding.
private func firstAction(_ it: Itinerary, at pos: RiderPosition, sameAlighting: Bool) -> Double {
    if case .onTrain = pos {
        if sameAlighting, it.legs.count > 1 { return it.legs[1].boardTs }
        return it.legs[0].arriveTs
    }
    return it.boardTs
}

/// The route to offer the rider instead of `current`, from where they are: the earliest arrival among `options`
/// that saves at least `Reroute.offerSec` and leaves time to act on its first step. `keeping`: the id of the one on
/// offer now, which stays while it saves `Reroute.keepSec` unless another beats it by `Reroute.replaceSec`. Nil
/// when the route in hand is as good as any, or its own arrival is not known.
func fasterRoute(current: PathOption, options: [PathOption], at pos: RiderPosition, boards: [String: LineBoard], schedule: ClientSchedule,
                 station: (String) -> String, now: Double, keeping: String? = nil) -> FasterRoute? {
    guard let mine = currentItinerary(boards: boards, schedule: schedule, option: current, at: pos, now: now) else { return nil }
    var found: [FasterRoute] = []
    for p in options where p.id != current.id && continuesFrom(p, current: current, at: pos, station: station) {
        guard let it = itineraryFromHere(boards: boards, schedule: schedule, option: p, at: pos, current: current, now: now) else { continue }
        // the same trains as the route in hand: the same journey under another name
        if it.legs.map(\.train.id) == mine.legs.map(\.train.id) { continue }
        var sameAlighting = false
        if case let .onTrain(leg, c) = pos, let a = p.legs[leg].idx[c.key]?.to, let b = current.legs[leg].idx[c.key]?.to { sameAlighting = a == b }
        let act = firstAction(it, at: pos, sameAlighting: sameAlighting)
        guard act - now >= Reroute.reactSec else { continue }
        found.append(FasterRoute(option: p, itinerary: it, currentArriveTs: mine.arriveTs, actionTs: act))
    }
    guard let best = found.min(by: { $0.itinerary.arriveTs < $1.itinerary.arriveTs }) else { return nil }
    if let k = keeping, let kept = found.first(where: { $0.option.id == k }), kept.savedSec >= Reroute.keepSec,
       best.itinerary.arriveTs > kept.itinerary.arriveTs - Reroute.replaceSec {
        return kept
    }
    return best.savedSec >= Reroute.offerSec ? best : nil
}
