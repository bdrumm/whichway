import Foundation

/// What a rider saw, in one or two taps: a held train, a long wait, crowding, an incident, or that all is well,
/// pinned to the line, direction and stop the app already knows. Sent through the trip relay (POST /v1/reports),
/// shown on the Atlas map, and matched by the pipeline against what the feeds showed, so the model learns from it.
enum ReportKind: String, Codable, CaseIterable, Identifiable {
    case held, delay, moving, longWait = "long_wait", crowded, incident, skipped, allGood = "all_good"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .held: return "Held"
        case .delay: return "Running slow"
        case .moving: return "Moving again"
        case .longWait: return "Long wait"
        case .crowded: return "Crowded"
        case .incident: return "Incident"
        case .skipped: return "Skipped / rerouted"
        case .allGood: return "All good"
        }
    }

    var symbol: String {
        switch self {
        case .held: return "pause.circle.fill"
        case .delay: return "tortoise.fill"
        case .moving: return "play.circle.fill"
        case .longWait: return "hourglass"
        case .crowded: return "person.3.fill"
        case .incident: return "exclamationmark.triangle.fill"
        case .skipped: return "arrow.triangle.branch"
        case .allGood: return "checkmark.circle.fill"
        }
    }

    /// The second tap, where the kind has one: how crowded, what kind of incident, how the run differs.
    var subs: [(key: String, label: String)] {
        switch self {
        case .crowded: return [("some", "Busy"), ("packed", "Packed"), ("cant_board", "Couldn't board")]
        case .incident: return [("police", "Police"), ("medical", "Sick passenger"), ("door", "Doors"), ("signal", "Signals"), ("track", "Track"), ("other", "Other")]
        case .skipped: return [("skipped_stop", "Skipped a stop"), ("rerouted", "Rerouted"), ("express", "Running express"), ("local", "Running local")]
        default: return []
        }
    }

    /// The kinds that make sense where the rider is: on a train, or at a station waiting for one.
    static func offered(onTrain: Bool) -> [ReportKind] {
        onTrain ? [.held, .delay, .moving, .crowded, .incident, .skipped, .allGood]
                : [.longWait, .crowded, .incident, .allGood]
    }
}

/// Where a report is pinned: the line and direction, the stop (the train's current or last stop on a ride, the
/// boarding platform before it), the train when the phone knows it, and how sure the phone is of all that.
struct ReportContext: Equatable {
    enum Source: String, Codable { case trip, station, manual }
    var route: String
    var dir: String?
    var stop: String
    var stopName: String
    var tripId: String?
    var source: Source
    var confidence: Double?

    /// On a ride: the train the phone believes the rider is on, placed where the feed has it now.
    static func onTrain(key: String, tripId: String?, route: String, stop: String, stopName: String, confidence: Double?) -> ReportContext {
        ReportContext(route: route, dir: direction(ofKey: key), stop: stop, stopName: stopName, tripId: tripId, source: .trip, confidence: confidence)
    }

    /// Before the ride: the platform the rider is at (or headed to), on the line the plan takes from it.
    static func atStation(key: String, stop: String, stopName: String) -> ReportContext {
        ReportContext(route: String(key.split(separator: "_").first ?? ""), dir: direction(ofKey: key), stop: stop, stopName: stopName,
                      tripId: nil, source: .station, confidence: nil)
    }

    /// "F_N" → "N"; a key without a direction says nothing.
    static func direction(ofKey key: String) -> String? {
        guard let d = key.split(separator: "_").last, key.contains("_"), d == "N" || d == "S" else { return nil }
        return String(d)
    }

    /// The line board's train id ("F_N|tripId") → the trip id the feeds use.
    static func tripId(ofTrain trainId: String?) -> String? {
        guard let t = trainId, let bar = t.firstIndex(of: "|") else { return nil }
        let id = String(t[t.index(after: bar)...])
        return id.isEmpty ? nil : id
    }
}

struct RiderReport: Codable, Equatable, Identifiable {
    var id: String
    var ts: Double
    var kind: String
    var sub: String?
    var route: String
    var dir: String?
    var stop: String
    var trip: String?
    var source: String
    var confidence: Double?
    var appBuild: String?

    init(kind: ReportKind, sub: String?, context c: ReportContext, ts: Double, id: String = "R-" + UUID().uuidString, appBuild: String? = nil) {
        self.id = id
        self.ts = ts
        self.kind = kind.rawValue
        self.sub = kind.subs.contains { $0.key == sub } ? sub : nil
        route = RiderReport.relayRoute(c.route)
        dir = c.dir
        stop = c.stop
        trip = c.tripId.flatMap { RiderReport.tripOK($0) ? $0 : nil }
        source = c.source.rawValue
        confidence = c.confidence.map { (min(1, max(0, $0)) * 100).rounded() / 100 }
        self.appBuild = appBuild
    }

    /// The relay takes routes as the feeds name them, upper case ("GS", "6X", "FX"); "SI" and such pass as they are.
    static func relayRoute(_ r: String) -> String { r.uppercased() }

    /// The relay's own check on a trip id (letters, digits and _.:+- only, up to 80): one it would refuse is left off
    /// rather than costing the report.
    static func tripOK(_ t: String) -> Bool {
        t.count <= 80 && t.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "_.:+-".unicodeScalars.contains($0) }
    }

    /// What the rider sees afterwards: "Held · A at Jay St-MetroTech".
    func summary(stopName: String) -> String {
        let k = ReportKind(rawValue: kind)
        let what = k.flatMap { k in sub.flatMap { s in k.subs.first { $0.key == s }?.label } } ?? k?.label ?? kind
        return "\(what) · \(route) at \(stopName)"
    }
}
