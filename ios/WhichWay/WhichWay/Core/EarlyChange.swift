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
func earlierChanges(from sel: PathOption, ridingKey: String, among options: [PathOption], index: StationIndex) -> [EarlyChange] {
    guard sel.legs.count == 2, let planned = sel.legs[0].idx[ridingKey]?.to else { return [] }
    let origin = index.stationOf(sel.legs[0].from), dest = index.stationOf(sel.legs[1].to)
    var out: [EarlyChange] = []
    var seen = Set<String>()
    for p in options where p.legs.count == 2 && !seen.contains(p.id) {
        guard let ix = p.legs[0].idx[ridingKey], ix.to < planned, let tr = p.transfer,
              index.stationOf(p.legs[0].from) == origin, index.stationOf(p.legs[1].to) == dest else { continue }
        seen.insert(p.id)
        let st = index.stationOf(p.legs[0].to)
        out.append(EarlyChange(option: p, station: st, stationName: tr.station, stopIdx: ix.to, nextKeys: p.legs[1].keys, acrossPlatform: tr.acrossPlatform))
    }
    return out.sorted { $0.stopIdx != $1.stopIdx ? $0.stopIdx < $1.stopIdx : ($0.acrossPlatform && !$1.acrossPlatform) }
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
/// the platform, plus the step to the doors; failing a time for that stop, now.
func earlyChangeAlightTs(_ ch: EarlyChange, train c: BoardingCandidate?, now: Double) -> Double {
    guard let c = c, let feedTs = c.stopTs[ch.stopIdx] else { return now }
    return min(now, PlatformTiming.atPlatform(feedTs, route: c.route) + TransferTiming.stepAcrossSec)
}
