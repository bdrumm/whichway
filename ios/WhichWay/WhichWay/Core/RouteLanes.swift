import Foundation

// The Go tab's home lanes: every way to the destination on one clock, from now to arrival, a short copy of the
// routes page two swipes over: the same routes in the same order (`RouteRank`: the rider's usual way first unless
// another is a real margin sooner), the route in hand marked where it falls rather than lifted to the top. Each
// lane knows where it leaves the route in hand (another train or line from the first platform, staying on past the
// change, getting off sooner, another line at the same change). As the trip goes on the routes are weighed from
// where the rider is (`continuesFrom`, `itineraryFromHere`), so a way behind them drops out.

/// One stretch of a lane: on a platform waiting, on a train, or changing between trains.
enum LaneSegmentKind: Equatable {
    case wait
    /// On `route`; `estimated`: no train for it in the feeds yet, the timetable's guess.
    case ride(route: String, estimated: Bool)
    /// Off one train and over to the next: across the platform or a walk.
    case change(acrossPlatform: Bool)
}

struct LaneSegment: Equatable {
    var kind: LaneSegmentKind
    var startTs: Double
    var endTs: Double
}

/// Where a lane leaves the route in hand.
enum LaneParting: Equatable {
    /// The route in hand.
    case current
    /// Another line (or another first train) from the first platform.
    case atStart
    /// Stays on the train in hand past the change at `station`: changes later on, or not at all.
    case stayOn(station: String)
    /// Gets off the train in hand at `station`, short of the route's own change.
    case offEarlier(station: String)
    /// Off at the same change, `station`, onto another line.
    case otherConnection(station: String)
    /// A way the rider is already past (it leaves from a platform or a train behind them): still listed, not takeable.
    case behind

    /// The station the choice is made at; nil for the first platform.
    var station: String? {
        switch self {
        case let .stayOn(s), let .offEarlier(s), let .otherConnection(s): return s
        case .current, .atStart, .behind: return nil
        }
    }
}

struct RouteLane: Identifiable {
    /// The route's id.
    var id: String
    var optionId: String
    /// The lines, one per leg still to ride: the itinerary's trains where known.
    var routes: [String]
    /// The change still ahead, by name; nil when the rest is one train.
    var changeAt: String?
    var segments: [LaneSegment]
    var arriveTs: Double
    var parting: LaneParting
    /// When the lane leaves the route in hand: the stop where they part; nil when they part at the first platform.
    var partsTs: Double?
    /// The lane's arrival less the route in hand's.
    var deltaSec: Double
    /// No train for it in the feeds: the arrival is the route's expected door-to-door time from now, and no bar is drawn.
    var estimated = false
    var isCurrent: Bool { parting == .current }
    var isBehind: Bool { parting == .behind }
}

/// What the home shows: the routes in the routes page's order, the route in hand among them, and the clock they are
/// drawn on.
struct RouteLanes {
    /// The route in hand (also in `lanes`, where it ranks).
    var current: RouteLane
    /// Every route, in the held order (`SteadyOrder`) or else best first (`RouteRank.order`), the route in hand among
    /// them: never cut down to the ones that go on from the route in hand (Nov 5: "stop filtering the list").
    var lanes: [RouteLane]
    /// The rider's usual way for this trip at this hour, when the habits single one out (`RouteRank.typical`).
    var typicalId: String?
    var startTs: Double
    var endTs: Double

    /// The clock spans at least this long, and ends on a whole five minutes.
    static let minSpanSec = 15.0 * 60

    /// On the way: the next station where a listed way leaves the route in hand, and when the rider gets there.
    func nextChoice(after now: Double) -> (station: String, ts: Double)? {
        lanes.compactMap { l in l.parting.station.flatMap { s in l.partsTs.flatMap { $0 > now ? (s, $0) : nil } } }.min { $0.1 < $1.1 }
    }
}

/// The stretches of a lane from `startTs` on: the wait for the first train (none while on it), its ride, the change
/// and the wait for the next, its ride. `ridingFirst`: the rider is on the first train of `it` now. `option` and
/// `leg` give the lines when the itinerary carries fewer legs than are left (a connection not in the feeds yet: its
/// ride is the timetable's guess, up to the itinerary's arrival).
func laneSegments(_ it: Itinerary, option: PathOption, leg: Int = 0, ridingFirst: Bool, from startTs: Double) -> [LaneSegment] {
    var out: [LaneSegment] = []
    func add(_ k: LaneSegmentKind, _ a: Double, _ b: Double) {
        let a = max(a, startTs)
        if b > a { out.append(LaneSegment(kind: k, startTs: a, endTs: b)) }
    }
    guard let first = it.legs.first else { return [] }
    if !ridingFirst { add(.wait, startTs, first.boardTs) }
    add(.ride(route: first.train.route, estimated: false), ridingFirst ? startTs : first.boardTs, first.arriveTs)
    let legsLeft = option.legs.count - leg
    guard legsLeft > 1, let tr = option.transfer else { return out }
    let changeEnd = first.arriveTs + tr.plannedSec
    if it.legs.count > 1 {
        let second = it.legs[1]
        // a train standing across the platform can be boarded before the planned step is done: the change ends there
        add(.change(acrossPlatform: tr.acrossPlatform), first.arriveTs, min(changeEnd, max(second.boardTs, first.arriveTs + 1)))
        add(.wait, changeEnd, second.boardTs)
        add(.ride(route: second.train.route, estimated: false), second.boardTs, second.arriveTs)
    } else {
        let next = option.legs[leg + 1]
        add(.change(acrossPlatform: tr.acrossPlatform), first.arriveTs, changeEnd)
        let rideStart = max(changeEnd, it.arriveTs - Double(next.schedRideSec ?? 0))
        add(.wait, changeEnd, rideStart)
        add(.ride(route: next.primaryRoute, estimated: true), rideStart, it.arriveTs)
    }
    return out
}

/// Where `p` leaves `current` for a rider at `pos` (nil: the route has not started). `station` maps a stop to its
/// complex. Both are taken to go on from where the rider is (`continuesFrom`).
func laneParting(_ p: PathOption, from current: PathOption, at pos: RiderPosition?, station: (String) -> String) -> LaneParting {
    if p.id == current.id { return .current }
    let leg: Int
    var inHand: String? = nil
    switch pos {
    case nil, .toOrigin?: leg = 0
    case let .onTrain(l, c)?: leg = l; inHand = c.key
    case let .atChange(l)?: return .otherConnection(station: current.transfer?.station ?? "the change")
    }
    guard p.legs.indices.contains(leg), current.legs.indices.contains(leg) else { return .atStart }
    let a = p.legs[leg], b = current.legs[leg]
    // the line both ride on this leg: the train in hand, else one the two legs share from the same platform
    guard station(a.from) == station(b.from),
          let key = inHand ?? a.keys.first(where: { b.keys.contains($0) }),
          let ia = a.idx[key]?.to, let ib = b.idx[key]?.to else { return .atStart }
    if ia == ib {
        return p.legs.count > leg + 1 ? .otherConnection(station: current.transfer?.station ?? p.transfer?.station ?? "the change") : .atStart
    }
    if ia > ib { return .stayOn(station: current.transfer?.station ?? "the change") }
    return .offEarlier(station: p.transfer?.station ?? "the change")
}

/// The home's lanes: `current` on `currentIt` (the ride in hand while on the way, else the planner's next) and
/// `alternatives` with their itineraries from where the rider is, ranked as the routes page ranks them
/// (`RouteRank.order`, `affinity` the rider's share per route id). A way on the same trains as the route in hand is
/// listed too: every route is, whatever the route in hand. `unplaced`: routes with no train in the feeds (listed on
/// their expected time, no bar); `behind`: routes the rider is already past on the way (listed, not takeable).
/// `order`: the routes page's held order (`SteadyOrder`), which the lanes keep too rather than reshuffling.
func routeLanes(current: PathOption, currentIt: Itinerary, alternatives: [(PathOption, Itinerary)], unplaced: [PathOption] = [],
                behind: [PathOption] = [], affinity: [String: Double] = [:],
                order: SteadyOrder? = nil, at pos: RiderPosition?, now: Double, station: (String) -> String) -> RouteLanes {
    var leg = 0, riding = false
    switch pos {
    case let .onTrain(l, _)?: leg = l; riding = true
    case let .atChange(l)?: leg = l
    default: break
    }
    func routes(_ it: Itinerary, _ p: PathOption) -> [String] {
        var r = it.legs.map(\.train.route)
        let left = p.legs.count - leg
        if r.count < left { r += p.legs[(leg + r.count)...].map(\.primaryRoute) }
        return r
    }
    func changeAt(_ p: PathOption) -> String? { p.legs.count - leg > 1 ? p.transfer?.station : nil }
    let cur = RouteLane(id: current.id, optionId: current.id, routes: routes(currentIt, current), changeAt: changeAt(current),
                        segments: laneSegments(currentIt, option: current, leg: leg, ridingFirst: riding, from: now),
                        arriveTs: currentIt.arriveTs, parting: .current, partsTs: nil, deltaSec: 0)
    // the route in hand leaves the train in hand at its change: the moment staying on, or another line there, parts from it
    let curChangeTs: Double? = changeAt(current) != nil ? currentIt.legs.first?.arriveTs : nil
    var lanes: [RouteLane] = [cur]
    for (p, it) in alternatives where p.id != current.id && !lanes.contains(where: { $0.id == p.id }) {
        let part = laneParting(p, from: current, at: pos, station: station)
        let ts: Double?
        switch part {
        case .stayOn, .otherConnection: ts = curChangeTs
        case .offEarlier: ts = it.legs.first?.arriveTs
        default: ts = nil
        }
        lanes.append(RouteLane(id: p.id, optionId: p.id, routes: routes(it, p), changeAt: changeAt(p),
                               segments: laneSegments(it, option: p, leg: leg, ridingFirst: riding, from: now),
                               arriveTs: it.arriveTs, parting: part, partsTs: ts, deltaSec: it.arriveTs - currentIt.arriveTs))
    }
    var expected: [String: Double] = [:]
    for (p, isBehind) in unplaced.map({ ($0, false) }) + behind.map({ ($0, true) }) where !lanes.contains(where: { $0.id == p.id }) {
        let arrive = now + p.expectedSec
        expected[p.id] = p.expectedSec
        // a way behind the rider is shown whole; one still ahead from the leg the rider is on
        let from = isBehind ? 0 : min(leg, p.legs.count - 1)
        lanes.append(RouteLane(id: p.id, optionId: p.id, routes: p.legs[from...].map(\.primaryRoute),
                               changeAt: p.legs.count - from > 1 ? p.transfer?.station : nil,
                               segments: [], arriveTs: arrive, parting: isBehind ? .behind : .atStart, partsTs: nil,
                               deltaSec: arrive - currentIt.arriveTs, estimated: true))
    }
    // a route with no train to time it ranks as a timetable guess, on its expected time, behind the ones with trains
    let weighed = lanes.map { l in
        RankedRoute(id: l.id, arriveTs: l.estimated ? nil : l.arriveTs, expectedSec: expected[l.id] ?? 0, affinity: affinity[l.optionId])
    }
    let byId = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
    var kept = RouteRank.order(weighed).compactMap { byId[$0.id] }
    if let order, order.settled { kept = order.arrange(kept, id: \.optionId) }
    let last = kept.filter { !$0.estimated }.map(\.arriveTs).max() ?? now
    let end = max(last, now + RouteLanes.minSpanSec)
    return RouteLanes(current: cur, lanes: kept, typicalId: RouteRank.typical(weighed),
                      startTs: now, endTs: (end / 300).rounded(.up) * 300)
}
