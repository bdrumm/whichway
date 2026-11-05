import XCTest
@testable import WhichWayCore

private func fpStart(_ ts: Double = 1000, legs: Int = 1, transfer: String? = nil) -> TripTimeline {
    TripTimeline(startTs: ts, startedBy: "gps", startDistanceM: 20, placeId: nil, originStation: "S1", destStation: "S9",
                 transferStation: transfer, legs: legs)
}
private func fpSec(_ ts: Double, walking: Bool, push: Double = 0.005, shake: Double = 0.005) -> MotionSecond {
    MotionSecond(ts: ts, stepEnergy: walking ? 0.05 : 0.002, pushG: push, shakeG: shake)
}

/// `TripTracker.needsPreciseFixes`: the GPS goes to coarse fixes on the platform and the ride, and comes back wherever a
/// fix decides something: on the way to the station, a walk-off and the five minutes after it, and near the arrival.
/// Every way of making a change is checked, and each one keeps the change itself (the leg in hand) as it was.
final class FixPrecisionTests: XCTestCase {
    private func start(legs: Int = 1) -> TripTimeline { fpStart(legs: legs, transfer: nil) }
    private func sec(_ ts: Double, walking: Bool) -> MotionSecond { fpSec(ts, walking: walking) }

    /// A two-leg trip under way: at the station from 1000, the first train pulls away at about 1030 and rides 300 s.
    /// The arrival is at 4000, so the arrival window (from 3580) is well clear of the change.
    private struct Ride {
        var t: TripTracker
        var ts = 1000.0
        init(legs: Int = 2, arriveTs: Double = 4000) {
            t = TripTracker(fpStart(legs: legs, transfer: legs > 1 ? "X" : nil), distanceToOriginM: 20)
            t.updateForecast(boardTs: 1030, arriveTs: arriveTs, now: 1000)
        }
        mutating func stand(_ n: Int) { for _ in 0..<n { t.motion(fpSec(ts, walking: false)); ts += 1 } }
        mutating func ride(_ n: Int) { for _ in 0..<n { t.motion(fpSec(ts, walking: false, shake: 0.04)); ts += 1 } }
        mutating func depart() { for _ in 0..<6 { t.motion(fpSec(ts, walking: false, push: 0.08, shake: 0.03)); ts += 1 } }
        mutating func walk(_ n: Int) { for _ in 0..<n { t.motion(fpSec(ts, walking: true)); ts += 1 } }
        var precise: Bool { t.needsPreciseFixes(now: ts) }
    }

    func testOnTheWayToTheStationFixesStayPrecise() {
        var t = TripTracker(start(), distanceToOriginM: 900)
        t.updateForecast(boardTs: 1600, arriveTs: 3000, now: 1000)
        t.motion(sec(1000, walking: true))
        XCTAssertEqual(t.phase, .approaching)
        XCTAssertTrue(t.needsPreciseFixes(now: 1001))
    }

    func testOnThePlatformAndTheRideFixesGoCoarse() {
        var r = Ride()
        r.stand(20)
        XCTAssertEqual(r.t.phase, .atStation)
        XCTAssertFalse(r.precise, "standing on the platform: no fix decides anything")
        r.depart(); r.ride(200)
        XCTAssertTrue(r.t.onTrain)
        XCTAssertFalse(r.precise, "riding under the street")
    }

    func testWalkBetweenPlatformsComesBackPreciseForTheWalkAndTheFiveMinutesAfter() {
        var r = Ride()
        r.stand(30); r.depart(); r.ride(300); r.stand(15)
        r.walk(3)
        XCTAssertTrue(r.precise, "steps on a ride: a walk-off may be called")
        r.walk(42)
        XCTAssertEqual(r.t.timeline.legsRidden, 1, "the hand-off is unchanged: the first leg is closed")
        XCTAssertTrue(r.precise)
        r.stand(60)
        XCTAssertTrue(r.precise, "inside the five minutes after the walk-off, when the recorder reads where it was")
        r.depart()
        XCTAssertTrue(r.t.onTrain)
        r.ride(300)
        XCTAssertFalse(r.precise, "on the second train, five minutes past the walk-off")
    }

    func testStepAcrossThePlatformAndAStandingTrainAreTheSameUnfeltAlighting() {
        // two steps across, or none onto a train already standing there: the recorder closes the ride from the feed
        // (`alightStanding`), and the five minutes after it run from the alighting it names
        for steps in [2, 0] {
            var r = Ride()
            r.stand(30); r.depart(); r.ride(300); r.stand(15)
            let off = r.ts
            r.walk(steps)
            r.t.alightStanding(at: off)
            XCTAssertEqual(r.t.timeline.legsRidden, 1, "\(steps) steps: the first leg is closed")
            XCTAssertTrue(r.precise, "\(steps) steps")
            r.stand(20); r.depart(); r.ride(100)
            XCTAssertTrue(r.t.onTrain, "\(steps) steps: on the connection")
            XCTAssertTrue(r.t.needsPreciseFixes(now: off + 299))
            XCTAssertFalse(r.t.needsPreciseFixes(now: off + 301))
        }
    }

    func testStayingOnPastTheChangeStaysCoarseUntilTheArrival() {
        var r = Ride(arriveTs: 3000)
        r.stand(30); r.depart(); r.ride(900)
        XCTAssertEqual(r.t.timeline.legsRidden, 0)
        XCTAssertFalse(r.precise, "still on the first train, well before the arrival")
        r.ride(700)                                       // 2636: inside seven minutes of 3000
        XCTAssertTrue(r.precise, "near the arrival the destination check reads the fixes")
    }

    func testChangingEarlierOrLaterThanPlannedRunsFromTheAlightingItself() {
        for rideSec in [120, 900] {                       // off at an earlier stop, or a later one
            var r = Ride(arriveTs: 5000)
            r.stand(30); r.depart(); r.ride(rideSec); r.stand(15); r.walk(45)
            XCTAssertEqual(r.t.timeline.legsRidden, 1)
            let off = r.t.timeline.events.last { $0.kind == .alighted }!.ts
            r.stand(30)
            XCTAssertTrue(r.precise, "ride \(rideSec) s")
            r.depart(); r.ride(400)
            XCTAssertFalse(r.precise, "ride \(rideSec) s, on the connection")
            XCTAssertTrue(r.t.needsPreciseFixes(now: off + 200))
        }
    }

    func testAChangeNamedByHandComesBackPrecise() {
        // "Changed to the A" on the Live Activity, or "Not on the train" past the change: both close the ride through
        // `alightStanding` at the moment named
        var r = Ride()
        r.stand(30); r.depart(); r.ride(600)
        XCTAssertFalse(r.precise)
        r.t.noteChangedEarly(at: r.ts)
        r.t.alightStanding(at: r.ts - 20)
        XCTAssertEqual(r.t.timeline.legsRidden, 1)
        XCTAssertTrue(r.precise)
    }

    func testWithoutSensorsOrAForecastFixesStayPrecise() {
        // no motion sensors: the fixes are all the route has
        var t = TripTracker(start(legs: 1), distanceToOriginM: 20)
        t.updateForecast(boardTs: 1100, arriveTs: 3000, now: 1000)
        t.tick(now: 1300)
        XCTAssertEqual(t.phase, .riding)
        XCTAssertTrue(t.needsPreciseFixes(now: 1300))
        // no forecast: the destination check can fire at any moment
        var u = TripTracker(start(legs: 1), distanceToOriginM: 20)
        u.motion(sec(1000, walking: false))
        XCTAssertTrue(u.needsPreciseFixes(now: 1001))
    }

    func testTheDestinationIsStillFoundAfterACoarseRide() {
        var r = Ride(legs: 1, arriveTs: 2000)
        r.stand(30); r.depart(); r.ride(400)
        XCTAssertFalse(r.precise)
        // the coarse fixes under the street say nothing the tracker acts on
        r.t.location(ts: r.ts, toOriginM: 3000, toDestM: 4000, now: r.ts, accuracyM: 100)
        r.ride(200)                                       // 1636: precise two minutes before the check can fire
        XCTAssertTrue(r.precise)
        r.ride(100)                                       // 1736: within five minutes of 2000
        r.t.location(ts: r.ts, toOriginM: 6000, toDestM: 120, now: r.ts, accuracyM: 10)
        XCTAssertEqual(r.t.phase, .arrived)
        XCTAssertEqual(r.t.timeline.endedBy, "arrived")
    }

    func testARouteNobodyEndedStopsAfterThreeHours() {
        // the forecast keeps sliding to the next train and the rider never boards: the late-arrival timeout never comes
        var t = TripTracker(start(), distanceToOriginM: 20)
        var now = 1000.0
        while now < 1000 + 3 * 3600 - 15 {
            t.updateForecast(boardTs: now + 300, arriveTs: now + 1500, now: now)
            t.tick(now: now)
            now += 15
        }
        XCTAssertNotEqual(t.phase, .arrived)
        t.tick(now: 1000 + 3 * 3600)
        XCTAssertEqual(t.phase, .arrived)
        XCTAssertEqual(t.timeline.endedBy, "timeout")
    }
}
