import SwiftUI

/// Overall health of one line direction right now, from the live board, the engine's projection and the alerts:
/// how late its trains run, whether any is held, the largest gap forming against the usual headway, and whether an
/// unplanned alert is active. Four levels, each with the reason spelled out.
struct LineHealth {
    enum Level: Int { case good = 0, minor, delays, severe }
    var level: Level
    var reason: String

    var label: String {
        switch level {
        case .good: return "Good service"
        case .minor: return "Minor delays"
        case .delays: return "Delays"
        case .severe: return "Severe delays"
        }
    }

    var color: Color {
        switch level {
        case .good: return .green
        case .minor: return .yellow
        case .delays: return .orange
        case .severe: return .red
        }
    }
}

/// The line's health for a rider, in practical terms: the extra wait the trains make, the gaps a rider would stand
/// through, and holds that cause them. `span`: the rider's own stretch (boarding to alighting stop on this line); only
/// it and the trains on their way to it set the level, and what happens elsewhere on the line is said as context
/// ("2 held near Jackson Hts, not on your stretch"). Without a span, the whole line.
///
/// Oct 12, the F at 18:00: within a minute of the timetable both ways, yet "Severe delays" for two trains standing
/// 3-4 min at Jackson Hts and Forest Hills (no gap behind either) and a 3.25x gap at Avenue X, both far from a rider
/// between 4 Av-9 St and Jay St. A hold alone is never severe now: it counts once it leaves a gap.
@MainActor func lineHealth(key: String, data: DataService, span: StopSpan? = nil) -> LineHealth? {
    guard let b = data.boards[key] else { return nil }
    let route = String(key.split(separator: "_").first ?? "")
    guard !b.trains.isEmpty else { return LineHealth(level: .minor, reason: "no started train in the feed") }
    let line = data.schedule?.lines[key]
    let names = line?.names ?? []
    func name(_ i: Int) -> String { i < names.count ? names[i] : "a stop" }
    // the trains that matter: on the rider's stretch or on their way to it (from a few stops before the boarding stop)
    let lo = span.map { max(0, $0.from - 8) } ?? 0
    let hi = span?.to ?? Int.max
    let trains = b.trains.filter { $0.started && $0.nextIdx >= lo && $0.nextIdx <= hi }
    let elsewhere = b.trains.filter { $0.started && !($0.nextIdx >= lo && $0.nextIdx <= hi) }
    let scope = span == nil ? "" : " on your stretch"

    // judged by the extra wait the trains make (the gap over the scheduled headway) where the board can tell: a line
    // running behind its timetable at even spacing is no delay to a rider at the platform
    let gaps = trains.filter { $0.practicalLatenessSec != nil }.count >= 2
    let by: (LiveTrain) -> Double? = { gaps ? $0.practicalLatenessSec : $0.effectiveLatenessSec }
    let lates = trains.compactMap(by).map { max(0, $0) }.sorted()
    let median = lates.isEmpty ? 0 : lates[lates.count / 2]
    let nLate = trains.filter { (by($0) ?? 0) >= 180 }.count
    let lateShare = trains.isEmpty ? 0 : Double(nLate) / Double(trains.count)
    let behind = b.trains.compactMap { $0.effectiveLatenessSec }.sorted()
    let behindMedian = behind.isEmpty ? 0 : behind[behind.count / 2]
    let held = trains.filter(\.isHeld)
    let heldElsewhere = elsewhere.filter(\.isHeld)

    // the largest gap coming, at the stops of the stretch, against the usual headway there; and the line's own largest
    var gapRatio = 0.0, gapText = "", outsideText = ""
    if let lp = data.predictions[key]?[data.scenario] ?? data.predictions[key]?["baseline"], let sched = data.schedule, let line {
        func usual(_ i: Int) -> Double { i < line.stops.count ? (schedHeadwayAt(schedule: sched, lineSched: data.lineSched, keys: [key], stop: line.stops[i], now: data.now) ?? 0) : 0 }
        // gaps between the engine's arrivals in the next 20 min only: further out the feed has not listed every trip
        // yet, so gaps there are partly trains it does not know of (as the server's line status measures them)
        let until = data.now + 1200
        var gapAt: [(idx: Int, gap: Double, ratio: Double)] = []
        for i in 0..<line.stops.count {
            let arr = lp.trains.compactMap { $0.point(at: i)?.etaTs }.filter { $0 >= data.now && $0 <= until }.sorted()
            guard arr.count >= 2, case let u = usual(i), u > 0 else { continue }
            let g = zip(arr, arr.dropFirst()).map { $1 - $0 }.max() ?? 0
            gapAt.append((i, g, g / u))
        }
        let inSpan = gapAt.filter { g in span.map { g.idx >= $0.from && g.idx <= $0.to } ?? true }
        if let w = inSpan.max(by: { $0.ratio < $1.ratio }) {
            gapRatio = w.ratio
            gapText = "largest gap\(scope) \(Fmt.minTxt(w.gap)) at \(name(w.idx)) (usually \(Fmt.minTxt(usual(w.idx))))"
        }
        if let sp = span, let w = gapAt.filter({ $0.idx < sp.from || $0.idx > sp.to }).max(by: { $0.ratio < $1.ratio }), w.ratio >= 2 {
            outsideText = "a \(Fmt.minTxt(w.gap)) gap at \(name(w.idx)), not on your stretch"
        }
    }
    // an alert counts while the trains show it (the delay model's phase), not because it is posted
    let delayAlerts = data.alertsFor(routes: [route]).filter { $0.kind == "delay" }
    let alertInEffect = delayAlerts.contains { data.assess($0).map { $0.phase == .inEffect || $0.phase == .starting } ?? true }

    var level: LineHealth.Level = .good
    if median >= 600 || gapRatio >= 3 { level = .severe }
    else if median >= 300 || lateShare >= 0.5 || gapRatio >= 2 || alertInEffect || (held.count >= 2 && (gapRatio >= 1.5 || median >= 120)) { level = .delays }
    else if median >= 120 || lateShare >= 0.25 || gapRatio >= 1.5 || !held.isEmpty || !delayAlerts.isEmpty { level = .minor }

    var parts: [String] = []
    if gaps {
        parts.append(nLate == 0 ? "trains at their usual spacing\(scope)" : "\(nLate) of \(trains.count) trains\(scope) 3+ min behind the usual spacing")
        if median >= 60 { parts.append("typically \(Fmt.minTxt(median)) extra wait") }
    } else {
        parts.append(nLate == 0 ? "no train\(scope) 3+ min late" : "\(nLate) of \(trains.count) trains\(scope) 3+ min late")
        if median >= 60 { parts.append("typically \(Fmt.minTxt(median)) behind") }
    }
    if !held.isEmpty { parts.append("\(held.count) held or overdue\(scope)" + (gapRatio < 1.5 && median < 120 ? ", no gap from it yet" : "")) }
    if gapRatio >= 1.5, !gapText.isEmpty { parts.append(gapText) }
    if !delayAlerts.isEmpty { parts.append(alertInEffect ? "delay alert in effect" : "delay alert posted, trains running normally") }
    // context: what happens on the rest of the line, said for what it is
    if span != nil, !heldElsewhere.isEmpty {
        let at = heldElsewhere.compactMap { $0.position?.stopName }.first.map { " near \($0)" } ?? ""
        parts.append("\(heldElsewhere.count) held\(at), not on your stretch")
    }
    if !outsideText.isEmpty { parts.append(outsideText) }
    if behindMedian >= 180, median < 60 { parts.append("\(Fmt.minTxt(behindMedian)) behind the timetable, at normal spacing") }
    return LineHealth(level: level, reason: parts.joined(separator: " · "))
}

/// The indicator: a coloured dot, the level, and the reason.
struct LineHealthRow: View {
    let health: LineHealth
    let route: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(health.color).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(route) line: \(health.label)").font(.subheadline.bold()).foregroundStyle(health.level == .good ? Color.primary : health.color)
                Text(health.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(health.color.opacity(health.level == .good ? 0 : 0.5), lineWidth: 1))
    }
}
