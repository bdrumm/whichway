import XCTest
@testable import WhichWayCore

final class RouteHabitsTests: XCTestCase {
    private let ny = TimeZone(identifier: "America/New_York")!
    private func ts(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Double {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = ny
        return cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!.timeIntervalSince1970
    }
    private func leg(_ i: Int, _ key: String, _ verdict: LineBelief.Verdict = .onPlan) -> BoardedLeg {
        BoardedLeg(leg: i, key: key, trainId: nil, chosenKey: nil, confidence: 0.9, verdict: verdict, evidence: [])
    }
    /// A finished trip from `o` to `d`, changing at `x` when given, ridden on `keys` leg by leg.
    private func trip(_ o: String, _ d: String, at start: Double, via x: String? = nil, _ keys: [String]) -> TripTimeline {
        var t = TripTimeline(startTs: start, startedBy: "gps", originStation: o, destStation: d, transferStation: x, legs: x == nil ? 1 : 2)
        t.boarded = keys.enumerated().map { leg($0.offset, $0.element) }
        return t
    }
    private func option(_ id: String, _ legs: [[String]], via x: String? = nil) -> PathOption {
        PathOption(id: id, legs: legs.map { PathLeg(from: "", to: "", keys: $0) },
                   transfer: x.map { PathTransfer(stop: "", stop2: "", station: $0, walkSec: 120) })
    }

    func testRecordsSettledLegsOnlyAndCaps() {
        var h = RouteHabits()
        var t = trip("A", "B", at: ts(21, 8), via: "Hoyt", ["G_N", "A_N"])
        t.boarded[1].verdict = .unsure
        XCTAssertTrue(h.record(t, timeZone: ny))
        XCTAssertEqual(h.rides[0].legs, [RiddenLeg(leg: 0, key: "G_N", from: "A")])
        XCTAssertEqual(h.rides[0].transfer, "Hoyt")
        XCTAssertEqual(h.rides[0].weekday, 2)
        t.boarded = [leg(0, "G_N", .unsure)]
        XCTAssertFalse(h.record(t, timeZone: ny), "nothing settled, nothing learned")
        for i in 0..<RouteHabits.cap + 10 { h.record(trip("A", "B", at: ts(1, 0) + Double(i) * 3600, ["F_S"]), timeZone: ny) }
        XCTAssertEqual(h.rides.count, RouteHabits.cap)
    }

    func testLinePriorFollowsTheRiderAtThePlatformAndHour() {
        var h = RouteHabits()
        // mornings from A to B: the F four days, the G once; evenings from A to C, always the G
        for d in 21...24 { h.record(trip("A", "B", at: ts(d, 8, 10), ["F_N"]), timeZone: ny) }
        h.record(trip("A", "B", at: ts(25, 8, 20), ["G_N"]), timeZone: ny)
        for d in 21...23 { h.record(trip("A", "C", at: ts(d, 19), ["G_N"]), timeZone: ny) }
        let now = ts(28, 8, 15)
        let am = try! XCTUnwrap(h.linePrior(boardingAt: "A", leg: 0, toward: "B", hour: 8.25, weekday: 2, now: now))
        XCTAssertGreaterThan(am.share("F_N"), 0.7)
        XCTAssertLessThan(am.share("G_N"), 0.25)
        let pm = try! XCTUnwrap(h.linePrior(boardingAt: "A", leg: 0, toward: "C", hour: 19, weekday: 2, now: now))
        XCTAssertGreaterThan(pm.share("G_N"), 0.85, "heading for C the rider takes the G")
        let fit = am.fit(["F_N", "G_N", "R_N"])
        XCTAssertGreaterThan(fit["F_N"]!, 1.1)
        XCTAssertLessThan(fit["R_N"]!, 0.9)
        XCTAssertGreaterThan(fit["R_N"]!, 0.6, "a handful of rides never rules a line out")
        XCTAssertNil(h.linePrior(boardingAt: "Z", leg: 0, toward: nil, hour: 8, weekday: 2, now: now))
        // a single ride is not a habit
        var one = RouteHabits()
        one.record(trip("A", "B", at: ts(21, 8), ["F_N"]), timeZone: ny)
        XCTAssertNil(one.linePrior(boardingAt: "A", leg: 0, toward: "B", hour: 8, weekday: 2, now: ts(22, 8)))
    }

    func testOldRidesFadeSoANewHabitTakesOver() {
        var h = RouteHabits()
        for d in 1...6 { h.record(trip("A", "B", at: ts(d, 8) - 150 * 86400, ["F_N"]), timeZone: ny) }  // five months ago
        for d in 21...23 { h.record(trip("A", "B", at: ts(d, 8), ["G_N"]), timeZone: ny) }
        let p = try! XCTUnwrap(h.linePrior(boardingAt: "A", leg: 0, toward: "B", hour: 8, weekday: 3, now: ts(24, 8)))
        XCTAssertGreaterThan(p.share("G_N"), p.share("F_N"))
    }

    func testTransferPriorIsTheLineTakenAfterTheOneRidden() {
        var h = RouteHabits()
        // at Hoyt off the G: the A three times, the C once; off the F (another trip) always the C
        for d in 21...23 { h.record(trip("A", "B", at: ts(d, 8), via: "Hoyt", ["G_N", "A_N"]), timeZone: ny) }
        h.record(trip("A", "B", at: ts(24, 8), via: "Hoyt", ["G_N", "C_N"]), timeZone: ny)
        for d in 21...23 { h.record(trip("D", "B", at: ts(d, 8), via: "Hoyt", ["F_N", "C_N"]), timeZone: ny) }
        let now = ts(25, 8)
        let offG = try! XCTUnwrap(h.transferPrior(at: "Hoyt", from: "G_N", toward: "B", hour: 8, weekday: 6, now: now))
        XCTAssertEqual(offG.share("A_N"), 0.75, accuracy: 0.05)
        let offF = try! XCTUnwrap(h.transferPrior(at: "Hoyt", from: "F_N", toward: "B", hour: 8, weekday: 6, now: now))
        XCTAssertEqual(offF.share("C_N"), 1, accuracy: 1e-9)
    }

    func testUsualRouteGetsTheRankingNudge() {
        var h = RouteHabits()
        for d in 21...24 { h.record(trip("A", "B", at: ts(d, 8), via: "Hoyt", ["G_N", "A_N"]), timeZone: ny) }
        h.record(trip("A", "B", at: ts(25, 8), ["F_N"]), timeZone: ny)
        let now = ts(28, 8)
        let change = option("G>AC", [["G_N"], ["A_N", "C_N"]], via: "Hoyt"), direct = option("F", [["F_N"]])
        let a = try! XCTUnwrap(h.routeAffinity(change, origin: "A", dest: "B", hour: 8, weekday: 2, now: now))
        XCTAssertEqual(a, 0.8, accuracy: 0.05)
        let b = try! XCTUnwrap(h.routeAffinity(direct, origin: "A", dest: "B", hour: 8, weekday: 2, now: now))
        XCTAssertEqual(b, 0.2, accuracy: 0.05)
        XCTAssertGreaterThan(RouteHabits.rankNudgeSec(a), 40)
        XCTAssertEqual(RouteHabits.rankNudgeSec(b), 0)
        XCTAssertEqual(RouteHabits.rankNudgeSec(1), RouteHabits.maxRankNudgeSec)
        XCTAssertEqual(RouteHabits.rankNudgeSec(nil), 0)
        XCTAssertNil(h.routeAffinity(direct, origin: "B", dest: "A", hour: 8, weekday: 2, now: now), "never ridden that way")
    }
}
