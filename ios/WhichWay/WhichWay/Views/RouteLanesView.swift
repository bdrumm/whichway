import SwiftUI

/// The Go tab home's lanes (Nov 2 review, B with C): every way on one clock from now to arrival, the route in hand
/// first, the others under the station where they leave it, in the order the rider meets those stations. A lane
/// shares the route in hand's bar up to where it parts (faded), then shows its own. A tap takes the lane's route;
/// on the way, that tells the trip which way the rider went. The lanes themselves are `routeLanes` (Core).
struct RouteLanesView: View {
    let lanes: RouteLanes
    let now: Double
    let originName: String
    /// On the way: the next choice is the first station's, counted down.
    var routeStarted = false
    /// The arrival if a hold on the route drags on (later than the lane's own): a tail on the route in hand.
    var holdTailTs: Double? = nil
    /// The hold's three outcomes, when a held train touches the route.
    var hold: HoldOutlook? = nil
    /// The arrival's likely window and the model's word on it, under the route in hand.
    var note: String? = nil
    var onPick: (String) -> Void
    var onLineView: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Every way, by the clock").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(action: onLineView) {
                    HStack(spacing: 3) { Text("Line view"); Image(systemName: "chevron.right").font(.caption2) }
                }
                .font(.footnote).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            LaneAxis(start: lanes.startTs, end: lanes.endTs)
            LaneRow(lane: lanes.current, text: text(lanes.current), start: lanes.startTs, end: lanes.endTs,
                    marks: lanes.groups.compactMap(\.ts), holdTailTs: holdTailTs)
            if let n = note { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 26) }
            if let h = hold { HoldOutlookCard(outlook: h).padding(.top, 4) }
            ForEach(Array(lanes.groups.enumerated()), id: \.element.id) { i, g in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title(g, first: i == 0)).font(.footnote.weight(.semibold))
                            .foregroundStyle(i == 0 && routeStarted && g.ts != nil ? Color.accentColor : Color.primary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(subtitle(g)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ForEach(g.lanes) { l in
                        Button { onPick(l.optionId) } label: {
                            LaneRow(lane: l, text: text(l), start: lanes.startTs, end: lanes.endTs, sharedUntil: l.partsTs)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(l.parting == .nextTrain)
                        .accessibilityLabel("\(text(l)), in \(Fmt.hhmm(l.arriveTs))")
                    }
                }
                .padding(.top, 10)
            }
            if lanes.groups.isEmpty {
                Text(routeStarted ? "No other way from here: no change left to make differently." : "The only way with at most one change.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private func title(_ g: LaneGroup, first: Bool) -> String {
        guard let s = g.station else { return "At \(originName.isEmpty ? "the station" : originName)" + (routeStarted ? "" : " · now") }
        if first, routeStarted, let t = g.ts, t > now { return "Next: \(s) in \(Fmt.mmss(t - now))" }
        return "At \(s)" + (g.ts.map { " · \(Fmt.hhmm($0))" } ?? "")
    }

    private func subtitle(_ g: LaneGroup) -> String {
        let kinds = g.lanes.map(\.parting)
        if g.station == nil { return "another train" }
        if kinds.contains(where: { if case .stayOn = $0 { return true }; return false }) { return "change here or stay on" }
        if kinds.allSatisfy({ if case .offEarlier = $0 { return true }; return false }) { return "change sooner" }
        return "another line"
    }

    private func text(_ l: RouteLane) -> String {
        let last = l.routes.last ?? ""
        let board = l.segments.first { if case .ride = $0.kind { return true }; return false }?.startTs
        switch l.parting {
        case .current: return "your route" + (l.changeAt.map { " · at \($0)" } ?? (l.routes.count == 1 ? " · direct" : ""))
        case .nextTrain: return "next \(l.routes.first ?? "") · \(Fmt.hhmm(board))"
        case .atStart: return "\(l.routes.first ?? "") \(Fmt.hhmm(board))" + (l.changeAt.map { " · \(last) at \($0)" } ?? " · direct")
        case .stayOn: return "stay on" + (l.changeAt.map { " · \(last) at \($0)" } ?? " to the end")
        case let .offEarlier(s): return "off at \(s) · the \(last)"
        case .otherConnection: return "the \(last) instead"
        }
    }
}

/// One lane: the check (the route in hand), its lines, a word, its arrival and the difference; the bar under them.
private struct LaneRow: View {
    let lane: RouteLane
    let text: String
    let start: Double
    let end: Double
    var marks: [Double] = []
    var sharedUntil: Double? = nil
    var holdTailTs: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().strokeBorder(lane.isCurrent ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: 1.5)
                        .background(Circle().fill(lane.isCurrent ? Color.accentColor : Color.clear))
                    if lane.isCurrent { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) }
                }
                .frame(width: 16, height: 16)
                HStack(spacing: 2) { ForEach(Array(lane.routes.enumerated()), id: \.offset) { _, r in RouteBullet(route: r, size: 17) } }
                Text(text).font(.footnote.weight(lane.isCurrent ? .semibold : .regular))
                    .foregroundStyle(lane.isCurrent ? Color.primary : Color.secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text(Fmt.hhmm(lane.arriveTs)).font(.subheadline.weight(.bold)).monospacedDigit()
                    .foregroundStyle(lane.isCurrent ? Color.accentColor : Color.primary)
                if !lane.isCurrent, abs(lane.deltaSec) >= 30 {
                    Text("\(lane.deltaSec > 0 ? "+" : "−")\(Int((abs(lane.deltaSec) / 60).rounded()))").font(.caption2.weight(.medium))
                        .foregroundStyle(lane.deltaSec < 0 ? Color.green : Color.secondary).monospacedDigit()
                }
            }
            LaneBar(segments: lane.segments, start: start, end: end, bold: lane.isCurrent, sharedUntil: sharedUntil, marks: marks, holdTailTs: holdTailTs,
                    arriveTs: lane.arriveTs)
                .padding(.leading, 22)
        }
        .padding(.vertical, 3)
    }
}

/// A lane's stretches drawn to the clock: waits faint, rides in the line's colour (a guess paler), changes dotted.
private struct LaneBar: View {
    let segments: [LaneSegment]
    let start: Double
    let end: Double
    var bold = false
    var sharedUntil: Double? = nil
    var marks: [Double] = []
    var holdTailTs: Double? = nil
    var arriveTs: Double = 0

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = { (ts: Double) in CGFloat((min(max(ts, start), end) - start) / max(1, end - start)) * w }
            let h: CGFloat = bold ? 9 : 6
            ZStack(alignment: .topLeading) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    let x0 = x(s.startTs) + 1, x1 = x(s.endTs) - 1
                    let shared = sharedUntil.map { s.endTs <= $0 + 1 } ?? false
                    switch s.kind {
                    case .wait:
                        Capsule().fill(Color.primary.opacity(0.12)).frame(width: max(2, x1 - x0), height: h).offset(x: x0, y: (12 - h) / 2)
                    case let .ride(route, estimated):
                        Capsule().fill(RouteStyle.color(route).opacity(shared ? 0.25 : (estimated ? 0.45 : (bold ? 1 : 0.8))))
                            .frame(width: max(2, x1 - x0), height: h).offset(x: x0, y: (12 - h) / 2)
                    case .change:
                        Path { p in p.move(to: CGPoint(x: x0, y: 6)); p.addLine(to: CGPoint(x: max(x0, x1), y: 6)) }
                            .stroke(Color.secondary.opacity(shared ? 0.3 : 0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 3]))
                    }
                }
                if let t = holdTailTs, t > arriveTs {
                    Capsule().fill(Color.orange.opacity(0.85)).frame(width: max(2, x(t) - x(arriveTs) - 1), height: 5).offset(x: x(arriveTs) + 1, y: 3.5)
                }
                if let p = sharedUntil {
                    Rectangle().fill(Color.primary).frame(width: 1.5, height: 12).offset(x: x(p) - 0.75)
                }
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    Circle().strokeBorder(Color.primary, lineWidth: 1.5).background(Circle().fill(Color(.systemBackground)))
                        .frame(width: 8, height: 8).offset(x: x(m) - 4, y: 2)
                }
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

/// The clock over the lanes: now at the left, then every ten minutes.
private struct LaneAxis: View {
    let start: Double
    let end: Double

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let first = ((start + 240) / 600).rounded(.up) * 600
            let ticks = Array(stride(from: first, to: end, by: 600))
            ZStack(alignment: .topLeading) {
                Text("now").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                ForEach(ticks, id: \.self) { t in
                    Text(Fmt.hhmm(t)).font(.caption2).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                        .position(x: CGFloat((t - start) / max(1, end - start)) * w, y: 7)
                }
            }
        }
        .frame(height: 14)
        .padding(.leading, 22)
        .accessibilityHidden(true)
    }
}
