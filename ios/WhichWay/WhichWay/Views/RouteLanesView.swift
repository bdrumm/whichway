import SwiftUI

/// The Go tab home's lanes (Nov 2 review, B with C; Nov 4: a short copy of the routes page): every way on one clock
/// from now to arrival, in the routes page's order (the rider's usual way first unless another is a real margin
/// sooner), the route in hand outlined in blue where it ranks. Choosing another way moves the outline and leaves the
/// list as it is. A lane shares the route in hand's bar up to where it parts (faded), then shows its own. A tap takes
/// the lane's route; on the way, that tells the trip which way the rider went. The lanes themselves are `routeLanes`
/// (Core). Nov 5: every route always listed (a way behind the rider faded, not dropped), no clock labels over the
/// bars, no words after the line icons (unless two ways share them), no "usual" mark, and the arrivals in one column.
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
                Text("\(lanes.lanes.count) way\(lanes.lanes.count == 1 ? "" : "s") to get there").font(.headline)
                Spacer(minLength: 8)
                Button(action: onLineView) {
                    HStack(spacing: 3) { Text("Line view"); Image(systemName: "chevron.right").font(.caption2) }
                }
                .font(.footnote).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            let marks = Array(Set(lanes.lanes.compactMap(\.partsTs))).sorted()
            ForEach(lanes.lanes) { l in row(l, marks: marks) }
            if let h = hold { HoldOutlookCard(outlook: h).padding(.top, 6) }
        }
    }

    /// Each way as the routes page's card (Nov 5: "the ways to get there items in the main page"), the lane's bar
    /// under it; the route in hand outlined, any other a tap to take it, one behind the rider faded and not takeable.
    @ViewBuilder private func row(_ l: RouteLane, marks: [Double]) -> some View {
        let card = WayCard(legs: l.routes.map { [$0] }, subtitle: subtitle(l), minutes: minutes(l), arrive: arrive(l), selected: l.isCurrent,
                           spoken: spoken(l)) {
            if !l.segments.isEmpty {
                LaneBar(segments: l.segments, start: lanes.startTs, end: lanes.endTs, bold: l.isCurrent,
                        sharedUntil: l.isCurrent ? nil : l.partsTs, marks: l.isCurrent ? marks : [],
                        holdTailTs: l.isCurrent ? holdTailTs : nil, arriveTs: l.arriveTs)
            }
        }
        if l.isCurrent {
            card
        } else if l.isBehind {
            card.opacity(0.45)
        } else {
            Button { onPick(l.optionId) } label: { card }.buttonStyle(.plain)
        }
    }

    /// "change at Jay St · next 9:31", as the routes page says it; on the train, "on the train"; a way behind the
    /// rider, "behind you"; with no train in the feeds, as the routes page.
    private func subtitle(_ l: RouteLane) -> String {
        let way = l.changeAt.map { "change at \($0)" } ?? "direct"
        if l.isBehind { return way + " · behind you" }
        if l.estimated { return way + " · no train in the feeds yet" }
        let board = l.segments.first { if case .ride = $0.kind { return true }; return false }?.startTs
        if let b = board, b > now + 1 { return way + " · next \(Fmt.hhmm(b))" }
        return way + " · on the train"
    }

    /// The door-to-door minutes from now, as the routes page's; a way behind the rider, a dash.
    private func minutes(_ l: RouteLane) -> String {
        l.isBehind ? "—" : Fmt.minTxt(max(0, l.arriveTs - now))
    }

    private func arrive(_ l: RouteLane) -> String? {
        if l.isBehind { return nil }
        return "in " + (l.estimated ? "~" : "") + Fmt.hhmm(l.arriveTs)
    }

    /// For VoiceOver: the lines and the change.
    private func spoken(_ l: RouteLane) -> String {
        l.routes.joined(separator: " to ") + (l.changeAt.map { ", change at \($0)" } ?? ", direct") + (l.isBehind ? ", already behind you" : "")
    }
}

/// A lane's stretches drawn to the clock: waits faint, rides in the line's colour (a guess paler), changes dotted.
struct LaneBar: View {
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
