import Foundation

// The rider's own word on the train: every train they could be on at a station, for the "On a train?" sheet.
//
// The sheet is the override for when detection is wrong, so it must not be filtered by the logic it overrides. Until
// Nov 5 it listed only trains that had already left, on lines with a route to the destination, in the plan's
// direction, short of the plan's alighting stop: a rider who had just stepped onto a standing train, or taken a line
// the planner did not rank, could not name it. Here nothing is hidden for being unlikely; likelihood only orders.

/// Every train on every line that stops at `station`, in both directions: standing or arriving there within
/// `lookAheadSec`, or gone from it within `lookBackSec`. `planKeys` are the lines of the leg in hand, listed first
/// among trains about as near in time; `boardTs` is the feed's time at the station (estimated back from the next stop
/// for a train that has left). No alighting stop is assumed: a picked train's own route is found from it.
func trainsToPick(boards: [String: LineBoard], schedule: ClientSchedule, station: Station, planKeys: Set<String>, now: Double,
                  lookBackSec: Double = 1500, lookAheadSec: Double = 600) -> [BoardingCandidate] {
    var out: [BoardingCandidate] = []
    var seen = Set<String>()
    for m in station.members {
        guard let lb = boards[m.key] else { continue }
        let bi = m.idx
        for t in lb.trains where !seen.contains(t.id) {
            guard let board = timeAtStation(t, idx: bi, line: schedule.lines[m.key]) else { continue }
            let left = t.nextIdx > bi
            guard left ? board >= now - lookBackSec : board <= now + lookAheadSec else { continue }
            seen.insert(t.id)
            var stopTs: [Int: Double] = [:]
            for p in t.points where p.idx > bi { stopTs[p.idx] = p.ts }
            let standing = t.position.map { $0.status == "STOPPED_AT" && $0.stopIdx == bi } ?? false
            out.append(BoardingCandidate(trainId: t.id, key: m.key, route: t.route, boardTs: board, alightTs: nil, stopsToAlight: nil, chosen: false,
                                         onLeg: planKeys.contains(m.key), boardIdx: bi, alightIdx: nil, stoppedAtBoardTs: standing ? now : nil,
                                         stopTs: stopTs, progressIdx: t.nextIdx, samePlatform: planKeys.contains(m.key), atOrigin: bi == 0))
        }
    }
    return out.sorted { pickOrder($0, now: now) < pickOrder($1, now: now) || (pickOrder($0, now: now) == pickOrder($1, now: now) && $0.trainId < $1.trainId) }
}

/// Nearest the moment first, a train at the platform now before all; the leg's own lines a minute ahead of the rest.
private func pickOrder(_ c: BoardingCandidate, now: Double) -> Double {
    if c.stoppedAtBoardTs != nil { return c.onLeg ? -2 : -1 }
    return abs(PlatformTiming.pullsAway(c.boardTs, route: c.route) - now) - (c.onLeg ? 60 : 0)
}

/// The feed's time for a train at stop `idx`: its own, while it lists the stop; back from its next stop by the
/// timetable's run once it has gone past; failing a run, about 90 s a stop.
private func timeAtStation(_ t: LiveTrain, idx: Int, line: LineTopology?) -> Double? {
    if let p = t.points.first(where: { $0.idx == idx }) { return p.ts }
    guard t.nextIdx > idx, let next = t.points.first(where: { $0.idx >= t.nextIdx }) else { return nil }
    if let run = line?.runBetween(idx, next.idx) { return next.ts - Double(run) }
    return next.ts - 90 * Double(next.idx - idx)
}
