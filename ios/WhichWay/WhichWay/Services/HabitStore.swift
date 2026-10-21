import Foundation
import Observation

/// Which trips this rider makes, when and from where, and which trains they ride on them: on the phone only.
/// Suggests the likely route for the moment and the stations that look like Home and Work; gives the line
/// inference the rider's usual lines and the planner their usual routes.
@MainActor
@Observable
final class HabitStore {
    static let shared = HabitStore()
    private(set) var habits: Habits
    private(set) var routes: RouteHabits
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let routesFile: URL

    init() {
        let root = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let dir = root.appendingPathComponent("WhichWay/personal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("habits.json")
        habits = (try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode(Habits.self, from: $0) } ?? Habits()
        file = f
        let rf = dir.appendingPathComponent("routes.json")
        routes = (try? Data(contentsOf: rf)).flatMap { try? JSONDecoder().decode(RouteHabits.self, from: $0) } ?? RouteHabits()
        routesFile = rf
    }

    /// A finished trip's lines, where the phone settled them.
    func learnRide(_ t: TripTimeline) {
        if routes.record(t, timeZone: Fmt.ny), let d = try? JSONEncoder().encode(routes) { try? d.write(to: routesFile, options: .atomic) }
    }

    /// New York hour and weekday of a moment, as the habits keep them.
    static func when(_ ts: Double) -> (hour: Double, weekday: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Fmt.ny
        let c = cal.dateComponents([.hour, .minute, .weekday], from: Date(timeIntervalSince1970: ts))
        return (Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60, c.weekday ?? 1)
    }

    /// The rider's lines boarding at a station on a leg, heading for `dest` (`RouteHabits.linePrior`).
    func linePrior(boardingAt station: String, leg: Int, toward dest: String?, after fromKey: String? = nil, now: Double) -> LinePrior? {
        let w = HabitStore.when(now)
        return routes.linePrior(boardingAt: station, leg: leg, toward: dest, after: fromKey, hour: w.hour, weekday: w.weekday, now: now)
    }

    /// The share of the rider's trips like this one that took route `p` (`RouteHabits.routeAffinity`).
    func routeAffinity(_ p: PathOption, origin: String, dest: String, now: Double) -> Double? {
        let w = HabitStore.when(now)
        return routes.routeAffinity(p, origin: origin, dest: dest, hour: w.hour, weekday: w.weekday, now: now)
    }

    func record(origin: String, dest: String, ts: Double, lat: Double?, lon: Double?) {
        let before = habits.uses.count
        habits.record(origin: origin, dest: dest, ts: ts, lat: lat, lon: lon, timeZone: Fmt.ny)
        if habits.uses.count != before, let d = try? JSONEncoder().encode(habits) { try? d.write(to: file, options: .atomic) }
    }

    func likelyTrip(now: Double, lat: Double?, lon: Double?) -> HabitGuess? {
        let w = HabitStore.when(now)
        return habits.likelyTrip(hour: w.hour, weekday: w.weekday, lat: lat, lon: lon)
    }

    func reset() {
        habits = Habits()
        routes = RouteHabits()
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: routesFile)
    }
}
