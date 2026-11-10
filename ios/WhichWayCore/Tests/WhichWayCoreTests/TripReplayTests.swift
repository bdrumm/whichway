import XCTest
@testable import WhichWayCore

// The stored trips through the current decisions (CLAUDE.md, transfers rule 4). Runs only when WHICHWAY_REPLAY points at
// the fixtures `python -m pipeline.trip_replay` writes (git-ignored: the rider's movements never enter the repository);
// WHICHWAY_SCHEDULE is the client schedule the routes are planned on. Each trip's motion trace goes into `RideSession`
// second by second, with the feed's boards every 30 s rebuilt from the trains the store recorded (each train lists the
// stops still ahead of it at the time the store kept there, and stands at a stop while the store had it standing), the
// route planned as the phone planned it, and the planner's follow-ups the view makes (a route that rides the line
// called, a change named or read from a tap, staying on). Run once on the motion alone, once with the rider's own taps
// at the moments they made them. The report goes beside the fixtures.

/// One trip's fixture, as `pipeline/trip_replay.py` writes it.
struct ReplayFixture: Decodable {
    struct Leg: Decodable { var line: String?; var from: String?; var to: String? }
    struct Event: Decodable { var kind: String; var ts: Double }
    struct Boarded: Decodable { var leg: Int; var key: String; var trainId: String?; var verdict: String?; var confidence: Double? }
    struct Trip: Decodable {
        var id: String
        var createdTs: Double
        var endedTs: Double?
        var endedBy: String?
        var startedBy: String?
        var startDistanceM: Double?
        var routeLabel: String?
        var transferStation: String?
        var legs: [Leg]
        var events: [Event]?
        var notOnTrainTaps: [Double]?
        var changedEarlyTaps: [Double]?
        var boarded: [Boarded]?
        var appBuild: String?
        var predictedBoardTs: Double?
        var predictedArriveTs: Double?
    }
    struct Trace: Decodable { var columns: [String]?; var seconds: [[Double]] }
    struct TruthLeg: Decodable { var leg: Int?; var riderRoute: String?; var riderTransfer: String?; var train: String?; var route: String?; var matchedBy: String? }
    struct Truth: Decodable { var riderLines: [String]?; var legs: [TruthLeg]?; var missedChange: Bool?; var falseStart: Bool? }
    var trip: Trip
    var trace: Trace
    var arrivals: [[ReplayValue]]
    var dwells: [[ReplayValue]]
    var truth: Truth?
}

/// A cell of the store's rows: text or a number (or nothing).
enum ReplayValue: Decodable {
    case s(String), d(Double), none
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .none } else if let d = try? c.decode(Double.self) { self = .d(d) } else { self = .s(try c.decode(String.self)) }
    }
    var str: String? { if case let .s(v) = self { return v }; return nil }
    var num: Double? { if case let .d(v) = self { return v }; return nil }
}

/// The feed as the store recorded it, served as boards at any moment.
struct ReplayFeed {
    struct Stop { var stop: String; var arrive: Double; var depart: Double? }
    /// Per trip id: its route, direction and stops in time order.
    var trips: [String: (route: String, dir: String, stops: [Stop])] = [:]
    /// Per trip id and stop: when the store had it standing there.
    var dwell: [String: [String: (Double, Double)]] = [:]

    init(_ fx: ReplayFixture) {
        for r in fx.arrivals {
            guard r.count >= 6, let id = r[0].str, let route = r[1].str, let stop = r[3].str, let at = r[4].num else { continue }
            let dir = String(stop.suffix(1))
            var t = trips[id] ?? (route, dir, [])
            t.stops.append(Stop(stop: stop, arrive: at, depart: r[5].num))
            trips[id] = t
        }
        for (id, t) in trips { trips[id] = (t.route, t.dir, t.stops.sorted { $0.arrive < $1.arrive }) }
        for r in fx.dwells {
            guard r.count >= 4, let id = r[0].str, let stop = r[1].str, let a = r[2].num, let b = r[3].num else { continue }
            dwell[id, default: [:]][stop] = (a, b)
        }
    }

    /// Line `key`'s board at `now`: every train of its route and direction with a stop of the line still ahead (a stop is
    /// listed until the train leaves it), its points those stops at the store's times.
    func board(_ key: String, line: LineTopology, now: Double) -> LineBoard {
        let parts = key.split(separator: "_").map(String.init)
        let route = parts.first ?? "", dir = parts.count > 1 ? parts[1] : ""
        var idxOf: [String: Int] = [:]
        for (i, s) in line.stops.enumerated() where idxOf[s] == nil { idxOf[s] = i }
        var trains: [LiveTrain] = []
        for (id, t) in trips where t.route == route && t.dir == dir {
            guard let first = t.stops.first, first.arrive <= now + 1800 else { continue }
            var pts: [TrainPoint] = []
            var standing: (idx: Int, stop: String)?
            for s in t.stops {
                guard let i = idxOf[s.stop] else { continue }
                let leaves = s.depart ?? (dwell[id]?[s.stop]?.1) ?? (s.arrive + 20)
                if leaves <= now { continue }
                pts.append(TrainPoint(idx: i, ts: s.arrive))
                if let d = dwell[id]?[s.stop], d.0 <= now, now <= d.1 { standing = (i, s.stop) }
            }
            guard let next = pts.map(\.idx).min() else { continue }
            pts.sort { $0.idx < $1.idx }
            let pos = standing.map { TrainPosition(status: "STOPPED_AT", stopId: $0.stop, stopIdx: $0.idx, stopName: "", sinceSec: 0, holding: false,
                                                   stalled: false, atTerminal: $0.idx == 0) }
            trains.append(LiveTrain(key: key, tripId: id, trainId: nil, route: route, points: pts, nextIdx: next, nextName: "",
                                    etaTs: pts.first?.ts ?? now, schedTs: nil, schedMethod: nil, latenessSec: nil, effectiveLatenessSec: nil,
                                    position: pos, corroboration: "", trackChanged: false, started: true, segment: nil, lastRun: nil))
        }
        return LineBoard(key: key, route: route, direction: dir, now: now, trains: trains, nHolding: 0, nStalled: 0, nFeedOptimistic: 0)
    }
}

/// What one replay decided.
struct ReplayOutcome {
    var lines: [String] = []          // the decisions, in time order, for the report
    var legsRidden = 0
    var routeLegs = 0
    var called: [String] = []         // per leg: the line (and train) the session called at the end
    var endedBy: String?
    var routeLabel = ""
    var events: [MotionEvent] = []
    /// On the route's last train when the trace ran out: the trace stops where the phone ended the trip, so the walk-off
    /// at the destination is often not in it (and the replay has no location fixes to end the trip by). Not a miss.
    var onLastLegAtEnd = false
}

final class TripReplayTests: XCTestCase {
    func testReplayStoredTrips() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["WHICHWAY_REPLAY"], let schedPath = env["WHICHWAY_SCHEDULE"] else {
            throw XCTSkip("WHICHWAY_REPLAY and WHICHWAY_SCHEDULE not set: run `python -m pipeline.trip_replay`")
        }
        let sched = try JSONDecoder().decode(ClientSchedule.self, from: Data(contentsOf: URL(fileURLWithPath: schedPath)))
        let index = StationIndex(schedule: sched)
        let only = env["WHICHWAY_REPLAY_TRIP"]
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") && Double($0.dropLast(5)) != nil && (only == nil || $0.hasPrefix(only!)) }.sorted()
        var md = ["# Trip replay on current code", "",
                  "Each stored trip with a motion trace, replayed through `RideSession` with the feed rebuilt from the store. *auto*: the motion "
                  + "alone; *taps*: with the rider's own taps where they made them. *as recorded*: what the phone on the trip's build decided.", "",
                  "| trip | build | route | as recorded | auto | taps | rider / review |", "|---|---|---|---|---|---|---|"]
        var detail: [String] = []
        var summary: [[String: Any]] = []
        for f in files {
            let fx = try JSONDecoder().decode(ReplayFixture.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/" + f)))
            let feed = ReplayFeed(fx)
            guard let auto = replay(fx, feed: feed, sched: sched, index: index, taps: false) else { continue }
            let taps = replay(fx, feed: feed, sched: sched, index: index, taps: true)
            let recorded = recordedSummary(fx)
            let truth = truthSummary(fx)
            md.append("| \(day(fx.trip.createdTs)) | \(fx.trip.appBuild ?? "–") | \(fx.trip.routeLabel ?? "") | \(recorded) | \(short(auto)) | \(taps.map(short) ?? "–") | \(truth) |")
            var d = "## \(day(fx.trip.createdTs)) · \(fx.trip.routeLabel ?? "")\n\n"
            if fx.arrivals.isEmpty { d += "_no feed in the store for this trip_\n\n" }
            let autoLines: [String] = auto.lines.map { "- " + $0 }
            d += "auto:\n\n" + autoLines.joined(separator: "\n") + "\n\n"
            if let tp = taps {
                let tapLines: [String] = tp.lines.map { "- " + $0 }
                d += "taps:\n\n" + tapLines.joined(separator: "\n") + "\n"
            }
            detail.append(d)
            summary.append(["trip": fx.trip.id, "start": fx.trip.createdTs, "auto": short(auto), "taps": taps.map(short) ?? "", "recorded": recorded, "truth": truth,
                            "autoLegs": auto.legsRidden, "routeLegs": auto.routeLegs, "autoCalled": auto.called, "autoEndedBy": auto.endedBy ?? ""])
        }
        let out = (md + ["", "Times are local to the trip; every decision the session made is listed below.", ""] + detail).joined(separator: "\n")
        try out.write(toFile: dir + "/replay_report.md", atomically: true, encoding: .utf8)
        let js = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try js.write(to: URL(fileURLWithPath: dir + "/replay_report.json"))
    }

    // MARK: - one trip

    private func replay(_ fx: ReplayFixture, feed: ReplayFeed, sched: ClientSchedule, index: StationIndex, taps: Bool) -> ReplayOutcome? {
        let trip = fx.trip
        guard let first = trip.legs.first, let last = trip.legs.last, let from = first.from, let to = last.to else { return nil }
        let originId = index.stationOf(from), destId = index.stationOf(to)
        var options = enumeratePaths(schedule: sched, index: index, from: originId, to: destId, maxOptions: 400)
        // the route the trip started on: the option over the same stops
        let sig = trip.legs.map { "\($0.from ?? "")>\($0.to ?? "")" }.joined(separator: "|")
        guard var sel = options.first(where: { $0.id == sig })
                ?? options.first(where: { $0.legs.count == trip.legs.count && zip($0.legs, trip.legs).allSatisfy { index.stationOf($0.from) == index.stationOf($1.from ?? "") && index.stationOf($0.to) == index.stationOf($1.to ?? "") } })
        else { return nil }
        options = options.filter { $0.id != sel.id }
        let firstId = sel.id
        var out = ReplayOutcome()
        let tz = TimeZone(identifier: "America/New_York")!
        func hm(_ ts: Double) -> String {
            var c = Calendar(identifier: .gregorian); c.timeZone = tz
            let d = c.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: ts))
            return String(format: "%02d:%02d:%02d", d.hour ?? 0, d.minute ?? 0, d.second ?? 0)
        }
        // the line the trip's record has for each leg: the plan's own pick (the planner's live itinerary named it)
        var preferred: [Int: String] = [:]
        for (i, l) in trip.legs.enumerated() { if let k = l.line { preferred[i] = k } }
        func plans(_ p: PathOption, chosen: [Int: (key: String, trainId: String)] = [:]) -> [LegPlan] {
            makeLegPlans(p, schedule: sched, index: index, originId: originId, destId: destId, chosen: chosen, preferred: p.id == firstId ? preferred : [:])
        }
        var session = RideSession()
        session.changesOnTheWay = { [sel] in
            // the planner's list for the first leg: every change off each of its lines toward the destination
            var outCh: [EarlyChange] = [], seen = Set<String>()
            for k in sel.legs[0].keys {
                for ch in changesOnTheWay(from: sel, ridingKey: k, among: options, index: index) where !seen.contains(ch.option.id) { seen.insert(ch.option.id); outCh.append(ch) }
            }
            return outCh.sorted { $0.stopIdx != $1.stopIdx ? $0.stopIdx < $1.stopIdx : ($0.acrossPlatform && !$1.acrossPlatform) }
        }
        var chosen: [Int: (key: String, trainId: String)] = [:]
        if let b = trip.boarded { for x in b where x.leg == 0 { if let id = x.trainId { chosen[0] = (x.key, id) } } }
        let start = TripTimeline(startTs: trip.createdTs, startedBy: trip.startedBy ?? "gps", startDistanceM: trip.startDistanceM, originStation: originId,
                                 destStation: destId, transferStation: sel.transfer?.station, legs: sel.legs.count)
        session.begin(start, distanceToOriginM: trip.startDistanceM, legs: plans(sel), now: trip.createdTs)
        session.updateForecast(boardTs: trip.predictedBoardTs, arriveTs: trip.predictedArriveTs, now: trip.createdTs)
        out.routeLabel = sel.label
        out.lines.append("\(hm(trip.createdTs)) start on \(sel.label)")
        var keys = Set(sel.legs.flatMap { $0.keys })
        for p in plans(sel) { keys.formUnion(p.platformKeys.keys) }
        var lastLegs = 0, lastOn = false, lastBelief: [Int: String] = [:], lastPending = false
        var tapsLeft = taps ? ((trip.notOnTrainTaps ?? []).map { ($0, "not on the train") } + (trip.changedEarlyTaps ?? []).map { ($0, "changed trains") }).sorted { $0.0 < $1.0 } : []
        var lastSwitch = -Double.infinity
        let cols = fx.trace.columns ?? ["ts", "stepEnergy", "pushG", "shakeG"]
        let ix = Dictionary(uniqueKeysWithValues: cols.enumerated().map { ($1, $0) })
        var nextPoll = trip.createdTs, nextTick = trip.createdTs
        let verbose = ProcessInfo.processInfo.environment["WHICHWAY_REPLAY_VERBOSE"] != nil
        func note(_ ts: Double) {
            guard let t = session.tracker else { return }
            let legs = t.timeline.legsRidden
            if legs != lastLegs { out.lines.append("\(hm(ts)) legs ridden \(lastLegs) → \(legs)"); lastLegs = legs }
            if session.onTrain != lastOn { out.lines.append("\(hm(ts)) \(session.onTrain ? "on a train" : "off the train")"); lastOn = session.onTrain }
            if t.boardingPending != lastPending { out.lines.append("\(hm(ts)) \(t.boardingPending ? "boarding? (waiting on the feed)" : "boarding settled")"); lastPending = t.boardingPending }
            for b in session.beliefs {
                let s = "\(b.bestKey ?? "?") \(b.bestTrain.map { tripSuffix($0) } ?? "") \(String(format: "%.2f", b.confidence)) \(b.verdict.rawValue) [\(b.evidence.joined(separator: ","))]"
                if lastBelief[b.leg] != s {
                    out.lines.append("\(hm(ts)) leg \(b.leg): \(s)"); lastBelief[b.leg] = s
                    if verbose {
                        let top = b.byTrain.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key == LineBelief.noneKey ? "none" : tripSuffix($0.key)) \(String(format: "%.2f", $0.value))" }
                        out.lines.append("    trains: " + top.joined(separator: ", "))
                    }
                }
            }
        }
        // the planner's follow-ups (PlannerView: followBoarded, followEarlyChange, followStayingOn), on the replay's options
        func adopt(_ p: PathOption, why: String, at ts: Double) {
            sel = p
            session.replan(legs: plans(p), transferStation: p.transfer?.station, transferStops: nil)
            for pl in plans(p) { keys.formUnion(pl.keys); keys.formUnion(pl.platformKeys.keys) }
            out.lines.append("\(hm(ts)) route → \(p.label) (\(why))")
        }
        func follow(_ now: Double) {
            guard let t = session.tracker, t.phase == .riding else { return }
            if let c = session.changedEarly, c.change.option.id != sel.id {
                adopt(c.change.option, why: "change at \(c.change.stationName)", at: now)
                let next = c.change.option.legs[1]
                var cands: [BoardingCandidate] = []
                for k in next.keys {
                    guard let line = sched.lines[k], let span = next.idx[k] else { continue }
                    var lg = DepartureLog()
                    lg.observe(trains: feed.board(k, line: line, now: now).trains, key: k, boardIdx: span.from, span: span, onLeg: true, now: now)
                    cands += lg.candidates(departedTs: now, windowSec: 900, chosenTrainId: nil)
                }
                session.seedCurrentLeg(cands, now: now)
                return
            }
            if let s = session.stayedOn, sel.legs.indices.contains(s.leg) {
                let fits = (options + [sel]).filter { p in
                    guard p.legs.indices.contains(s.leg), let ix = p.legs[s.leg].idx[s.key], ix.to > s.pastIdx else { return false }
                    return index.stationOf(p.legs[s.leg].from) == index.stationOf(sel.legs[s.leg].from)
                }
                if let p = fits.min(by: { $0.schedSec < $1.schedSec }), p.id != sel.id { adopt(p, why: "stayed on the \(s.key)", at: now) }
                return
            }
            let leg = t.timeline.legsRidden
            if sel.legs.indices.contains(leg), let key = session.lineToFollow(routeKeys: sel.legs[leg].keys, now: now, lastSwitchTs: lastSwitch) {
                let fits = (options + [sel]).filter { p in
                    guard p.legs.indices.contains(leg), p.legs[leg].keys.contains(key) else { return false }
                    if leg > 0, index.stationOf(p.legs[leg].from) != index.stationOf(sel.legs[leg].from) { return false }
                    for i in 0..<leg where index.stationOf(p.legs[i].from) != index.stationOf(sel.legs[i].from) || index.stationOf(p.legs[i].to) != index.stationOf(sel.legs[i].to) { return false }
                    return true
                }
                if let p = fits.min(by: { $0.schedSec < $1.schedSec }) { lastSwitch = now; adopt(p, why: "the phone called the \(key)", at: now) }
            }
        }
        for row in fx.trace.seconds {
            guard let ts = row[safe: ix["ts"] ?? 0] else { continue }
            while nextPoll <= ts {
                var boards: [String: LineBoard] = [:]
                for k in keys { if let line = sched.lines[k] { boards[k] = feed.board(k, line: line, now: nextPoll) } }
                session.observeBoards(boards, now: nextPoll)
                note(nextPoll)
                follow(nextPoll)
                nextPoll += 30
            }
            while nextTick <= ts { session.tick(now: nextTick); nextTick += 5 }
            while let tap = tapsLeft.first, tap.0 <= ts {
                tapsLeft.removeFirst()
                out.lines.append("\(hm(tap.0)) the rider taps \"\(tap.1)\"")
                if tap.1 == "not on the train" { session.notOnTrain(now: tap.0) } else if let ec = session.earlyChange { session.takeChange(ec.change, alightTs: ec.alightTs, now: tap.0) }
                note(tap.0); follow(tap.0)
            }
            let m = MotionSecond(ts: ts, stepEnergy: row[safe: ix["stepEnergy"] ?? 1] ?? 0, pushG: row[safe: ix["pushG"] ?? 2] ?? 0, shakeG: row[safe: ix["shakeG"] ?? 3] ?? 0)
            session.motion(m)
            note(ts)
            if session.tracker?.phase == .arrived { break }
        }
        let t = session.tracker
        out.legsRidden = t?.timeline.legsRidden ?? 0
        out.routeLegs = sel.legs.count
        out.onLastLegAtEnd = t.map { $0.onTrain && $0.timeline.legsRidden == sel.legs.count - 1 } ?? false
        out.events = t?.timeline.events ?? []
        out.endedBy = t?.timeline.endedBy
        out.called = (0..<sel.legs.count).map { l in
            guard let b = session.belief(leg: l) else { return "–" }
            return "\(b.route ?? "?")\(b.settled ? "" : "?")"
        }
        out.routeLabel = sel.label
        if let e = out.endedBy { out.lines.append("ended: \(e)") }
        return out
    }

    private func short(_ o: ReplayOutcome) -> String {
        "\(o.called.joined(separator: "→")) · \(o.legsRidden)/\(o.routeLegs) legs\(o.legsRidden >= o.routeLegs ? "" : o.onLastLegAtEnd ? " (on the last train at trace end)" : " **short**")" + (o.routeLabel.isEmpty ? "" : " · \(o.routeLabel)")
    }

    private func recordedSummary(_ fx: ReplayFixture) -> String {
        let b = (fx.trip.boarded ?? []).sorted { $0.leg < $1.leg }.map { "\(String($0.key.split(separator: "_").first ?? ""))\($0.verdict == "unsure" ? "?" : "")" }
        let n = (fx.trip.events ?? []).filter { $0.kind == "alighted" }.count
        return "\(b.joined(separator: "→")) · \(n)/\(fx.trip.legs.count) legs · \(fx.trip.endedBy ?? "")"
    }

    private func truthSummary(_ fx: ReplayFixture) -> String {
        guard let t = fx.truth else { return "–" }
        if let r = t.riderLines, !r.isEmpty { return "rider: " + r.joined(separator: "→") }
        let m = (t.legs ?? []).map { "\($0.route ?? "–")" + ($0.matchedBy == "phone" ? "ᵖ" : "") }
        return m.isEmpty ? "–" : "review: " + m.joined(separator: "→")
    }

    private func day(_ ts: Double) -> String {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "America/New_York"); f.dateFormat = "EEE MMM d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
