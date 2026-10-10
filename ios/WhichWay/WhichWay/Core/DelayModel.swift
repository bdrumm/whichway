import Foundation

/// The delay-alert lifecycle model published as delay_model.json (pipeline/delay_model.py; the exercise is written
/// up in docs/delay_model_report.md): how long an unplanned delay alert stays posted, by line and cause, as survival
/// curves since creation and relative to the MTA's stated end; and how soon alerts are gone once the feed shows the
/// stops around the named station back to normal. `assess` reads a live alert against it and against the boards.
struct DelayModel: Decodable {
    struct Curve: Decodable {
        var n: Int
        var survival: [Double]
    }
    struct Lifetime: Decodable {
        var all: Curve?
        var byRoute: [String: Curve]?
        var byCause: [String: Curve]?
        var byRouteCause: [String: Curve]?
        var relative: Relative?
        enum CodingKeys: String, CodingKey { case all, byRoute = "by_route", byCause = "by_cause", byRouteCause = "by_route_cause", relative }
    }
    struct Relative: Decodable {
        var gridStart: Double
        var all: Curve?
        var byCause: [String: Curve]?
        var byRoute: [String: Curve]?
        enum CodingKeys: String, CodingKey { case gridStart = "grid_start", all, byCause = "by_cause", byRoute = "by_route" }
    }
    struct Stale: Decodable {
        struct Row: Decodable {
            var n: Int
            var shareRemovedWithin30: Double
            enum CodingKeys: String, CodingKey { case n, shareRemovedWithin30 = "share_removed_within_30" }
        }
        var all: Row?
        var byCause: [String: Row]?
        enum CodingKeys: String, CodingKey { case all, byCause = "by_cause" }
    }
    struct Prewarn: Decodable {
        struct Rate: Decodable {
            var n: Int
            var pAlert30: Double
            var pAlert60: Double
            enum CodingKeys: String, CodingKey { case n, pAlert30 = "p_alert_30", pAlert60 = "p_alert_60" }
        }
        struct Severity: Decodable {
            var loss: String
            var trains: String
            var lossLo: Double
            var minTrains: Int
            var n: Int
            var pAlert30: Double
            var pAlert60: Double
            /// the station-local rows carry what chance alone gives and the lift over it
            var chance30: Double?
            var lift30: Double?
            var chance60: Double?
            var lift60: Double?
            enum CodingKeys: String, CodingKey { case loss, trains, lossLo = "loss_lo", minTrains = "min_trains", n, pAlert30 = "p_alert_30", pAlert60 = "p_alert_60",
                                                 chance30 = "chance_30", lift30 = "lift_30", chance60 = "chance_60", lift60 = "lift_60" }
        }
        /// The station-local test: an alert naming a stop within a few of the slowdown's segment, against chance.
        struct Local: Decodable {
            struct FromSlowdowns: Decodable {
                var n: Int
                var pAlert30: Double
                var chance30: Double?
                var lift30: Double?
                var pAlert60: Double
                var chance60: Double?
                var lift60: Double?
                var bySeverity: [Severity]?
                enum CodingKeys: String, CodingKey { case n, pAlert30 = "p_alert_30", chance30 = "chance_30", lift30 = "lift_30", pAlert60 = "p_alert_60",
                                                     chance60 = "chance_60", lift60 = "lift_60", bySeverity = "by_severity" }
            }
            var fromSlowdowns: FromSlowdowns?
            enum CodingKeys: String, CodingKey { case fromSlowdowns = "from_slowdowns" }
        }
        var all: Rate?
        var bySeverity: [Severity]?
        var byRoute: [String: Rate]?
        var local: Local?
        enum CodingKeys: String, CodingKey { case all, bySeverity = "by_severity", byRoute = "by_route", local }
    }
    var version: Int
    var gridMin: Double
    var nEvents: Int
    var lifetime: Lifetime
    var stale: Stale
    /// The phases (section 7 of the report): when the feed first shows an alert's delay, which sets how long a
    /// fresh alert reads as starting, and how alerts in each phase go on from there (the chance of being gone
    /// within 15, 30 and 60 minutes), overall and by cause.
    struct Phases: Decodable {
        struct Evidence: Decodable {
            var startMin: Double
            var neverMin: Double
            var shareSeenEver: Double?
            enum CodingKeys: String, CodingKey { case startMin = "start_min", neverMin = "never_min", shareSeenEver = "share_seen_ever" }
        }
        struct Row: Decodable {
            var nAlerts: Int?
            var nGone30: Int?
            var pGone15: Double?
            var pGone30: Double?
            var pGone60: Double?
            enum CodingKeys: String, CodingKey { case nAlerts = "n_alerts", nGone30 = "n_gone_30", pGone15 = "p_gone_15", pGone30 = "p_gone_30", pGone60 = "p_gone_60" }
        }
        struct CauseRows: Decodable {
            var phases: [String: Row]?
        }
        var marginSec: Double?
        var staleMin: Double?
        var evidence: Evidence?
        var byPhase: [String: Row]?
        var byCause: [String: CauseRows]?
        enum CodingKeys: String, CodingKey { case marginSec = "margin_sec", staleMin = "stale_min", evidence, byPhase = "by_phase", byCause = "by_cause" }
    }
    var prewarn: Prewarn?
    var phases: Phases?
    enum CodingKeys: String, CodingKey { case version, gridMin = "grid_min", nEvents = "n_events", lifetime, stale, prewarn, phases }

    static let minGroupN = 8
    /// A line whose trains run within two minutes of the timetable reads as normal.
    static let normalLatenessSec = 120.0

    // MARK: curves

    /// S(t) from a grid curve, linearly between points, held at the ends.
    private static func interp(_ curve: [Double], start: Double, step: Double, _ t: Double) -> Double {
        guard !curve.isEmpty else { return 1 }
        let x = (t - start) / step
        if x <= 0 { return curve[0] }
        if x >= Double(curve.count - 1) { return curve[curve.count - 1] }
        let i = Int(x), f = x - Double(i)
        return curve[i] * (1 - f) + curve[i + 1] * f
    }

    /// The most specific curve with enough behind it: line and cause, cause, line, all alerts.
    private func pick(routes: [String], cause: String, relative: Bool) -> (curve: [Double], start: Double, basis: String) {
        if relative, let r = lifetime.relative {
            if let c = r.byCause?[cause], c.n >= DelayModel.minGroupN { return (c.survival, r.gridStart, "alerts for \(DelayModel.causeWords(cause))") }
            for route in routes { if let c = r.byRoute?[route], c.n >= DelayModel.minGroupN { return (c.survival, r.gridStart, "alerts on the \(route)") } }
            return (r.all?.survival ?? [], r.gridStart, "all alerts")
        }
        for route in routes { if let c = lifetime.byRouteCause?["\(route)|\(cause)"], c.n >= DelayModel.minGroupN { return (c.survival, 0, "\(DelayModel.causeWords(cause)) on the \(route)") } }
        if let c = lifetime.byCause?[cause], c.n >= DelayModel.minGroupN { return (c.survival, 0, "alerts for \(DelayModel.causeWords(cause))") }
        for route in routes { if let c = lifetime.byRoute?[route], c.n >= DelayModel.minGroupN { return (c.survival, 0, "alerts on the \(route)") } }
        return (lifetime.all?.survival ?? [], 0, "all alerts")
    }

    /// P(gone within h | still posted at t) for h = 15, 30, 60, and the expected remaining minutes (capped at the grid).
    private func clearProbabilities(_ curve: [Double], start: Double, _ t: Double) -> (p15: Double, p30: Double, p60: Double, expected: Double) {
        let step = gridMin
        let s0 = max(DelayModel.interp(curve, start: start, step: step, t), 0.02)
        func p(_ h: Double) -> Double { max(0, min(1, 1 - DelayModel.interp(curve, start: start, step: step, t + h) / s0)) }
        let end = start + step * Double(max(0, curve.count - 1))
        var expected = 0.0
        if end > t {
            var x = t
            var prev = 1.0
            while x < end {
                let nx = min(end, x + 1)
                let s = min(1, DelayModel.interp(curve, start: start, step: step, nx) / s0)
                expected += (prev + s) / 2 * (nx - x)
                prev = s; x = nx
            }
        }
        return (p(15), p(30), p(60), expected)
    }

    // MARK: the assessment

    /// A name as the schedule and the alert might each spell it: letters and digits only, lowercase.
    static func normName(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The phase from what is knowable now: the alert's age, the feed's excess near its station now (nil: no
    /// reading), whether the feed has shown the delay at any point, the peak so far, and how long the stops have
    /// read normal since (the rules of analysis/phases.py, calibrated in section 7 of the report).
    static func phaseNow(age: Double, excess: Double?, seen: Bool, peak: Double, recoveredMin: Double?, neverMin: Double, margin: Double, staleMin: Double) -> DelayAssessment.Phase {
        if let e = excess, e >= margin { return e >= 0.5 * peak ? .inEffect : .waning }
        if seen { return (recoveredMin ?? 0) < staleMin || recoveredMin == nil ? .waning : .stale }
        return age < neverMin ? .starting : .unconfirmed
    }

    /// P(gone within 30 min) for alerts in this phase: the cause's own rate where the record is deep enough,
    /// shrunk toward all alerts; nil without the phase tables.
    private func phaseGone30(_ phase: DelayAssessment.Phase, cause: String) -> Double? {
        guard let ph = phases, let overall = ph.byPhase?[phase.rawValue]?.pGone30 else { return nil }
        if let row = ph.byCause?[cause]?.phases?[phase.rawValue], let n = row.nGone30, n >= DelayModel.minGroupN, let p = row.pGone30 {
            return (Double(n) * p + 10 * overall) / (Double(n) + 10)
        }
        return overall
    }

    /// A live unplanned delay alert read against the curves, the boards of its lines (the trains near the station
    /// it names, now), the lateness the phone has seen on those lines while open (the trajectory: a peak, a
    /// recovery) and, when fresh, the server's own reading from the store. The phase, starting / in effect / waning
    /// / stale / unconfirmed, follows section 7 of the report; the chance of being gone within 30 minutes is the
    /// phase's own record, by cause where deep enough.
    func assess(_ a: RouteAlert, now: Double, boards: [LineBoard], lines: [String: LineTopology] = [:],
                history: [LatenessSample] = [], published: PublishedAssessment? = nil) -> DelayAssessment {
        let cause = DelayModel.classifyCause(a.header)
        let created = a.createdAt ?? a.start ?? now
        let age = max(0, (now - created) / 60)
        let statedEnd: Double? = (a.end ?? 0) > created ? a.end : nil
        let probs: (p15: Double, p30: Double, p60: Double, expected: Double)
        let basis: String
        if let e = statedEnd {
            let (curve, start, b) = pick(routes: a.routes, cause: cause, relative: true)
            probs = clearProbabilities(curve, start: start, (now - e) / 60)
            basis = b
        } else {
            let (curve, start, b) = pick(routes: a.routes, cause: cause, relative: false)
            probs = clearProbabilities(curve, start: start, age)
            basis = b
        }
        let station = DelayModel.station(in: a.header)
        let direction = DelayModel.direction(in: a.header)
        let margin = phases?.marginSec ?? DelayModel.normalLatenessSec
        let neverMin = phases?.evidence?.neverMin ?? 30
        let staleMin = phases?.staleMin ?? 10

        // the feed now: the trains within three stops of the named station on the boards, in the direction named,
        // else the whole line
        var lates: [Double] = [], near: [Double] = []
        var held = 0, heldNear = 0
        let want = station.map(DelayModel.normName)
        for b in boards {
            if (direction == "N" && b.direction == "S") || (direction == "S" && b.direction == "N") { continue }
            let idx: Int? = want.flatMap { w in lines[b.key]?.names.firstIndex { DelayModel.normName($0) == w } }
            for t in b.trains where t.started {
                guard let l = t.effectiveLatenessSec else { continue }
                lates.append(l)
                let stuck = t.position?.holding == true || t.position?.stalled == true
                if stuck { held += 1 }
                if let i = idx, abs((t.position?.stopIdx ?? t.nextIdx) - i) <= 3 {
                    near.append(l)
                    if stuck { heldNear += 1 }
                }
            }
        }
        let local = near.count >= 2
        let sample = local ? near : lates
        let seenNow = sample.count >= 2
        let late = seenNow ? sample.sorted()[sample.count / 2] : 0
        let heldHere = local ? heldNear : held
        let feedActive = seenNow && (late >= margin || heldHere > 0)
        let feedNormal = seenNow && late < margin && heldHere == 0

        // the trajectory as the phone has seen it: the lateness on these lines at each poll since the alert was posted
        var seen = feedActive
        var peak = feedActive ? late : 0.0
        var lastLateTs: Double? = feedActive ? now : nil
        for smp in history where smp.ts >= created {
            if smp.latenessSec >= margin || smp.held > 0 {
                seen = true
                peak = max(peak, smp.latenessSec)
                lastLateTs = max(lastLateTs ?? 0, smp.ts)
            }
        }
        var recoveredMin: Double? = (seen && !feedActive && lastLateTs != nil) ? (now - lastLateTs!) / 60 : nil
        var excessNow: Double? = seenNow ? late : nil
        var phase = DelayModel.phaseNow(age: age, excess: excessNow, seen: seen, peak: peak, recoveredMin: recoveredMin, neverMin: neverMin, margin: margin, staleMin: staleMin)
        var source = "phone"
        // the server's reading from the store, the whole trajectory since posting, when fresh: the phone's own
        // history begins when the app opened, so the server knows of a peak and a recovery the phone never saw.
        // The boards are fresher than the server, so trains late near the station now stay in effect.
        if let pub = published, now - pub.generatedAt < 20 * 60, let ph = DelayAssessment.Phase(rawValue: pub.phase ?? ""), !feedActive {
            phase = ph
            source = "server"
            if let pk = pub.peakExcessSec { peak = max(peak, pk) }
            if let r = pub.recoveredMin { recoveredMin = r }
            if excessNow == nil, let e = pub.excessNowSec { excessNow = e }
            seen = seen || pub.seen
            if ph == .inEffect && feedNormal { phase = .waning; recoveredMin = nil }
        }
        if age >= 240 && (phase == .unconfirmed || phase == .starting) { phase = .stale }
        let pGone30 = phaseGone30(phase, cause: cause) ?? probs.p30

        let routes = a.routes.joined(separator: "/")
        let whereTxt = (local && station != nil) ? "near \(station!)" : "on the \(routes)"
        let gone = "\(Int((pGone30 * 100).rounded()))% of such alerts gone within 30 min"
        var bits: [String]
        switch phase {
        case .inEffect:
            bits = ["trains \(Fmt.late(max(0, excessNow ?? late))) \(whereTxt), \(Int(age)) min in"]
            if probs.expected > 0 { bits.append("typically \(Int(probs.expected)) min to go") }
        case .waning:
            if let e = excessNow, e >= margin / 2, peak > 0, e < peak { bits = ["delay down to \(Fmt.minTxt(e)) from \(Fmt.minTxt(peak)) \(whereTxt)"] }
            else if let r = recoveredMin { bits = [r >= 1 ? "trains back to normal \(whereTxt) \(Int(r)) min ago" : "trains just back to normal \(whereTxt)"] }
            else { bits = ["trains back to normal \(whereTxt)"] }
            bits.append(gone)
        case .stale:
            if seen, let r = recoveredMin { bits = ["trains normal \(whereTxt) for \(Int(r)) min after a \(Fmt.minTxt(peak)) delay"] }
            else if seen { bits = ["trains normal \(whereTxt) again"] }
            else { bits = ["posted \(Int(age / 60)) h ago with nothing in the feed \(whereTxt) since"] }
            bits.append(gone)
        case .starting:
            bits = ["posted \(Int(age)) min ago, nothing in the feed \(whereTxt) yet; alerts that register do so within \(Int(neverMin)) min"]
        case .unconfirmed:
            bits = ["nothing in the feed \(whereTxt) \(Int(age)) min after posting", gone]
        }
        let interpretation = phase.word + " · " + bits.joined(separator: " · ")
        let at = station.map { " at \($0)" } ?? ""
        var head = ["\(DelayModel.causeWords(cause)) on the \(routes)\(at)", "posted \(Fmt.hhmm(created)) (\(Int(age)) min ago)"]
        if let e = statedEnd { head.append("MTA's end \(Fmt.hhmm(e))" + (now > e ? " passed" : "")) }
        let short = "delay alert on the \(routes)\(at): \(phase.word)"
            + (feedActive ? ", trains \(Fmt.late(late))" : (feedNormal ? ", trains on time" : "")) + (phase == .inEffect ? "" : ", posted \(Fmt.hhmm(created))")
        return DelayAssessment(cause: cause, station: station, direction: direction, postedTs: created, ageMin: age,
                               statedEndTs: statedEnd, pClear15: probs.p15, pClear30: probs.p30, pClear60: probs.p60, expectedRemainingMin: probs.expected,
                               feedSeen: seenNow, latenessSec: late, held: heldHere, phase: phase, pGone30: pGone30, excessSec: excessNow, peakSec: peak,
                               recoveredMin: recoveredMin, local: local, source: source, basis: basis, interpretation: interpretation,
                               text: head.joined(separator: " · ") + " · " + interpretation, short: short)
    }

    // MARK: the pre-warning

    /// Slowdowns the boards show right now: on one segment of a line, at least two trains and at least 60% of
    /// those whose last run the phone timed lost two minutes or more against the scheduled run (the server's
    /// detector over the arrivals, read here from the trains' last runs). Scored with the share of such slowdowns
    /// a delay alert naming a nearby station followed within 30 and 60 minutes, by what the trains lost, against chance (the
    /// station-local tables; the line-level ones when the model lacks them). It is a slowdown notice first: the alert clause
    /// is added only where the record shows a real lift over chance, the heaviest slowdowns.
    func prewarnings(boards: [LineBoard], alerts: [RouteAlert], stopName: (String, String) -> String?) -> [PreWarning] {
        guard let pwm = prewarn, let all = pwm.all else { return [] }
        let alerted = Set(alerts.filter { $0.kind == "delay" && ($0.type ?? "").lowercased().contains("delay") }.flatMap { $0.routes })
        var out: [PreWarning] = []
        for b in boards {
            var groups: [String: [(loss: Double, from: String, to: String)]] = [:]
            for t in b.trains where t.started {
                guard let lr = t.lastRun, !lr.assumedFrom, let d = lr.distM, let sched = lr.schedSpeedKmh, sched > 0 else { continue }
                let schedRun = d / (sched / 3.6)
                groups["\(lr.fromStop)>\(lr.toStop)", default: []].append((lr.runSec - schedRun, lr.fromStop, lr.toStop))
            }
            for (_, runs) in groups {
                let slow = runs.filter { $0.loss >= DelayModel.normalLatenessSec }
                guard runs.count >= 2, slow.count >= 2, Double(slow.count) / Double(runs.count) >= 0.6 else { continue }
                let loss = slow.map(\.loss).reduce(0, +) / Double(slow.count)
                var p30 = all.pAlert30, p60 = all.pAlert60, lift = 1.0
                var basis = "all slowdowns on the line"
                if let loc = pwm.local?.fromSlowdowns {
                    // the station-local record: an alert naming a stop near the segment, against what chance gives
                    p30 = loc.pAlert30; p60 = loc.pAlert60; lift = loc.lift30 ?? 1; basis = "all slowdowns, an alert nearby"
                    if let best = (loc.bySeverity ?? []).filter({ loss >= $0.lossLo && ($0.minTrains == 3 ? slow.count >= 3 : slow.count == 2) }).max(by: { $0.lossLo < $1.lossLo }) {
                        p30 = best.pAlert30; p60 = best.pAlert60; lift = best.lift30 ?? 1; basis = "\(best.trains) losing \(best.loss), an alert nearby"
                    }
                } else {
                    if let best = (pwm.bySeverity ?? []).filter({ loss >= $0.lossLo && ($0.minTrains == 3 ? slow.count >= 3 : slow.count == 2) }).max(by: { $0.lossLo < $1.lossLo }) {
                        p30 = best.pAlert30; p60 = best.pAlert60; basis = "\(best.trains) losing \(best.loss)"
                    }
                    if let r = pwm.byRoute?[b.route], all.pAlert30 > 0 {
                        p30 = min(0.98, p30 * (0.5 + 0.5 * r.pAlert30 / all.pAlert30))
                        p60 = min(0.98, p60 * (0.5 + 0.5 * (all.pAlert60 > 0 ? r.pAlert60 / all.pAlert60 : 1)))
                        basis += ", the \(b.route)"
                    }
                }
                let from = stopName(b.key, slow[0].from) ?? slow[0].from, to = stopName(b.key, slow[0].to) ?? slow[0].to
                let way = b.direction == "N" ? "uptown" : (b.direction == "S" ? "downtown" : "")
                let covered = alerted.contains(b.route)
                // a slowdown notice first; the alert clause only where the record shows a real lift over chance
                let claim = (!covered && lift >= 1.5 && p30 >= 0.04)
                    ? " · an alert nearby follows \(Int((p30 * 100).rounded()))% of such slowdowns within 30 min, \(Int(lift.rounded()))× the usual" : ""
                let text = "\(b.route) \(way): \(slow.count) of \(runs.count) trains lost \(Fmt.minTxt(loss)) between \(from) and \(to)"
                    + (covered ? " · a delay alert is posted" : " · no alert yet") + claim
                out.append(PreWarning(route: b.route, key: b.key, direction: b.direction, fromStop: slow[0].from, toStop: slow[0].to, fromName: from, toName: to,
                                      lossSec: loss, nSlow: slow.count, nTrains: runs.count, alerted: covered, pAlert30: p30, pAlert60: p60, lift30: lift, basis: basis, text: text))
            }
        }
        return out.sorted { ($0.alerted ? 1 : 0, -$0.lossSec * Double($0.nSlow)) < ($1.alerted ? 1 : 0, -$1.lossSec * Double($1.nSlow)) }
    }

    // MARK: reading the alert's text (mirrors mta_delay_insights/sources/alerts.py and analysis/delay_lifecycle.py)

    static let causePatterns: [(String, String)] = [
        ("person_on_track", "person (on|struck|in) the (track|roadbed)|unauthorized person|someone (on|struck by) (the )?(track|train)|struck by a train"),
        ("police", "\\bnypd\\b|police (activity|investigation)|criminal|assault|unruly|disruptive"),
        ("medical", "\\bems\\b|medical|sick (customer|passenger)|injured"),
        ("fire_smoke", "\\bfire\\b|smoke|\\bfdny\\b"),
        ("signal", "signal(s|ling)? (problem|malfunction|failure|trouble|issue|work|maintenance)|signal(s)?\\b"),
        ("switch", "switch (problem|trouble|malfunction|failure)"),
        ("track", "rail condition|track (condition|problem|fire|maintenance|work|replacement|inspection|defect)|broken rail|switch"),
        ("rolling_stock", "mechanical (problem|issue)|door (problem|issue)|brakes?|disabled train|train with mechanical|(removed|moved) a train|train (car|from service)|train that (had|has|needed)|in need of cleaning"),
        ("power", "power (problem|loss|outage)|third rail|electrical|con ?ed(ison)?"),
        ("obstruction", "debris|obstruction|object on the track|tree"),
        ("water_weather", "flood|water condition|\\bweather\\b|\\bsnow\\b|\\bice\\b|\\bheat\\b|\\bstorm\\b|\\bwind\\b|hurricane|lightning"),
        ("crowding_dwell", "crowd|overcrowd|customer volume|holding (the )?doors|door holding|heavy ridership"),
        ("crew", "crew (availability|shortage)|operator availability|staffing"),
        ("reduced_service", "runs every \\d+ minutes|reduced service|fewer trains"),
        ("planned_work", "planned work|scheduled maintenance|capital work|construction|track work|station work|maintenance"),
        ("investigation", "investigation"),
    ]

    static func classifyCause(_ text: String) -> String {
        let t = text.lowercased()
        for (cat, pat) in causePatterns where t.range(of: pat, options: .regularExpression) != nil { return cat }
        return "unknown"
    }

    static let causeWordsTable: [String: String] = [
        "rolling_stock": "a train problem", "signal": "signal problems", "switch": "a switch problem", "track": "track work or a track condition",
        "medical": "a medical call", "police": "police activity", "person_on_track": "a person on the track", "fire_smoke": "fire or smoke",
        "power": "a power problem", "obstruction": "an obstruction", "water_weather": "weather", "crowding_dwell": "crowding",
        "crew": "crew availability", "reduced_service": "reduced service", "planned_work": "work on the line", "investigation": "an investigation",
        "unknown": "an unstated cause",
    ]
    static func causeWords(_ cause: String) -> String { causeWordsTable[cause] ?? cause }

    static let stopWords: Set<String> = ["Manhattan", "Brooklyn", "Queens", "Bronx", "Staten Island", "NYPD", "FDNY", "EMS", "NYC", "MTA"]

    /// The station the header names ("…track maintenance at Grand Central-42 St."), if any.
    static func station(in header: String) -> String? {
        let h = header.replacingOccurrences(of: "\u{00a0}", with: " ")
        let pat = "\\b(?:at|near|between|in)\\s+((?:[A-Z0-9][\\w.'’/&-]*|of)(?:\\s+(?:[A-Z0-9][\\w.'’/&-]*|of|-))*)"
        guard let re = try? NSRegularExpression(pattern: pat) else { return nil }
        let ns = h as NSString
        for m in re.matches(in: h, range: NSRange(location: 0, length: ns.length)) {
            var name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
            name = name.replacingOccurrences(of: "\\s+(and|while|because|due|after|when|for|with|in|on)$", with: "", options: .regularExpression)
            if name.count < 3 || stopWords.contains(name) { continue }
            if name.range(of: "^(the|a|an|this|that|our|its)\\b", options: [.regularExpression, .caseInsensitive]) != nil { continue }
            return name
        }
        return nil
    }

    static func direction(in header: String) -> String {
        let h = header.lowercased()
        if h.contains("both directions") { return "both" }
        if h.range(of: "\\buptown\\b|\\bnorthbound\\b|bronx-bound|queens-bound", options: .regularExpression) != nil { return "N" }
        if h.range(of: "\\bdowntown\\b|\\bsouthbound\\b|brooklyn-bound", options: .regularExpression) != nil { return "S" }
        return "unknown"
    }
}

/// A slowdown the boards show on one segment, before any alert: the pre-warning.
struct PreWarning: Identifiable {
    var id: String { "\(key)|\(fromStop)>\(toStop)" }
    var route: String
    var key: String
    var direction: String
    var fromStop: String
    var toStop: String
    var fromName: String
    var toName: String
    var lossSec: Double
    var nSlow: Int
    var nTrains: Int
    var alerted: Bool
    var pAlert30: Double
    var pAlert60: Double
    /// how many times chance the 30-minute figure is (1 where the model has no station-local table)
    var lift30: Double
    var basis: String
    var text: String
}

/// What the model makes of one live alert: a status, active or stale, and the interpretation.
struct DelayAssessment {
    /// starting: posted, nothing in the feed yet · in effect: the feed shows the delay · waning: receding or just
    /// cleared · stale: cleared a while ago · unconfirmed: nothing in the feed in the time alerts that register take.
    enum Phase: String {
        case starting, inEffect = "in effect", waning, stale, unconfirmed
        var word: String { self == .unconfirmed ? "no sign in the feed" : rawValue }
        /// The order a rider should read them in.
        var priority: Int {
            switch self {
            case .inEffect: return 0
            case .starting: return 1
            case .waning: return 2
            case .unconfirmed: return 3
            case .stale: return 4
            }
        }
        var active: Bool { self == .starting || self == .inEffect || self == .waning }
    }
    var cause: String
    var station: String?
    var direction: String
    var postedTs: Double
    var ageMin: Double
    var statedEndTs: Double?
    var pClear15: Double
    var pClear30: Double
    var pClear60: Double
    var expectedRemainingMin: Double
    var feedSeen: Bool
    var latenessSec: Double
    var held: Int
    var phase: Phase
    /// P(gone within 30 min) from the phase's own record (by cause where deep enough), else the survival curve.
    var pGone30: Double
    /// The feed's excess near the station now (nil: no reading), the peak seen, and how long normal since.
    var excessSec: Double?
    var peakSec: Double
    var recoveredMin: Double?
    /// The reading is of the trains near the named station (else the whole line).
    var local: Bool
    /// phone | server: whose trajectory the phase came from.
    var source: String
    var basis: String
    /// "in effect · trains 4 min late near Jay St, 18 min in · typically 25 min to go"
    var interpretation: String
    /// The full line: cause, where, posted, the MTA's end, then the interpretation.
    var text: String
    /// For a route's reasons: "delay alert on the F at Jay St: in effect, trains 4 min late".
    var short: String

    var active: Bool { phase.active }
    var priority: Int { phase.priority }
    /// Whether the alert should count against the route right now.
    var countsAgainstRoute: Bool { phase == .inEffect || phase == .starting }
}

/// One poll's reading of a line: the median lateness of its started trains and how many were held or overdue.
struct LatenessSample {
    var ts: Double
    var latenessSec: Double
    var held: Int
}

/// The server's reading of a live alert, from alerts.json (its `assessment`): the phase from the store's whole
/// trajectory since posting, and the figures behind it.
struct PublishedAssessment: Decodable {
    var phase: String?
    var active: Bool?
    var interpretation: String?
    var excessNowSec: Double?
    var peakExcessSec: Double?
    var recoveredMin: Double?
    var seen: Bool = false
    /// When alerts.json was generated (set by the loader).
    var generatedAt: Double = 0

    enum CodingKeys: String, CodingKey { case phase, active, interpretation, trajectory }
    enum TrajectoryKeys: String, CodingKey { case excessNowSec = "excess_now_sec", peakExcessSec = "peak_excess_sec", recoveredMin = "recovered_min", seen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        active = try c.decodeIfPresent(Bool.self, forKey: .active)
        interpretation = try c.decodeIfPresent(String.self, forKey: .interpretation)
        if let t = try? c.nestedContainer(keyedBy: TrajectoryKeys.self, forKey: .trajectory) {
            excessNowSec = try t.decodeIfPresent(Double.self, forKey: .excessNowSec)
            peakExcessSec = try t.decodeIfPresent(Double.self, forKey: .peakExcessSec)
            recoveredMin = try t.decodeIfPresent(Double.self, forKey: .recoveredMin)
            seen = (try t.decodeIfPresent(Bool.self, forKey: .seen)) ?? false
        }
    }
}

/// alerts.json as the site publishes it: the alerts with the server's assessment of each live delay.
struct PublishedAlerts: Decodable {
    struct Entry: Decodable {
        var alertId: String
        var assessment: PublishedAssessment?
        enum CodingKeys: String, CodingKey { case alertId = "alert_id", assessment }
    }
    var generatedAt: String?
    var alerts: [Entry]
    enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", alerts }
}
