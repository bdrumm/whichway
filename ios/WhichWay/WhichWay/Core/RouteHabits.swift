import Foundation

// Which trains this rider actually rides: for each finished trip, the line each leg was ridden on (as the sensors
// or the rider settled it), where it was boarded, where they changed, and when. Stays on the phone. Two readers:
// the line inference, which takes the rider's usual line at a platform as its prior for which train they boarded
// (and for which line they change to), and the planner, which lets the rider's usual route win a near tie.

/// One leg as ridden: the line, and where it was boarded (the origin station id on the first leg, the change's
/// station name after it, as the trip's record keeps them).
struct RiddenLeg: Codable, Equatable {
    var leg: Int
    var key: String
    var from: String
}

/// One finished trip as ridden.
struct RouteRide: Codable, Equatable {
    var origin: String
    var dest: String
    var transfer: String?
    var legs: [RiddenLeg]
    var ts: Double
    var hour: Double          // New York, fractional
    var weekday: Int          // 1 = Sunday … 7 = Saturday
}

/// The rider's lines at a platform: each line's share of the weighted rides that boarded there, and how much
/// weight of rides stands behind the shares (about one per recent ride at a similar hour).
struct LinePrior: Equatable {
    var shares: [String: Double]
    var weight: Double

    func share(_ key: String) -> Double { shares[key] ?? 0 }

    /// A multiplier per line for the line inference's prior (`LegPlan.lineFit`): a line the rider always takes here
    /// up to 1.4, one they never do down to 0.6, pulled toward 1 while few rides stand behind it.
    func fit(_ keys: [String]) -> [String: Double] {
        let trust = weight / (weight + 2)
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, 1 + trust * (0.8 * share($0) - 0.4)) })
    }
}

struct RouteHabits: Codable, Equatable {
    var rides: [RouteRide] = []
    static let cap = 400
    /// A ride counts half after this many days, so a new job or a move shows within weeks.
    static let halfLifeDays = 60.0
    /// A prior speaks once this much weight of rides stands behind it: two recent rides at about this hour.
    static let minWeight = 1.5
    /// A ride that went somewhere else from the same platform still says which line the rider takes there, but less.
    static let otherDestWeight = 0.3
    /// The most the rider's usual route gains in the ranking: it wins a tie, never a real difference.
    static let maxRankNudgeSec = 90.0

    /// Records a finished trip's legs where the phone settled the line; nothing when it settled none.
    @discardableResult
    mutating func record(_ t: TripTimeline, timeZone: TimeZone) -> Bool {
        let settled = t.boarded.filter { $0.verdict != .unsure }.sorted { $0.leg < $1.leg }
        guard !settled.isEmpty, !t.originStation.isEmpty, !t.destStation.isEmpty, t.originStation != t.destStation else { return false }
        let legs = settled.map { RiddenLeg(leg: $0.leg, key: $0.key, from: $0.leg == 0 ? t.originStation : (t.transferStation ?? "")) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .weekday], from: Date(timeIntervalSince1970: t.startTs))
        rides.append(RouteRide(origin: t.originStation, dest: t.destStation, transfer: t.legs > 1 ? t.transferStation : nil, legs: legs,
                               ts: t.startTs, hour: Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60, weekday: c.weekday ?? 1))
        if rides.count > RouteHabits.cap { rides.removeFirst(rides.count - RouteHabits.cap) }
        return true
    }

    /// How much a past ride speaks for now: near in the hour, the same kind of day, recent.
    func weight(_ r: RouteRide, hour: Double, weekday: Int, now: Double) -> Double {
        var dh = abs(r.hour - hour); dh = min(dh, 24 - dh)
        let tw = max(0.25, 1 - dh / 4)
        let weekend = weekday == 1 || weekday == 7, rw = r.weekday == 1 || r.weekday == 7
        let dw = r.weekday == weekday ? 1.0 : (rw == weekend ? 0.8 : 0.4)
        let days = max(0, now - r.ts) / 86400
        return tw * dw * pow(0.5, days / RouteHabits.halfLifeDays)
    }

    /// The lines this rider boards at `station` on leg `leg` (0: setting out, else after a change), heading for
    /// `dest`; rides that went elsewhere from there count `otherDestWeight`. `after`: on a later leg, only changes
    /// off this line. nil until `minWeight` of rides stands behind it.
    func linePrior(boardingAt station: String, leg: Int, toward dest: String?, after fromKey: String? = nil,
                   hour: Double, weekday: Int, now: Double) -> LinePrior? {
        var by: [String: Double] = [:]
        var total = 0.0
        for r in rides {
            guard let l = r.legs.first(where: { $0.from == station && ($0.leg == 0) == (leg == 0) }) else { continue }
            if let f = fromKey, r.legs.first(where: { $0.leg == l.leg - 1 })?.key != f { continue }
            let w = weight(r, hour: hour, weekday: weekday, now: now) * (dest == nil || r.dest == dest ? 1 : RouteHabits.otherDestWeight)
            by[l.key, default: 0] += w
            total += w
        }
        guard total >= RouteHabits.minWeight else { return nil }
        return LinePrior(shares: by.mapValues { $0 / total }, weight: total)
    }

    /// The line this rider changes to at `station` after riding `fromKey`: `linePrior` for the leg after the change.
    func transferPrior(at station: String, from fromKey: String?, toward dest: String?, hour: Double, weekday: Int, now: Double) -> LinePrior? {
        linePrior(boardingAt: station, leg: 1, toward: dest, after: fromKey, hour: hour, weekday: weekday, now: now)
    }

    /// Whether a ride took route `p`: the same change (or none), and each leg ridden on one of the route's lines.
    func rode(_ r: RouteRide, _ p: PathOption) -> Bool {
        guard r.transfer == p.transfer?.station, r.legs.allSatisfy({ p.legs.indices.contains($0.leg) }) else { return false }
        return r.legs.allSatisfy { p.legs[$0.leg].keys.contains($0.key) }
    }

    /// The share of this rider's trips from `origin` to `dest` at about this hour that took route `p`; nil until
    /// `minWeight` of such trips is known.
    func routeAffinity(_ p: PathOption, origin: String, dest: String, hour: Double, weekday: Int, now: Double) -> Double? {
        var mine = 0.0, total = 0.0
        for r in rides where r.origin == origin && r.dest == dest {
            let w = weight(r, hour: hour, weekday: weekday, now: now)
            total += w
            if rode(r, p) { mine += w }
        }
        guard total >= RouteHabits.minWeight else { return nil }
        return mine / total
    }

    /// Seconds the ranking takes off a route the rider usually takes: nothing below an even share, up to
    /// `maxRankNudgeSec` for the route they always take.
    static func rankNudgeSec(_ affinity: Double?) -> Double {
        guard let a = affinity, a > 0.5 else { return 0 }
        return maxRankNudgeSec * (a - 0.5) / 0.5
    }
}
