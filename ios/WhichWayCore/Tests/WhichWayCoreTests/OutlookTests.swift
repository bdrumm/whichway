import XCTest
@testable import WhichWayCore

// Synthetic riders only: stations "A", "B", "C" and made-up times, never a real trip's timeline.
final class OutlookTests: XCTestCase {
    private let ny = TimeZone(identifier: "America/New_York")!
    /// September 2026: the 7th, 14th, 21st and 28th are Mondays; October 5th is a Monday too.
    private func ts(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
        return cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!.timeIntervalSince1970
    }
    private func ride(_ o: String, _ d: String, _ at: Double, via x: String? = nil, _ keys: [String]) -> RouteRide {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
        let c = cal.dateComponents([.hour, .minute, .weekday], from: Date(timeIntervalSince1970: at))
        return RouteRide(origin: o, dest: d, transfer: x, legs: keys.enumerated().map { RiddenLeg(leg: $0.offset, key: $0.element, from: $0.offset == 0 ? o : (x ?? "")) },
                         ts: at, hour: Double(c.hour!) + Double(c.minute!) / 60, weekday: c.weekday!)
    }

    /// Four weeks of office days (Sep 7 to Oct 2): A to B in the morning and back in the evening, every Tuesday, three
    /// Wednesdays, two Thursdays, never a Monday or Friday. Mostly the F changing to the A at X, twice the G direct.
    private func officeDays() -> [RouteRide] {
        var out: [RouteRide] = []
        let tue = [8, 15, 22, 29], wed = [9, 16, 23], thu = [10, 24]
        for (i, d) in (tue + wed + thu).enumerated() {
            let minute = [30, 40, 50, 35, 45][i % 5]
            let direct = i % 4 == 3
            out.append(ride("A", "B", ts(9, d, 9, minute), via: direct ? nil : "X", direct ? ["G_N"] : ["F_N", "A_N"]))
            out.append(ride("B", "A", ts(9, d, 17, minute), via: "X", ["A_S", "F_S"]))
        }
        return out.sorted { $0.ts < $1.ts }
    }

    func testOfficeDaysPredictTuesdayNotMonday() {
        let now = ts(10, 5, 7)    // Monday Oct 5, 7:00
        let trips = CommuteOutlook.trips(rides: officeDays(), presets: [], now: now, days: 2, timeZone: ny)
        XCTAssertTrue(trips.filter { $0.day == "2026-10-05" }.isEmpty, "never a Monday: nothing today")
        let tue = trips.filter { $0.day == "2026-10-06" }
        XCTAssertEqual(tue.map { "\($0.origin)>\($0.dest)" }, ["A>B", "B>A"], "out in the morning, back in the evening, in order")
        let am = tue[0]
        XCTAssertEqual(am.source, .habit)
        XCTAssertGreaterThanOrEqual(am.likelihood, 0.8, "every Tuesday so far")
        XCTAssertEqual(am.days, 9)
        XCTAssertEqual(am.route?.keys, ["F_N", "A_N"], "the usual way, not the occasional G")
        XCTAssertEqual(am.route?.transfer, "X")
        // set out between 9:30 and 9:50 on Tuesdays: the middle and the edges fall inside
        XCTAssertGreaterThanOrEqual(am.earlyTs, ts(10, 6, 9, 30)); XCTAssertLessThanOrEqual(am.lateTs, ts(10, 6, 9, 50))
        XCTAssertTrue(am.earlyTs <= am.leaveTs && am.leaveTs <= am.lateTs)
    }

    func testThursdayLessLikelyThanTuesday() {
        let now = ts(10, 7, 20)   // Wednesday evening: Thursday is tomorrow
        let trips = CommuteOutlook.trips(rides: officeDays(), presets: [], now: now, days: 2, timeZone: ny)
        let thu = trips.first { $0.day == "2026-10-08" && $0.origin == "A" }
        XCTAssertNotNil(thu, "two Thursdays of four is still a possible trip")
        let tueTrips = CommuteOutlook.trips(rides: officeDays(), presets: [], now: ts(10, 5, 20), days: 2, timeZone: ny)
        let tue = tueTrips.first { $0.day == "2026-10-06" && $0.origin == "A" }!
        XCTAssertLessThan(thu!.likelihood, tue.likelihood)
    }

    func testTripMadeTodayOrPastIsDropped() {
        var rides = officeDays()
        rides.append(ride("A", "B", ts(10, 6, 9, 35), via: "X", ["F_N", "A_N"]))
        // Tuesday 11:00, the morning trip made: only the evening one is left today
        let trips = CommuteOutlook.trips(rides: rides, presets: [], now: ts(10, 6, 11), days: 1, timeZone: ny)
        XCTAssertEqual(trips.map { $0.origin }, ["B"])
        // Tuesday 11:00 with no ride today: the morning window ended over half an hour ago, so it is gone too
        let skipped = CommuteOutlook.trips(rides: officeDays(), presets: [], now: ts(10, 6, 11), days: 1, timeZone: ny)
        XCTAssertEqual(skipped.map { $0.origin }, ["B"])
    }

    func testRestartsTheSameDayCountOnceAndTwoDaysAreNotAHabit() {
        let rides = [ride("A", "C", ts(9, 29, 8, 0), ["R_N"]), ride("A", "C", ts(9, 29, 8, 1), ["R_N"]), ride("A", "C", ts(9, 29, 8, 2), ["R_N"]),
                     ride("A", "C", ts(9, 30, 8, 0), ["R_N"])]
        XCTAssertTrue(CommuteOutlook.trips(rides: rides, presets: [], now: ts(10, 5, 6), days: 2, timeZone: ny).isEmpty)
    }

    func testOldRidesSayNothing() {
        let rides = officeDays()
        // ten weeks on, the habits have aged out of the lookback
        XCTAssertTrue(CommuteOutlook.trips(rides: rides, presets: [], now: ts(12, 7, 6), days: 2, timeZone: ny).isEmpty)
    }

    func testSavedCommuteTakesTheLearnedTimeAndReplacesTheHabit() {
        let p = CommutePreset(name: "Work", originId: "A", destId: "B", startMinute: 8 * 60, endMinute: 11 * 60)
        let trips = CommuteOutlook.trips(rides: officeDays(), presets: [p], now: ts(10, 5, 20), days: 2, timeZone: ny)
        let tue = trips.filter { $0.day == "2026-10-06" && $0.dest == "B" }
        XCTAssertEqual(tue.count, 1, "one trip, not the commute and the habit both")
        XCTAssertEqual(tue[0].source, .commute)
        XCTAssertEqual(tue[0].commuteName, "Work")
        XCTAssertEqual(tue[0].likelihood, 1)
        XCTAssertGreaterThanOrEqual(tue[0].leaveTs, ts(10, 6, 9, 30), "the learned time, not the window's start")
        XCTAssertEqual(tue[0].route?.keys, ["F_N", "A_N"])
        // a saved commute shows on its days even where the habit would not (Monday)
        let mon = CommuteOutlook.trips(rides: officeDays(), presets: [p], now: ts(10, 5, 6), days: 1, timeZone: ny)
        XCTAssertEqual(mon.map { $0.dest }, ["B"])
    }

    func testCommuteWithoutHistoryUsesItsWindowAndItsDays() {
        let p = CommutePreset(name: "Gym", originId: "", destId: "C", startMinute: 18 * 60 + 15, endMinute: 19 * 60, weekdaysOnly: true, useNearestOrigin: true)
        // Friday Oct 9, 7:00: today at 6:15 pm; Saturday is not a weekday
        let trips = CommuteOutlook.trips(rides: [], presets: [p], now: ts(10, 9, 7), days: 2, timeZone: ny)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips[0].leaveTs, ts(10, 9, 18, 15))
        XCTAssertEqual(trips[0].origin, "", "starts from the nearest station")
        XCTAssertNil(trips[0].route)
    }

    func testClockChangeKeepsTheClockTime() {
        // Sunday Nov 1 2026 the clocks go back: Monday's 9:00 is still 9:00 New York time
        let p = CommutePreset(name: "Work", originId: "A", destId: "B", startMinute: 9 * 60, endMinute: 10 * 60)
        let trips = CommuteOutlook.trips(rides: [], presets: [p], now: ts(10, 31, 12), days: 3, timeZone: ny)
        XCTAssertEqual(trips.map { $0.leaveTs }, [ts(11, 2, 9)])
    }

    // MARK: notifications

    private func trip(_ leave: Double, _ source: OutlookTrip.Source = .habit, likelihood: Double = 0.9, name: String? = nil) -> OutlookTrip {
        OutlookTrip(day: "2026-10-06", origin: "A", dest: "B", leaveTs: leave, earlyTs: leave - 600, lateTs: leave + 600, likelihood: likelihood,
                    source: source, commuteName: name, route: OutlookRoute(transfer: "X St", keys: ["F_N", "A_N"], share: 0.7), days: 6)
    }
    private let names: (String) -> String? = { ["A": "Alpha Av", "B": "Beta St"][$0] }

    func testNothingScheduledUntilTurnedOn() {
        let t = [trip(ts(10, 6, 9, 40))]
        XCTAssertTrue(OutlookNotifications.plan(t, settings: OutlookSettings(), now: ts(10, 5, 20), names: names).isEmpty)
    }

    func testNotificationLeadsTheUsualTime() {
        var s = OutlookSettings(); s.enabled = true; s.leadMinutes = 15
        let a = OutlookNotifications.plan([trip(ts(10, 6, 9, 40))], settings: s, now: ts(10, 5, 20), names: names, expectedSec: { _ in 29 * 60 })
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].fireTs, ts(10, 6, 9, 25))
        XCTAssertTrue(a[0].id.hasPrefix(OutlookNotifications.idPrefix))
        XCTAssertEqual(a[0].title, "To Beta St")
        XCTAssertEqual(a[0].body, "You usually leave around 9:40. F, change to the A at X St, about 29 min.")
    }

    func testFiltersByLikelihoodSourceAndTime() {
        var s = OutlookSettings(); s.enabled = true
        let trips = [trip(ts(10, 6, 9, 40), likelihood: 0.3),                      // too unlikely
                     trip(ts(10, 6, 17, 30), .commute, likelihood: 1, name: "Home"), // a commute: always
                     trip(ts(10, 5, 20, 5)),                                        // due before now + lead
                     trip(ts(10, 6, 12, 0), likelihood: 0.6)]
        let a = OutlookNotifications.plan(trips, settings: s, now: ts(10, 5, 20), names: names)
        XCTAssertEqual(a.map { $0.fireTs }, [ts(10, 6, 11, 45), ts(10, 6, 17, 15)])
        XCTAssertEqual(a[1].title, "Home to Beta St")
        s.learnedTrips = false
        XCTAssertEqual(OutlookNotifications.plan(trips, settings: s, now: ts(10, 5, 20), names: names).map { $0.title }, ["Home to Beta St"])
    }

    func testRouteOnlyFromRidesWithEveryLegSettled() {
        var rides = officeDays()
        // three more Tuesdays where only the second leg was settled: they count for the time, not for the way
        for d in [1, 2, 3] {
            var r = ride("A", "B", ts(10, d, 9, 40), via: "X", ["F_N", "A_N"])
            r.legs = [RiddenLeg(leg: 1, key: "A_N", from: "X")]
            rides.append(r)
        }
        let trips = CommuteOutlook.trips(rides: rides, presets: [], now: ts(10, 5, 20), days: 2, timeZone: ny)
        XCTAssertEqual(trips.first { $0.day == "2026-10-06" && $0.origin == "A" }?.route?.keys, ["F_N", "A_N"])
    }

    func testUsualRouteMatchesItsPath() {
        let r = OutlookRoute(transfer: "X", keys: ["F_N", "A_N"], share: 1)
        let via = PathOption(id: "1", legs: [PathLeg(from: "", to: "", keys: ["F_N", "G_N"]), PathLeg(from: "", to: "", keys: ["A_N", "C_N"])],
                             transfer: PathTransfer(stop: "", stop2: "", station: "X", walkSec: 0))
        let other = PathOption(id: "2", legs: [PathLeg(from: "", to: "", keys: ["F_N"]), PathLeg(from: "", to: "", keys: ["A_N"])],
                               transfer: PathTransfer(stop: "", stop2: "", station: "Y", walkSec: 0))
        XCTAssertTrue(outlookTakes(via, r))
        XCTAssertFalse(outlookTakes(other, r), "another change station")
        XCTAssertFalse(outlookTakes(PathOption(id: "3", legs: [PathLeg(from: "", to: "", keys: ["F_N"])]), r), "direct")
    }

    func testRouteText() {
        XCTAssertEqual(OutlookRoute(transfer: nil, keys: ["G_N"], share: 1).text, "G")
        XCTAssertEqual(OutlookRoute(transfer: "Jay St", keys: ["F_N", "A_N"], share: 1).text, "F, change to the A at Jay St")
    }
}
