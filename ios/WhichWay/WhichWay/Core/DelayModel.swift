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
    var version: Int
    var gridMin: Double
    var nEvents: Int
    var lifetime: Lifetime
    var stale: Stale
    enum CodingKeys: String, CodingKey { case version, gridMin = "grid_min", nEvents = "n_events", lifetime, stale }

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

    /// A live unplanned delay alert read against the curves and the boards of its lines.
    func assess(_ a: RouteAlert, now: Double, boards: [LineBoard]) -> DelayAssessment {
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
        // the feed now, on the alert's lines
        var lates: [Double] = []
        var held = 0
        for b in boards {
            lates += b.trains.compactMap { $0.effectiveLatenessSec }
            held += b.nHolding + b.nStalled
        }
        let seen = lates.count >= 2
        let late = seen ? lates.sorted()[lates.count / 2] : 0
        let feedNormal = seen && late < DelayModel.normalLatenessSec && held == 0
        let feedActive = seen && (late >= DelayModel.normalLatenessSec || held > 0)
        let goneAfterRecovery = (stale.byCause?[cause] ?? stale.all)?.shareRemovedWithin30 ?? 0
        let staleScore: Double = feedNormal ? (age >= 10 ? max(probs.p30, goneAfterRecovery) : probs.p30) : (feedActive ? min(probs.p30, 0.25) : probs.p30)
        let status: DelayAssessment.Status
        if age < 10 { status = .fresh }
        else if feedActive { status = .active }
        else if age >= 240 && feedNormal { status = .standing }
        else if staleScore >= 0.5 { status = .likelyStale }
        else { status = .aging }
        let station = DelayModel.station(in: a.header)
        let routes = a.routes.joined(separator: "/")
        var bits = ["\(DelayModel.causeWords(cause)) on the \(routes)" + (station.map { " at \($0)" } ?? ""),
                    "posted \(Fmt.hhmm(created)) (\(Int(age)) min ago)"]
        if let e = statedEnd { bits.append("MTA's end \(Fmt.hhmm(e))" + (now > e ? " passed" : "")) }
        bits.append("\(Int((probs.p30 * 100).rounded()))% gone within 30 min")
        if seen { bits.append(late < DelayModel.normalLatenessSec ? "trains on time now" : "trains \(Fmt.late(late))" + (held > 0 ? ", \(held) held" : "")) }
        let short = "delay alert on the \(routes)" + (station.map { " at \($0)" } ?? "") + ": \(status.rawValue)"
            + (status == .active ? "" : ", posted \(Fmt.hhmm(created))") + (feedNormal ? ", trains on time" : (feedActive ? ", trains \(Fmt.late(late))" : ""))
        return DelayAssessment(cause: cause, station: station, direction: DelayModel.direction(in: a.header), postedTs: created, ageMin: age,
                               statedEndTs: statedEnd, pClear15: probs.p15, pClear30: probs.p30, pClear60: probs.p60, expectedRemainingMin: probs.expected,
                               feedSeen: seen, latenessSec: late, held: held, staleScore: staleScore, status: status, basis: basis,
                               text: bits.joined(separator: " · ") + " → \(status.rawValue)", short: short)
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

/// What the model makes of one live alert.
struct DelayAssessment {
    enum Status: String { case fresh, active, aging, likelyStale = "likely stale", standing }
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
    var staleScore: Double
    var status: Status
    var basis: String
    /// The full line: "signal problems on the F at Jay St · posted 8:12 (47 min ago) · MTA's end 8:45 passed · 61% gone within 30 min · trains on time now → likely stale".
    var text: String
    /// For a route's reasons: "delay alert on the F at Jay St: likely stale, posted 8:12, trains on time".
    var short: String

    /// Whether the alert should count against the route right now.
    var countsAgainstRoute: Bool { status == .active || status == .fresh }
}
