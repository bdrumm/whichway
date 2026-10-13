import SwiftUI

/// Route tab: the Go tab's route, one leg's line at a time. Summary (the default) is the line's health on the
/// rider's stretch and the track with every train on it; End to end, the whole route as a time chart; Map, the route
/// on the map; Insights & trains, the engine's figures, scenarios, alerts and every train on the line.
struct LineBoardView: View {
    @Environment(DataService.self) private var data
    @AppStorage("lineKey") private var lineKey = ""
    @AppStorage("routeSection") private var section: RouteSection = .summary

    /// One line shown: the route's leg on it (its stretch and the train it takes), or the line picked with no route.
    struct LineCtx: Identifiable {
        var leg: Int?
        var key: String
        var trainId: String?
        var span: StopSpan?
        var id: String { "\(leg ?? -1)|\(key)" }
    }

    /// Every line of the Go tab's route, in order; with no route, the line picked here.
    private var lines: [LineCtx] {
        if let legs = data.focus?.legs, !legs.isEmpty {
            return legs.enumerated().map { i, l in LineCtx(leg: i, key: l.key, trainId: l.trainId ?? (i == 0 && data.focus?.key == l.key && !(data.focus?.trainId ?? "").isEmpty ? data.focus?.trainId : nil), span: l.idx[l.key]) }
        }
        return lineKey.isEmpty ? [] : [LineCtx(leg: nil, key: lineKey, trainId: nil, span: nil)]
    }

    enum RouteSection: String, CaseIterable, Identifiable {
        case summary = "Summary", endToEnd = "End to end", map = "Map", insights = "Insights"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let sched = data.schedule {
                    content(sched)
                } else {
                    ProgressView("Loading the schedule…")
                }
            }
            .navigationTitle("Route")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusDot() } }
        }
        .onAppear { follow(); register() }
        .onChange(of: lineKey) { _, _ in register() }
        .onChange(of: data.staticVersion) { _, _ in register() }
        .onChange(of: data.focus) { _, _ in follow(); register() }
    }

    /// The Go tab's selected route: this tab shows its line, with the train to take marked.
    private func follow() {
        if let f = data.focus, data.schedule?.lines[f.key] != nil, lineKey != f.key { lineKey = f.key }
    }

    private func register() {
        guard let s = data.schedule else { return }
        if lineKey.isEmpty || s.lines[lineKey] == nil { lineKey = sortedKeys(s).first ?? "" }
        let keys = (data.focus?.legs.map(\.key)).map(Set.init) ?? (lineKey.isEmpty ? [] : [lineKey])
        data.setWanted(keys, for: "line")
    }

    /// One stop before the train to take, so the diagram opens on it.
    private func focusStop(_ c: LineCtx, _ line: LineTopology) -> Int? {
        guard let id = c.trainId, let b = data.boards[c.key], let t = b.trains.first(where: { $0.id == id }) else { return nil }
        return max(0, Int(trainProgress(t, age: data.now - b.now, line: line).idx.rounded(.down)) - 1)
    }

    private func sortedKeys(_ s: ClientSchedule) -> [String] {
        s.lines.keys.sorted { a, b in
            let pa = a.split(separator: "_").map(String.init), pb = b.split(separator: "_").map(String.init)
            if pa.first != pb.first { return (pa.first ?? "") < (pb.first ?? "") }
            return (pa.last ?? "") < (pb.last ?? "")
        }
    }

    private func title(_ key: String, _ s: ClientSchedule) -> String {
        let parts = key.split(separator: "_").map(String.init)
        let route = parts.first ?? key
        let terminal = s.lines[key]?.names.last ?? (parts.last ?? "")
        return "\(route) → \(terminal)"
    }

    private func content(_ sched: ClientSchedule) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let legs = data.focus?.legs, !legs.isEmpty {
                    // alerts that touch this route directly come first: station and entrance notices at its stops, skipped
                    // stops, and line-wide delays on its lines
                    // the model's reading orders them: in effect, starting, waning, no sign, stale, then planned work and notices
                    let direct = data.alertsAffecting(legs: legs, schedule: sched).map { ($0.alert, $0.station, data.assess($0.alert)) }.sorted { x, y in
                        let px = x.2?.priority ?? (x.0.kind == "delay" ? 5 : (x.0.kind == "planned" ? 6 : 7))
                        let py = y.2?.priority ?? (y.0.kind == "delay" ? 5 : (y.0.kind == "planned" ? 6 : 7))
                        return px != py ? px < py : (x.2?.excessSec ?? 0) > (y.2?.excessSec ?? 0)
                    }
                    if !direct.isEmpty {
                        Text("Affects your route").font(.subheadline.bold()).padding(.top, 2)
                        ForEach(direct.prefix(4), id: \.0.id) { item in
                            AlertCard(alert: item.0, evidence: alertEvidence(item.0, data: data), station: item.1, assessment: item.2)
                        }
                    }
                } else {
                    Picker("Line", selection: $lineKey) {
                        ForEach(sortedKeys(sched), id: \.self) { k in Text(title(k, sched)).tag(k) }
                    }
                    .pickerStyle(.menu)
                }
                if !lines.isEmpty {
                    Picker("View", selection: $section) {
                        ForEach(RouteSection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 2)
                    switch section {
                    case .summary:
                        // every line of the route, one after another: its health on the rider's stretch, the train, the track
                        ForEach(lines) { c in
                            if let line = sched.lines[c.key] { summary(sched, c, line: line, multi: lines.count > 1) }
                        }
                    case .endToEnd:
                        if let c = lines.first, let line = sched.lines[c.key] { endToEnd(sched, c, line: line) }
                    case .map:
                        if let p = data.focusOption, data.focus != nil {
                            RouteMapView(option: p, schedule: sched).frame(height: 460).clipShape(RoundedRectangle(cornerRadius: 12))
                            Text("\(p.label): the route's track, its stops, and the trains where they are now.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Choose a route on the Go tab to see it on the map.").font(.footnote).foregroundStyle(.secondary)
                        }
                    case .insights:
                        ForEach(lines) { c in
                            if let line = sched.lines[c.key] { insights(sched, c, line: line, multi: lines.count > 1) }
                        }
                    }
                }
                if let err = data.lastError { Text(err).font(.caption2).foregroundStyle(Color.red) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .onChange(of: data.focus) { _, f in
            if let f = f, section == .insights { withAnimation { proxy.scrollTo("train-\(f.trainId)", anchor: .center) } }
        }
        }
    }

    /// A line's heading when the route has more than one: its bullet, which leg, and the stretch.
    @ViewBuilder private func lineHeading(_ sched: ClientSchedule, _ c: LineCtx, line: LineTopology) -> some View {
        let route = String(c.key.split(separator: "_").first ?? "")
        let from = c.span.flatMap { $0.from < line.names.count ? line.names[$0.from] : nil } ?? ""
        let to = c.span.flatMap { $0.to < line.names.count ? line.names[$0.to] : nil } ?? ""
        HStack(spacing: 8) {
            RouteBullets(routes: [route], size: 22)
            Text("Line \((c.leg ?? 0) + 1)").font(.headline)
            if !from.isEmpty { Text("\(from) → \(to)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .padding(.top, 6)
    }

    /// The first view, per line of the route: how it is doing on the rider's stretch, their train, and the track with
    /// every train on it.
    @ViewBuilder private func summary(_ sched: ClientSchedule, _ c: LineCtx, line: LineTopology, multi: Bool) -> some View {
        let route = String(c.key.split(separator: "_").first ?? "")
        if multi { lineHeading(sched, c, line: line) }
        if let h = lineHealth(key: c.key, data: data, span: c.span) {
            LineHealthRow(health: h, route: route)
        }
        if let id = c.trainId, let b = data.boards[c.key], let t = b.trains.first(where: { $0.id == id }) {
            Text("Your train: \(shortLabel(t)), \(t.position?.text ?? "position unknown") · \(t.lateLabel).")
                .font(.caption).foregroundStyle(.secondary)
        }
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            TrackDiagramView(line: line, route: route, fromIdx: c.span?.from, toIdx: c.span?.to, trains: trains(c, line), colW: 52,
                             scrollTo: focusStop(c, line) ?? c.span.map { max(0, $0.from - 1) })
        }
        if data.boards[c.key] == nil { Text("Waiting for the feed…").font(.caption).foregroundStyle(.secondary) }
    }

    /// The whole route as a time chart: every leg's trains and the change between them; on a direct route, its line's.
    @ViewBuilder private func endToEnd(_ sched: ClientSchedule, _ c: LineCtx, line: LineTopology) -> some View {
        let route = String(c.key.split(separator: "_").first ?? "")
        if let legs = data.focus?.legs, legs.count > 1, legs.allSatisfy({ data.boards[$0.key] != nil }) {
            var preds: [String: LinePrediction] = [:]
            let _ = legs.forEach { l in if let p = data.predictions[l.key]?[data.scenario] ?? data.predictions[l.key]?["baseline"] { preds[l.key] = p } }
            RouteChartCard(legs: legs, schedule: sched, boards: data.boards, predictions: preds)
        } else if let lp = data.predictions[c.key]?[data.scenario] ?? data.predictions[c.key]?["baseline"], let raw = data.boards[c.key], !raw.trains.isEmpty {
            PredictionCard(line: line, board: raw, prediction: lp, focusedTrainId: c.trainId, span: c.span, route: route)
        } else {
            Text("Waiting for the feed…").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The figures behind it, per line: the counts, the engine's projection and its scenarios, the other alerts, and
    /// every train on the line with its lateness, position, holds and last run.
    @ViewBuilder private func insights(_ sched: ClientSchedule, _ c: LineCtx, line: LineTopology, multi: Bool) -> some View {
        let route = String(c.key.split(separator: "_").first ?? "")
        if multi { lineHeading(sched, c, line: line) }
        if let b = data.predictedBoards[c.key] ?? data.boards[c.key] {
            HStack(spacing: 8) {
                Tile(title: "Trains", value: "\(b.trains.count)", sub: "started, in the feed")
                Tile(title: "Held / overdue", value: "\(b.nHolding) / \(b.nStalled)", sub: "≥ \(Int(sched.constants.holdSec)) s at a stop / late between stops")
                Tile(title: "Gaps ≥ 3 min", value: "\(b.trains.filter { ($0.concernSec ?? 0) >= 180 }.count)",
                     sub: "over the usual spacing · \(b.trains.filter { ($0.effectiveLatenessSec ?? 0) >= 180 }.count) late by the timetable")
            }
            if let lp = data.predictions[c.key]?[data.scenario] ?? data.predictions[c.key]?["baseline"] {
                if multi, let raw = data.boards[c.key], !raw.trains.isEmpty {
                    PredictionCard(line: line, board: raw, prediction: lp, focusedTrainId: c.trainId, span: c.span, route: route)
                }
                EngineCards(prediction: lp, line: line)
            }
            if c.leg == nil || c.leg == 0 { ScenarioPicker() }
            let directIds = Set((data.focus?.legs).map { data.alertsAffecting(legs: $0, schedule: sched).map { $0.alert.id } } ?? [])
            let alerts = data.rankedAlerts(routes: [route]).filter { !directIds.contains($0.alert.id) }
            if !alerts.isEmpty {
                Text(directIds.isEmpty ? "Alerts on the \(route)" : "Other alerts on the \(route)").font(.subheadline.bold()).padding(.top, 2)
                ForEach(alerts.prefix(4), id: \.alert.id) { x in AlertCard(alert: x.alert, evidence: alertEvidence(x.alert, data: data), assessment: x.assessment) }
            }
            Text("Trains on the line").font(.subheadline.bold()).padding(.top, 2)
            ForEach(b.trains) { t in TrainRow(train: t, focused: t.id == c.trainId).id("train-\(t.id)") }
            if b.trains.isEmpty { Text("No started train on this line in the feed.").font(.caption).foregroundStyle(.secondary) }
        } else {
            Text("Waiting for the feed…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func trains(_ c: LineCtx, _ line: LineTopology) -> [DiagramTrain] {
        guard let b = data.boards[c.key] else { return [] }
        let age = data.now - b.now
        let focus = c.trainId
        return b.trains.map { t in
            let p = trainProgress(t, age: age, line: line)
            let sub = t.lateNote ?? ""
            return DiagramTrain(id: t.id, idx: p.idx, state: p.state, route: t.route, label: shortLabel(t), sub: sub, emphasis: t.id == focus ? "origin" : nil)
        }
    }
}

struct TrainRow: View {
    let train: LiveTrain
    var focused: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RouteBullet(route: train.route, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(shortLabel(train)).font(.caption.monospaced().bold())
                    Spacer()
                    Text("next \(train.nextName) \(Fmt.hhmm(train.feedPoints?.first?.ts ?? train.etaTs))").font(.caption).lineLimit(1)
                }
                if let text = engineText {
                    Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(train.position?.text ?? "position unknown").font(.caption2).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if focused { Flag("your train", Color.green) }
                        Text(train.lateLabel + (train.practicalLatenessSec == nil && train.schedMethod == "nearest" ? " ~" : ""))
                            .font(.caption2).foregroundStyle(latenessColor)
                        if train.corroboration == "feed_optimistic" { Flag("feed optimistic", Color.orange) }
                        if let p = train.position, p.holding { Flag("held \(Fmt.mmss(p.sinceSec))", Color.orange) }
                        if let p = train.position, p.stalled { Flag("overdue", Color.red) }
                        if train.trackChanged { Flag("track change", Color.purple) }
                        if let lr = train.lastRun, let sp = lr.speedKmh {
                            Text("last run \(Fmt.mph(sp))" + (lr.schedSpeedKmh.map { " (sched \(Fmt.mph($0)))" } ?? ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(focused ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? Color.accentColor : Color.clear, lineWidth: 1))
    }

    private var engineText: String? {
        guard let pr = train.pred, let pt = pr.point(at: train.nextIdx) else { return nil }
        var s = "engine \(Fmt.hhmm(pt.etaTs)) · \(Fmt.hhmm(pt.loTs))–\(Fmt.hhmm(pt.hiTs))"
        if pr.holdExtraSec > 0 { s += " · +\(Int(pr.holdExtraSec.rounded())) s expected hold" }
        if pr.knockOnSec >= 60 { s += " · held back \(Fmt.mmss(pr.knockOnSec))" }
        return s
    }

    private var latenessColor: Color {
        guard let e = train.concernSec else { return Color.secondary }
        if e >= 300 { return Color.red }
        if e >= 120 { return Color.orange }
        return Color.secondary
    }
}


/// The lines of the selected route as tabs: the line's bullet, where it is boarded and left, and the train taken.
struct LegTabs: View {
    @Environment(DataService.self) private var data
    let legs: [FocusLeg]
    let schedule: ClientSchedule
    @Binding var lineKey: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(legs.enumerated()), id: \.offset) { i, leg in
                let route = String(leg.key.split(separator: "_").first ?? "")
                let selected = leg.keys.contains(lineKey)
                let names = schedule.lines[leg.key]?.names ?? []
                let span = leg.idx[leg.key]
                let board = span.flatMap { $0.from < names.count ? names[$0.from] : nil } ?? ""
                let alight = span.flatMap { $0.to < names.count ? names[$0.to] : nil } ?? ""
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { lineKey = leg.key }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            RouteBullets(routes: [route], size: 20)
                            Text(legs.count > 1 ? "Line \(i + 1)" : "Your line").font(.caption.bold()).foregroundStyle(selected ? Color.primary : Color.secondary)
                            Spacer(minLength: 0)
                            if let h = lineHealth(key: leg.key, data: data, span: span) {
                                Circle().fill(h.color).frame(width: 8, height: 8).accessibilityLabel(h.label)
                            }
                        }
                        Text(board.isEmpty || alight.isEmpty ? "the whole line" : "\(board) → \(alight)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(route) line, \(board) to \(alight)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// What the engine projects for the line in the next hour, as two tiles: the largest gap, and the knock-on
/// from the train ahead.
struct EngineCards: View {
    let prediction: LinePrediction
    let line: LineTopology

    var body: some View {
        HStack(spacing: 8) {
            if let w = prediction.worstGap {
                let name = w.idx < line.names.count ? line.names[w.idx] : "stop \(w.idx)"
                Tile(title: "Largest gap ahead", value: Fmt.minTxt(w.gapSec), sub: "at \(name) · around \(Fmt.hhmm(w.atTs))")
            } else {
                Tile(title: "Largest gap ahead", value: "none", sub: "no gap projected in the next hour")
            }
            if prediction.nKnockOn > 0 {
                Tile(title: "Held back", value: "\(prediction.nKnockOn) train\(prediction.nKnockOn == 1 ? "" : "s")", sub: "by the train ahead · \(Fmt.minTxt(prediction.knockOnTotalSec)) in total")
            } else {
                Tile(title: "Held back", value: "none", sub: "no train slowed by the one ahead")
            }
        }
    }
}

/// One alert as a card: its kind, what it says, and whether the live boards bear it out.
struct AlertCard: View {
    let alert: RouteAlert
    let evidence: AlertEvidence
    var station: String? = nil      // the station on your route this alert names
    /// The delay model's reading: a status, active or stale, and the interpretation (starting, in effect, waning…).
    var assessment: DelayAssessment? = nil

    private func phaseColor(_ p: DelayAssessment.Phase) -> Color {
        switch p {
        case .inEffect: return .red
        case .starting: return .orange
        case .waning: return Color(red: 0.85, green: 0.65, blue: 0.0)
        case .stale, .unconfirmed: return .secondary
        }
    }

    private var kindColor: Color {
        switch alert.kind {
        case "delay": return .red
        case "planned": return .orange
        default: return .secondary
        }
    }

    private var kindTitle: String {
        switch alert.kind {
        case "delay": return "Delays"
        case "planned": return "Planned work"
        default: return "Notice"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Flag(kindTitle, kindColor)
                if let s = assessment { Flag(s.active ? "active" : "stale", s.active ? Color.red : Color.secondary) }
                RouteBullets(routes: alert.routes, size: 16)
                if let st = station { Flag("at \(st)", Color.accentColor) }
                Spacer()
            }
            Text(alert.header).font(.subheadline).lineLimit(station == nil ? 3 : 5)
            if let s = assessment {
                // the model's interpretation: the phase, what the trains near the station say, the odds it is gone soon
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(phaseColor(s.phase)).frame(width: 7, height: 7).padding(.top, 5)
                    Text(s.interpretation).font(.caption).foregroundStyle(s.active ? phaseColor(s.phase) : Color.secondary).lineLimit(3)
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(evidence.corroborated ? Color.red : Color.secondary.opacity(0.6)).frame(width: 7, height: 7).padding(.top, 5)
                    Text(evidence.text).font(.caption).foregroundStyle(evidence.corroborated ? Color.red : Color.secondary).lineLimit(2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(kindColor.opacity(alert.kind == "delay" ? 0.5 : 0.25), lineWidth: 1))
    }
}
