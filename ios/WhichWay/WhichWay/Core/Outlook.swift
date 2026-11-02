import Foundation

// The commute outlook: which trips this rider is expected to make today and tomorrow, about when they set out, the
// way they usually go, and the notification that goes ahead of each. Read from what the phone already keeps: the
// rides of `RouteHabits` (each finished trip's stations, lines, start time and weekday) and the saved commutes.
// Nothing new is collected and nothing leaves the phone. The rider's habits repeat by weekday, not by weekday versus
// weekend (office days: a trip on every Tuesday, most Wednesdays and Thursdays, hardly a Monday or Friday), so the
// likelihood is learned per weekday, pulled toward the rate of the same kind of day while few weeks are known.

/// The route a rider usually takes on a trip: the change (or none) and the line ridden on each leg.
struct OutlookRoute: Equatable {
    var transfer: String?
    var keys: [String]
    /// Share of the trip's weighted rides that went this way.
    var share: Double

    /// "F, change to the A at Jay St-MetroTech", or "F" for a direct ride.
    var text: String {
        let lines = keys.map(OutlookRoute.lineName)
        guard let first = lines.first else { return "" }
        guard lines.count > 1 else { return first }
        let rest = lines.dropFirst().joined(separator: ", then the ")
        return transfer.map { "\(first), change to the \(rest) at \($0)" } ?? "\(first), then the \(rest)"
    }

    /// "F" for the line key "F_N".
    static func lineName(_ key: String) -> String { key.split(separator: "_").first.map(String.init) ?? key }
}

/// One trip the rider is expected to make on a given day.
struct OutlookTrip: Equatable, Identifiable {
    enum Source: String, Equatable { case commute, habit }

    var day: String               // New York calendar day, Fmt.dayStamp
    var origin: String            // station id; "" for a commute that starts from the nearest station
    var dest: String
    /// When the rider usually sets out (the trip's start: the route started by hand or on reaching the station).
    var leaveTs: Double
    /// The usual spread of the set-out time on such days: early and late edges.
    var earlyTs: Double
    var lateTs: Double
    /// How likely the trip is that day, 0…1 (a saved commute counts 1 on its days).
    var likelihood: Double
    var source: Source
    var commuteName: String? = nil
    var route: OutlookRoute? = nil
    /// Days with a ride behind the prediction.
    var days: Int

    var id: String { "\(day)|\(origin)>\(dest)|\(Int(leaveTs))" }

    var likelihoodText: String {
        if source == .commute { return "Saved commute" }
        if likelihood >= 0.8 { return "Very likely" }
        if likelihood >= 0.5 { return "Likely" }
        return "Possible"
    }
}

enum CommuteOutlook {
    /// Rides older than this say nothing about the weeks ahead.
    static let lookbackDays = 56.0
    /// A trip is predicted once it was made on this many different days.
    static let minDays = 3
    /// Rides of a trip more than this many hours apart are different trips (the morning one and a late one).
    static let clusterGapHours = 2.0
    /// How many days of the trip's own weekday the likelihood takes from the kind-of-day rate (shrinkage).
    static let priorDays = 2.0
    /// Below this likelihood a learned trip is left out.
    static let minLikelihood = 0.25

    /// One ride per day per trip: the first. A route restarted twice in two minutes is one trip.
    private struct DayRide { var day: String; var ts: Double; var hour: Double; var weekday: Int; var ride: RouteRide }

    /// The expected trips on the next `days` days (today first), in order of the set-out time. A trip already made
    /// today, or whose window ended over half an hour ago, is left out of today.
    static func trips(rides: [RouteRide], presets: [CommutePreset], now: Double, days: Int = 2,
                      timeZone: TimeZone = Fmt.ny) -> [OutlookTrip] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let dayF = DateFormatter()
        dayF.calendar = cal
        dayF.timeZone = timeZone
        dayF.locale = Locale(identifier: "en_US_POSIX")
        dayF.dateFormat = "yyyy-MM-dd"
        let stamp = { (ts: Double) in dayF.string(from: Date(timeIntervalSince1970: ts)) }
        let todayStart = cal.startOfDay(for: Date(timeIntervalSince1970: now))
        let today = stamp(now)

        let clusters = habitClusters(rides: rides, now: now, cal: cal, stamp: stamp)
        var out: [OutlookTrip] = []
        for d in 0..<max(0, days) {
            guard let start = cal.date(byAdding: .day, value: d, to: todayStart) else { continue }
            let dayStart = start.timeIntervalSince1970
            let day = stamp(dayStart)
            let weekday = cal.component(.weekday, from: start)
            // a clock time of that day, kept right across the clock change
            let at = { (hour: Double) -> Double in
                let h = Int(hour), m = Int(((hour - Double(h)) * 60).rounded())
                return cal.date(bySettingHour: min(23, h), minute: min(59, m), second: 0, of: start)?.timeIntervalSince1970 ?? dayStart + hour * 3600
            }
            var dayTrips: [OutlookTrip] = []
            var covered = Set<Int>()
            for p in presets {
                guard p.startMinute != p.endMinute, p.isActive(minuteOfDay: p.startMinute, weekday: weekday), !p.destId.isEmpty else { continue }
                let origin = p.useNearestOrigin ? "" : p.originId
                let inWindow = { (hour: Double) -> Bool in p.isActive(minuteOfDay: Int(hour * 60) % 1440, weekday: weekday) }
                // the learned set-out time of the same trip inside the window, else the window's start
                let match = clusters.indices.first { i in
                    let c = clusters[i]
                    return c.dest == p.destId && (origin.isEmpty || c.origin == origin) && inWindow(c.medianHour(weekday: weekday))
                }
                if let i = match { covered.insert(i) }
                if d == 0, let i = match, clusters[i].rodeOn(today) { continue }
                let startHour = Double(p.startMinute) / 60
                let leave = match.map { clusters[$0].medianHour(weekday: weekday) } ?? startHour
                let spread = match.map { clusters[$0].spread(weekday: weekday) } ?? (startHour, startHour)
                let t = OutlookTrip(day: day, origin: origin, dest: p.destId, leaveTs: at(leave), earlyTs: at(spread.0), lateTs: at(spread.1),
                                    likelihood: 1, source: .commute, commuteName: p.name, route: match.flatMap { clusters[$0].route(weekday: weekday) },
                                    days: match.map { clusters[$0].dayRides.count } ?? 0)
                dayTrips.append(t)
            }
            for (i, c) in clusters.enumerated() where !covered.contains(i) {
                if d == 0 && c.rodeOn(today) { continue }
                let p = c.likelihood(weekday: weekday, today: todayStart.timeIntervalSince1970, cal: cal)
                guard p >= minLikelihood else { continue }
                let s = c.spread(weekday: weekday)
                dayTrips.append(OutlookTrip(day: day, origin: c.origin, dest: c.dest, leaveTs: at(c.medianHour(weekday: weekday)),
                                            earlyTs: at(s.0), lateTs: at(s.1), likelihood: p, source: .habit,
                                            route: c.route(weekday: weekday), days: c.dayRides.count))
            }
            if d == 0 { dayTrips.removeAll { $0.lateTs + 1800 < now } }
            out += dayTrips
        }
        return out.sorted { $0.leaveTs < $1.leaveTs }
    }

    /// A trip the rider repeats: one origin and destination, set-out hours within `clusterGapHours` of each other.
    private struct Cluster {
        var origin: String
        var dest: String
        var dayRides: [DayRide]
        var now: Double

        func rodeOn(_ day: String) -> Bool { dayRides.contains { $0.day == day } }

        func recency(_ r: DayRide) -> Double { pow(0.5, max(0, now - r.ts) / 86400 / RouteHabits.halfLifeDays) }

        /// The rides that speak for a weekday: its own once two are known, else the same kind of day, else all.
        func relevant(weekday: Int) -> [DayRide] {
            let own = dayRides.filter { $0.weekday == weekday }
            if own.count >= 2 { return own }
            let weekend = weekday == 1 || weekday == 7
            let kind = dayRides.filter { ($0.weekday == 1 || $0.weekday == 7) == weekend }
            return kind.count >= 2 ? kind : dayRides
        }

        func quantile(_ q: Double, weekday: Int) -> Double {
            let rs = relevant(weekday: weekday).sorted { $0.hour < $1.hour }
            guard !rs.isEmpty else { return 0 }
            let ws = rs.map(recency), total = ws.reduce(0, +)
            var acc = 0.0
            for (r, w) in zip(rs, ws) {
                acc += w
                if acc >= q * total { return r.hour }
            }
            return rs.last!.hour
        }

        func medianHour(weekday: Int) -> Double { quantile(0.5, weekday: weekday) }
        func spread(weekday: Int) -> (Double, Double) { (quantile(0.2, weekday: weekday), quantile(0.8, weekday: weekday)) }

        /// The most ridden way, by recency, among the rides that speak for the weekday.
        func route(weekday: Int) -> OutlookRoute? {
            var by: [String: (OutlookRoute, Double)] = [:]
            var total = 0.0
            for r in relevant(weekday: weekday) {
                // only rides with every leg settled: a ride whose first leg went unsettled would read as a direct one
                let legs = r.ride.legs.sorted { $0.leg < $1.leg }
                guard !legs.isEmpty, legs.map(\.leg) == Array(0..<(r.ride.transfer == nil ? 1 : 2)) else { continue }
                let keys = legs.map(\.key)
                let w = recency(r)
                let k = "\(r.ride.transfer ?? "")|\(keys.joined(separator: ","))"
                var e = by[k] ?? (OutlookRoute(transfer: r.ride.transfer, keys: keys, share: 0), 0)
                e.1 += w
                by[k] = e
                total += w
            }
            guard total > 0, let best = by.values.max(by: { $0.1 < $1.1 }) else { return nil }
            var r = best.0
            r.share = best.1 / total
            return r
        }

        /// Days of this weekday with the trip over the days of this weekday since the trip was first made (within
        /// the lookback), pulled toward the rate on the same kind of day by `priorDays`.
        func likelihood(weekday: Int, today: Double, cal: Calendar) -> Double {
            guard let first = dayRides.map(\.ts).min() else { return 0 }
            let firstDay = cal.startOfDay(for: Date(timeIntervalSince1970: first))
            let weekend = { (w: Int) in w == 1 || w == 7 }
            var n = [Int: Int](), k = [Int: Int]()
            var day = firstDay
            while day.timeIntervalSince1970 < today {
                n[cal.component(.weekday, from: day), default: 0] += 1
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            for r in dayRides where r.ts < today { k[r.weekday, default: 0] += 1 }
            let kindN = n.filter { weekend($0.key) == weekend(weekday) }.values.reduce(0, +)
            let kindK = k.filter { weekend($0.key) == weekend(weekday) }.values.reduce(0, +)
            let base = kindN > 0 ? Double(kindK) / Double(kindN) : 0
            let nw = Double(n[weekday] ?? 0), kw = Double(k[weekday] ?? 0)
            return min(1, (kw + CommuteOutlook.priorDays * base) / (nw + CommuteOutlook.priorDays))
        }
    }

    private static func habitClusters(rides: [RouteRide], now: Double, cal: Calendar, stamp: (Double) -> String) -> [Cluster] {
        let recent = rides.filter { now - $0.ts <= lookbackDays * 86400 && $0.ts <= now && !$0.origin.isEmpty && !$0.dest.isEmpty }
        var byTrip: [String: [RouteRide]] = [:]
        for r in recent { byTrip["\(r.origin)>\(r.dest)", default: []].append(r) }
        var out: [Cluster] = []
        for key in byTrip.keys.sorted() {
            let rs = byTrip[key]!.sorted { $0.hour < $1.hour }
            var groups: [[RouteRide]] = []
            for r in rs {
                if let last = groups.last?.last, r.hour - last.hour <= clusterGapHours { groups[groups.count - 1].append(r) } else { groups.append([r]) }
            }
            for g in groups {
                var firstOfDay: [String: DayRide] = [:]
                for r in g {
                    let day = stamp(r.ts)
                    if let have = firstOfDay[day], have.ts <= r.ts { continue }
                    firstOfDay[day] = DayRide(day: day, ts: r.ts, hour: r.hour, weekday: r.weekday, ride: r)
                }
                guard firstOfDay.count >= minDays, let r0 = g.first else { continue }
                out.append(Cluster(origin: r0.origin, dest: r0.dest, dayRides: firstOfDay.values.sorted { $0.ts < $1.ts }, now: now))
            }
        }
        return out
    }
}

// MARK: - notifications

/// What the rider set for the outlook. Off until they turn it on.
struct OutlookSettings: Codable, Equatable {
    var enabled = false
    /// Minutes before the usual set-out time that the notification arrives.
    var leadMinutes = 15
    /// Learned trips are notified from this likelihood; saved commutes always.
    var minLikelihood = 0.5
    /// Notify learned trips too, not only saved commutes.
    var learnedTrips = true
}

/// One scheduled notification: an outlook trip, the moment it is shown, and its words.
struct OutlookAlert: Equatable {
    var id: String
    var fireTs: Double
    var title: String
    var body: String
    var origin: String
    var dest: String
}

enum OutlookNotifications {
    /// Every outlook notification's id starts so; rescheduling removes them all and adds the new plan.
    static let idPrefix = "outlook."
    /// iOS keeps 64 pending notifications per app; the outlook takes a few.
    static let maxPending = 8
    /// A notification due in less than this is not scheduled: the rider has the app open, or it is too late.
    static let minAheadSec = 60.0

    /// The notifications for the expected trips: one per trip the settings let through, `leadMinutes` before the usual
    /// set-out time, none in the past. `names` gives a station's name; `expectedSec` the usual door-to-door time of the
    /// trip's route at that hour, when the published data is loaded.
    static func plan(_ trips: [OutlookTrip], settings: OutlookSettings, now: Double,
                     names: (String) -> String?, expectedSec: (OutlookTrip) -> Double? = { _ in nil }) -> [OutlookAlert] {
        guard settings.enabled else { return [] }
        var out: [OutlookAlert] = []
        for t in trips.sorted(by: { $0.leaveTs < $1.leaveTs }) {
            if t.source == .habit && (!settings.learnedTrips || t.likelihood < settings.minLikelihood) { continue }
            let fire = t.leaveTs - Double(max(0, settings.leadMinutes)) * 60
            guard fire >= now + minAheadSec else { continue }
            let destName = names(t.dest) ?? t.dest
            let title = t.commuteName.map { "\($0) to \(destName)" } ?? "To \(destName)"
            out.append(OutlookAlert(id: idPrefix + t.id, fireTs: fire, title: title, body: body(t, expectedSec: expectedSec(t)),
                                    origin: t.origin, dest: t.dest))
            if out.count >= maxPending { break }
        }
        return out
    }

    /// "You usually leave around 9:40. F, change to the A at Jay St-MetroTech, about 29 min."
    static func body(_ t: OutlookTrip, expectedSec: Double?) -> String {
        var s = "You usually leave around \(Fmt.hhmm(t.leaveTs))."
        var way: [String] = []
        if let r = t.route, !r.keys.isEmpty { way.append(r.text) }
        if let e = expectedSec, e > 0 { way.append("about \(Int((e / 60).rounded())) min") }
        if !way.isEmpty { s += " " + way.joined(separator: ", ") + "." }
        return s
    }
}

// MARK: - expected time

/// The usual door-to-door time of an expected trip at its hour, as the planner ranks routes: half the scheduled
/// headway as the wait, the scheduled ride, the time trains typically lose on those stretches at that hour and the
/// hold risk. Taken on the rider's usual route when it is among the paths, else the quickest. Nil without a fixed
/// origin (a commute from the nearest station) or without a path.
func outlookExpectedSec(_ t: OutlookTrip, schedule: ClientSchedule, index: StationIndex, lineSched: [String: [LineSchedEntry]],
                        holds: HoldsSummary?, deviations: [String: LineDeviation]) -> Double? {
    guard !t.origin.isEmpty else { return nil }
    var options = enumeratePaths(schedule: schedule, index: index, from: t.origin, to: t.dest)
    guard !options.isEmpty else { return nil }
    let hour = nyHour(t.leaveTs)
    for i in options.indices {
        evaluate(&options[i], schedule: schedule, lineSched: lineSched, now: t.leaveTs, holds: holds, deviations: deviations, hour: hour)
    }
    if let r = t.route, let usual = options.first(where: { outlookTakes($0, r) }) { return usual.expectedSec }
    return options.map(\.expectedSec).min()
}

/// Whether a path is the usual route: the same change (or none), and each leg carrying the line ridden on it.
func outlookTakes(_ p: PathOption, _ r: OutlookRoute) -> Bool {
    guard p.transfer?.station == r.transfer, p.legs.count == r.keys.count else { return false }
    return zip(p.legs, r.keys).allSatisfy { $0.keys.contains($1) }
}
