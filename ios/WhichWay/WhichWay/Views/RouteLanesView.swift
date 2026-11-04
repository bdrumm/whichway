import SwiftUI

/// The Go tab home's lanes (Nov 2 review, B with C; Nov 4: a short copy of the routes page): every way on one clock
/// from now to arrival, in the routes page's order (the rider's usual way first unless another is a real margin
/// sooner), the route in hand outlined in blue where it ranks. Choosing another way moves the outline and leaves the
/// list as it is. A lane shares the route in hand's bar up to where it parts (faded), then shows its own. A tap takes
/// the lane's route; on the way, that tells the trip which way the rider went. The lanes themselves are `routeLanes`
/// (Core).
struct RouteLanesView: View {
    let lanes: RouteLanes
    let now: Double
    let originName: String
    /// On the way: the next station where a way leaves the route in hand, counted down.
    var routeStarted = false
    /// The arrival if a hold on the route drags on (later than the lane's own): a tail on the route in hand.
    var holdTailTs: Double? = nil
    /// The hold's three outcomes, when a held train touches the route.
    var hold: HoldOutlook? = nil
    /// The arrival's likely window and the model's word on it, under the route in hand.
    var note: String? = nil
    var onPick: (String) -> Void
    var onLineView: () -> Void
    /// The full list of routes, two swipes over.
    var onMore: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Every way, by the clock").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(action: onLineView) {
                    HStack(spacing: 3) { Text("Line view"); Image(systemName: "chevron.right").font(.caption2) }
                }
                .font(.footnote).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            if routeStarted, let c = lanes.nextChoice(after: now) {
                Text("Next choice: \(c.station) in \(Fmt.mmss(c.ts - now))").font(.footnote.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            LaneAxis(start: lanes.startTs, end: lanes.endTs).padding(.horizontal, 8)
            let marks = Array(Set(lanes.lanes.compactMap(\.partsTs))).sorted()
            ForEach(lanes.lanes) { l in row(l, marks: marks) }
            if lanes.lanes.count == 1 {
                Text(routeStarted ? "No other way from here: no change left to make differently." : "The only way with at most one change.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            if let h = hold { HoldOutlookCard(outlook: h).padding(.top, 6) }
            Button(action: onMore) {
                HStack(spacing: 3) {
                    Text(lanes.moreCount > 0 ? "\(lanes.moreCount) more way\(lanes.moreCount == 1 ? "" : "s") in all routes" : "All routes")
                    Image(systemName: "chevron.right").font(.caption2)
                }
            }
            .font(.footnote).buttonStyle(.plain).foregroundStyle(Color.accentColor).padding(.horizontal, 8).padding(.top, 4)
        }
    }

    /// The route in hand outlined in blue, its note inside the outline; any other way a tap to take it.
    @ViewBuilder private func row(_ l: RouteLane, marks: [Double]) -> some View {
        if l.isCurrent {
            VStack(alignment: .leading, spacing: 2) {
                LaneRow(lane: l, text: text(l), start: lanes.startTs, end: lanes.endTs, marks: marks, holdTailTs: holdTailTs)
                if let n = note { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Chosen: \(text(l)), in \(Fmt.hhmm(l.arriveTs))")
        } else {
            Button { onPick(l.optionId) } label: {
                LaneRow(lane: l, text: text(l), start: lanes.startTs, end: lanes.endTs, sharedUntil: l.partsTs)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(text(l)), in \(Fmt.hhmm(l.arriveTs))")
        }
    }

    private func text(_ l: RouteLane) -> String {
        let last = l.routes.last ?? ""
        let board = l.segments.first { if case .ride = $0.kind { return true }; return false }?.startTs
        let usual = l.optionId == lanes.typicalId ? "usual · " : ""
        let fromStart = "\(l.routes.first ?? "") \(Fmt.hhmm(board))" + (l.changeAt.map { " · \(last) at \($0)" } ?? " · direct")
        switch l.parting {
        case .current:
            return usual + (routeStarted ? "your route" + (l.changeAt.map { " · at \($0)" } ?? (l.routes.count == 1 ? " · direct" : "")) : fromStart)
        case .atStart: return usual + fromStart
        case .stayOn: return usual + "stay on" + (l.changeAt.map { " · \(last) at \($0)" } ?? " to the end")
        case let .offEarlier(s): return usual + "off at \(s) · the \(last)"
        case .otherConnection: return usual + "the \(last) instead"
        }
    }
}

/// One lane: its lines, a word, its arrival and the difference from the route in hand; the bar under them.
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
        .accessibilityHidden(true)
    }
}
