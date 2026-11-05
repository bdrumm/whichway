import Foundation

/// A change the rider can make before the route's own: off the line being ridden at a station it calls at short of
/// the planned change, onto a line that reaches the same destination (Oct 22 and Oct 27: the F planned to change at
/// W 4 St, the rider stepped across the platform onto the A at Jay St). Nothing the sensors feel tells such a change
/// apart from staying on: two steps across, then a train that moves like the one left. So the route offers it to the
/// rider, and it is the rider's word that hands the trip over.
struct EarlyChange: Equatable {
    var option: PathOption            // the route that changes there
    var station: String               // the change's station id
    var stationName: String
    var stopIdx: Int                  // the change's stop on the line being ridden
    var nextKeys: [String]            // the lines to change to there
    var acrossPlatform: Bool

    /// "A/C at Jay St-MetroTech"
    var text: String { "\(option.legs[1].routesLabel) at \(stationName)" }

    static func == (a: EarlyChange, b: EarlyChange) -> Bool { a.option.id == b.option.id }
}

/// The routes that ride `ridingKey` from the same station as `sel` and change before `sel` does, to a line that reaches
/// the same destination: nearest the boarding station first, across the platform before a walk at the same station.
/// This is what the phone offers on its own (`earlyChangeOffer`); the rider's own list is `changesOnTheWay`.
func earlierChanges(from sel: PathOption, ridingKey: String, among options: [PathOption], index: StationIndex) -> [EarlyChange] {
    guard sel.legs.count == 2, let planned = sel.legs[0].idx[ridingKey]?.to else { return [] }
    return changesOnTheWay(from: sel, ridingKey: ridingKey, among: options, index: index).filter { $0.stopIdx < planned }
}

/// Every change the rider could have made off `ridingKey` on the way to `sel`'s destination: at a station short of the
/// route's own change, past it (stayed on, then changed), or at the same station onto another line; on a route with no
/// change at all, anywhere along the ride. The rider's word in the "On a train?" sheet: listed whatever the phone
/// believes about where the train is, since that belief is what the list overrides. Nearest the boarding station
/// first, across the platform before a walk at the same station; `sel` itself is not listed (its change is the plan).
func changesOnTheWay(from sel: PathOption, ridingKey: String, among options: [PathOption], index: StationIndex) -> [EarlyChange] {
    guard let first = sel.legs.first, let last = sel.legs.last else { return [] }
    let origin = index.stationOf(first.from), dest = index.stationOf(last.to)
    var out: [EarlyChange] = []
    var seen = Set<String>([sel.id])
    for p in options where p.legs.count == 2 && !seen.contains(p.id) {
        guard let ix = p.legs[0].idx[ridingKey], let tr = p.transfer,
              index.stationOf(p.legs[0].from) == origin, index.stationOf(p.legs[1].to) == dest else { continue }
        seen.insert(p.id)
        let st = index.stationOf(p.legs[0].to)
        out.append(EarlyChange(option: p, station: st, stationName: tr.station, stopIdx: ix.to, nextKeys: p.legs[1].keys, acrossPlatform: tr.acrossPlatform))
    }
    return out.sorted { $0.stopIdx != $1.stopIdx ? $0.stopIdx < $1.stopIdx : ($0.acrossPlatform && !$1.acrossPlatform) }
}

/// The rider's list of changes, in the order to show: the one the phone offers now (`offered`) first, the rest in
/// their order on the line. Nothing is dropped: the phone's reading only orders the list it may have wrong.
func changesToName(_ changes: [EarlyChange], offered: EarlyChange?) -> [EarlyChange] {
    guard let o = offered, let i = changes.firstIndex(of: o) else { return changes }
    var out = changes
    out.insert(out.remove(at: i), at: 0)
    return out
}

/// The change to offer now, on the train `c`: the latest one at a station the train has reached (by the feed, put back
/// to the platform, `leadSec` early as it pulls in), until `holdSec` after it was there, time for a rider to reach for the
/// phone once on the other train; nil before the first or once all are well behind. `stopTs` keys are stop indices on the
/// ridden line, as in `BoardingCandidate`.
func earlyChangeOffer(_ changes: [EarlyChange], train c: BoardingCandidate, now: Double, leadSec: Double = 60, holdSec: Double = 600) -> (change: EarlyChange, atTs: Double)? {
    var best: (change: EarlyChange, atTs: Double)?
    for ch in changes {
        guard let feedTs = c.stopTs[ch.stopIdx] else { continue }
        let at = PlatformTiming.atPlatform(feedTs, route: c.route)
        if now >= at - leadSec, now <= at + holdSec, at > (best?.atTs ?? -.infinity) { best = (ch, at) }
    }
    return best
}

/// When the rider stepped off at `ch`, as the ride's record has it: the train's arrival there by the feed, put back to
/// its doors opening, plus the step across; failing a time for that stop, now.
func earlyChangeAlightTs(_ ch: EarlyChange, train c: BoardingCandidate?, now: Double) -> Double {
    guard let c = c, let feedTs = c.stopTs[ch.stopIdx] else { return now }
    return min(now, PlatformTiming.doorsOpen(feedTs, route: c.route) + TransferTiming.stepAcrossSec)
}
