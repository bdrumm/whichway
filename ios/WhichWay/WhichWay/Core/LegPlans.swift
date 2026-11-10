import Foundation

/// The legs of `p` as the trip's decisions need them (`LegPlan`): each leg's lines and stop indices, the line and train
/// the plan picked, the walk before boarding, the other lines at the boarding platform in the same direction and how well
/// each suits the trip (`platformLineFit`), times the rider's own habits there (`habit`, nil for none). The planner's view
/// and the trip replay build the legs the same way, here.
///
/// `chosen` is the plan's train per leg (its line and train id, from the live itinerary), `preferred` a line the rider
/// named for a leg (kept when the leg still has it), `liveWalkSec` the walk the live itinerary planned at the change.
func makeLegPlans(_ p: PathOption, schedule: ClientSchedule, index: StationIndex, originId: String, destId: String,
                  chosen: [Int: (key: String, trainId: String)] = [:], preferred: [Int: String] = [:], liveWalkSec: Double? = nil,
                  habit: ((_ boardAt: String, _ leg: Int) -> LinePrior?)? = nil) -> [LegPlan] {
    var plans: [LegPlan] = []
    // the stations where a line to the destination calls and the leg's own lines do not: a line at the platform that
    // reaches one is a sensible change
    let destSt = index.stationOf(destId)
    let lineStops = schedule.lines.mapValues { $0.stops }
    for (i, leg) in p.legs.enumerated() {
        let changeStations = sensibleChangeStations(lines: lineStops, dest: destSt, legKeys: leg.keys, station: index.stationOf)
        let tc = chosen[i]
        let pref = preferred[i].flatMap { leg.keys.contains($0) ? $0 : nil }
        var plan = LegPlan(keys: leg.keys, idx: leg.idx, chosenKey: pref ?? tc?.key ?? leg.primaryKey,
                           chosenTrainId: pref == nil || pref == tc?.key ? tc?.trainId : nil, origin: originId, dest: destId)
        // 0 marks a change made standing (across the platform): the recorder then watches for the train moving on
        plan.walkSec = i == 0 || p.transfer?.acrossPlatform == true ? 0 : (liveWalkSec ?? Double(p.transfer?.walkSec ?? 0))
        let dir = String((plan.chosenKey ?? "").split(separator: "_").last ?? "")
        if let st = index.stations[index.stationOf(leg.from)] {
            for m in st.members where m.dir == dir && !leg.keys.contains(m.key) {
                plan.platformKeys[m.key] = m.idx
                if m.stop != leg.from { plan.otherPlatformKeys.insert(m.key) }
                if let line = schedule.lines[m.key], m.idx + 1 < line.stops.count {
                    let after = line.stops[(m.idx + 1)...].map { index.stationOf($0) }
                    plan.lineFit[m.key] = platformLineFit(stationsAfter: Array(after), targets: [destSt, index.stationOf(leg.to)], changeStations: changeStations)
                }
            }
        }
        // the rider's own lines boarding here at about this hour (`RouteHabits.linePrior`); 1 where habits say nothing
        let boardAt = i == 0 ? originId : (p.transfer?.station ?? "")
        if let h = habit?(boardAt, i) {
            for (k, f) in h.fit(leg.keys + Array(plan.platformKeys.keys)) { plan.lineFit[k, default: 1] *= f }
        }
        plans.append(plan)
    }
    return plans
}
