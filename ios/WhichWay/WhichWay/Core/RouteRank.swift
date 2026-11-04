import Foundation

// The order the routes are listed in, on the routes page and on the home's lanes alike (the home is a short copy of
// that list). The rider's usual way for this trip at this hour (`RouteHabits.routeAffinity`) comes first unless
// another way gets in a margin sooner that is worth breaking the habit for (`RouteRank.significantSec`); the rest
// by arrival, a train in the feeds ahead of a timetable guess, with the small habit nudge (`RouteHabits.rankNudgeSec`)
// settling near ties.

/// One route as the ranking weighs it.
struct RankedRoute: Equatable {
    var id: String
    /// The arrival of its next train in the feeds; nil while it has none.
    var arriveTs: Double?
    /// Its expected door-to-door seconds, which order the routes with no train in the feeds.
    var expectedSec: Double
    /// The share of the rider's trips like this one that took it; nil until the habits know enough.
    var affinity: Double?
}

enum RouteRank {
    /// The usual way is the one the rider took on at least this share of trips like this one, ahead of every other.
    static let typicalMinShare = 0.35
    /// A way that gets in at least this much sooner than the usual one goes ahead of it: a real difference, not noise
    /// in the feeds' predictions (a train or two minutes either way) that the rider would rather not chase.
    static let significantSec = 240.0

    /// The rider's usual way among `routes`: the one with the largest share of their trips like this one, when that
    /// share is at least `typicalMinShare` and no other way ties it; nil when the habits do not single one out.
    static func typical(_ routes: [RankedRoute]) -> String? {
        let known = routes.compactMap { r in r.affinity.map { (id: r.id, share: $0) } }.sorted { $0.share > $1.share }
        guard let top = known.first, top.share >= typicalMinShare else { return nil }
        if known.count > 1, known[1].share >= top.share - 1e-9 { return nil }
        return top.id
    }

    /// `routes` best first: by arrival (a route with a train in the feeds ahead of one without), each counting the
    /// habit nudge sooner, then the usual way moved up ahead of every route that does not beat it by `significantSec`.
    static func order(_ routes: [RankedRoute]) -> [RankedRoute] {
        func nudge(_ r: RankedRoute) -> Double { RouteHabits.rankNudgeSec(r.affinity) }
        var list = routes.sorted { a, b in
            let na = nudge(a), nb = nudge(b)
            switch (a.arriveTs, b.arriveTs) {
            case let (x?, y?): return x - na != y - nb ? x - na < y - nb : (a.expectedSec != b.expectedSec ? a.expectedSec < b.expectedSec : a.id < b.id)
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.expectedSec - na != b.expectedSec - nb ? a.expectedSec - na < b.expectedSec - nb : a.id < b.id
            }
        }
        guard let t = typical(routes), let i = list.firstIndex(where: { $0.id == t }) else { return list }
        let usual = list.remove(at: i)
        let at = list.firstIndex { !beats($0, usual) } ?? list.count
        list.insert(usual, at: min(at, i))
        return list
    }

    /// Whether `a` stays ahead of the usual way `usual`: it gets in `significantSec` sooner, or it has a train in the
    /// feeds and the usual way has none (a way nobody can board yet never outranks one with a train on its way).
    static func beats(_ a: RankedRoute, _ usual: RankedRoute) -> Bool {
        switch (a.arriveTs, usual.arriveTs) {
        case let (x?, y?): return y - x >= significantSec
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return usual.expectedSec - a.expectedSec >= significantSec
        }
    }
}
