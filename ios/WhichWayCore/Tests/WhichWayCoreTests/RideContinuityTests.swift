import XCTest
@testable import WhichWayCore

/// Whether the rider is still on the train the phone has them on, once it has gone past the stop the route leaves it
/// at, and where "not on a train" puts them. One test per way a rider makes (or does not make) the change: a step
/// across the platform, a train already standing there, staying on past the change, the feed's time running early,
/// a platform that shakes, the rider's own word mid-ride, and a pull-away that was never a train.
final class RideContinuityTests: XCTestCase {
    private let rc = RideContinuity()
    private func start(legs: Int = 2) -> TripTimeline {
        TripTimeline(startTs: 1000, startedBy: "hand", originStation: "F23", destStation: "A31", transferStation: "Jay St", legs: legs)
    }
    private func sec(_ ts: Double, push: Double = 0.005, shake: Double = 0.005, walking: Bool = false) -> MotionSecond {
        MotionSecond(ts: ts, stepEnergy: walking ? 0.05 : 0.002, pushG: push, shakeG: shake)
    }
    /// The F from stop 0: Jay St is stop 4 (the route's change), York St 5, East Broadway 6, by the feed's own times.
    private func fTrain(alightIdx: Int? = 4) -> BoardingCandidate {
        let lag = PlatformTiming.recordedLag(route: "F")
        return BoardingCandidate(trainId: "F_N|f1", key: "F_N", route: "F", boardTs: 1000 + lag, alightTs: alightIdx.map { _ in 1480 + lag },
                                 stopsToAlight: alightIdx, chosen: true, onLeg: true, boardIdx: 0, alightIdx: alightIdx,
                                 stopTs: [1: 1120 + lag, 2: 1240 + lag, 3: 1360 + lag, 4: 1480 + lag, 5: 1640 + lag, 6: 1800 + lag], progressIdx: 6)
    }
    /// A tracker riding from 1040: a pull-away push, then a push away from and into each stop as the train runs on to
    /// `rideUntil`, then standing on a platform that shakes (trains passing) but never pushes, to `until`.
    private func ridden(until: Double, rideUntil: Double = 1480) -> TripTracker {
        var t = TripTracker(start(), distanceToOriginM: 0)
        var ts = 1020.0
        while ts < until {
            let riding = ts >= 1040 && ts < rideUntil
            // five seconds of push every sixty while the train runs: pulling away, braking
            let pushing = riding && Int(ts - 1040) % 60 < 5
            t.motion(sec(ts, push: pushing ? 0.08 : 0.01, shake: 0.035))
            ts += 1
        }
        return t
    }

    func testThePushesOfARideAreKeptAndAShakingPlatformAddsNone() {
        let t = ridden(until: 1700)
        XCTAssertTrue(t.onTrain, "no walk-off was felt: the tracker still has the rider riding")
        XCTAssertGreaterThanOrEqual(t.pushRuns.count, 7)
        XCTAssertLessThan(t.pushRuns.last ?? 0, 1480, "three and a half minutes on a shaking platform: not one push")
        XCTAssertGreaterThan(t.lastMovingTs ?? 0, 1690, "the shaking alone would have read as riding on (the old rule)")
    }

    // MARK: past the stop the route leaves the train at

    func testAStepAcrossThePlatformIsReadAsGettingOffAsPlanned() {
        // off the F at Jay St at 1480, standing on the platform; the F reaches York St at 1640
        let t = ridden(until: 1700)
        XCTAssertEqual(rc.pastStop(atStopTs: 1480, laterStopTs: [1640, 1800], pushTimes: t.pushRuns, now: 1630), .waiting, "the F is not at York St yet")
        XCTAssertEqual(rc.pastStop(atStopTs: 1480, laterStopTs: [1640, 1800], pushTimes: t.pushRuns, now: 1665), .steppedOff(at: 1480))
        // the hand-off: the ride closes at the train's moment at Jay St and the rider is between trains on the next leg
        var tr = t
        tr.alightStanding(at: 1480)
        XCTAssertEqual(tr.timeline.legsRidden, 1)
        XCTAssertFalse(tr.onTrain)
        XCTAssertEqual(tr.phase, .riding)
        // and the connection's pull-away is the next ride
        for i in 0..<5 { tr.motion(sec(1720 + Double(i), push: 0.09, shake: 0.04)) }
        XCTAssertTrue(tr.onTrain)
        XCTAssertEqual(tr.ride(1)?.departedTs, 1720)
    }

    func testATrainStandingAcrossThePlatformIsTheConnectionNotAStayOnTheFirstTrain() {
        // no steps at all: off the F and onto the A standing there, which pulls away at 1525 (the F at about 1520)
        var t = ridden(until: 1500)
        var ts = 1500.0
        while ts < 1700 { t.motion(sec(ts, push: (ts >= 1525 && ts < 1531) || (ts >= 1600 && ts < 1605) ? 0.08 : 0.01, shake: 0.035)); ts += 1 }
        let v = rc.pastStop(atStopTs: 1480, laterStopTs: [1640], pushTimes: t.pushRuns, connectionPullAways: [1300, 1530], now: 1665)
        XCTAssertEqual(v, .tookConnection(offAt: 1480, pullAwayTs: 1525), "the route's own connection explains the pushes: the plan stands")
        // the hand-off: off at Jay St, and on the next leg's train from its pull-away
        t.alightStanding(at: 1480)
        t.beginRiding(now: 1665, departedTs: 1525)
        XCTAssertEqual(t.timeline.legsRidden, 1)
        XCTAssertTrue(t.onTrain)
        XCTAssertEqual(t.ride(1)?.departedTs, 1525)
    }

    func testStayingOnNeedsTheTrainFeltRunningOn() {
        // the rider rides on past Jay St: the F pulls away at 1520 and brakes into York St at 1630, and no A leaves then
        let t = ridden(until: 1700, rideUntil: 1700)
        XCTAssertEqual(rc.pastStop(atStopTs: 1480, laterStopTs: [1640, 1800], pushTimes: t.pushRuns, connectionPullAways: [1300, 1900], now: 1665), .stayedOn)
        XCTAssertTrue(t.onTrain, "nothing is closed: the planner re-routes along the line")
    }

    func testOnePushWaitsForAnotherStopAndThenThePlanStands() {
        // the feed's time for Jay St ran early and the braking into it fell inside the window: one push, then none
        let pushes = [1100.0, 1220, 1340, 1500]
        XCTAssertEqual(rc.pastStop(atStopTs: 1480, laterStopTs: [1640, 1800], pushTimes: pushes, now: 1665), .waiting)
        XCTAssertEqual(rc.pastStop(atStopTs: 1480, laterStopTs: [1640, 1800], pushTimes: pushes, now: 1825), .steppedOff(at: 1480))
        // the same one push, then the train felt running on to the stop after: stayed on
        XCTAssertEqual(rc.pastStop(atStopTs: 1480, laterStopTs: [1640, 1800], pushTimes: pushes + [1680, 1790], now: 1825), .stayedOn)
    }

    func testGettingOffAtTheDestinationUnfeltClosesTheLastLeg() {
        // the last leg: the train runs on past the destination and the phone stands still: the trip is over there
        var t = TripTracker(start(legs: 1), distanceToOriginM: 0)
        var ts = 1020.0
        while ts < 1700 { t.motion(sec(ts, push: ts >= 1040 && ts < 1480 && Int(ts - 1040) % 60 < 5 ? 0.08 : 0.01, shake: 0.035)); ts += 1 }
        guard case let .steppedOff(at) = rc.pastStop(atStopTs: 1480, laterStopTs: [1640], pushTimes: t.pushRuns, now: 1665) else { return XCTFail() }
        t.alightStanding(at: at)
        t.tick(now: 1666)
        XCTAssertEqual(t.phase, .arrived)
        XCTAssertEqual(t.timeline.endedBy, "alighted")
    }

    // MARK: "not on a train", by hand

    func testNotOnATrainMidRidePutsTheRiderAtTheStopThePushesEndedAtNotBackAtTheStart() {
        // Nov 9: the route had moved on to W 4 St (no planned stop reached), the rider off at Jay St since 1480, the tap at 1730
        let t = ridden(until: 1730)
        let off = rc.stopLeftAt(fTrain(alightIdx: nil), departedTs: 1040, pushTimes: t.pushRuns, now: 1730)
        XCTAssertEqual(off?.idx, 4, "Jay St, where the pushes ended; not York St, which the train has reached since")
        XCTAssertEqual(off?.ts, 1480)
        var tr = t
        tr.alightStanding(at: 1480)
        XCTAssertEqual(tr.timeline.legsRidden, 1, "the leg is ridden: the trains at the boarding platform are not asked again")
        XCTAssertEqual(tr.phase, .riding)
        XCTAssertFalse(tr.onTrain)
    }

    func testNotOnATrainAfterAPullAwayThatWasNoTrainStartsTheLegOver() {
        // a pull-away felt on the platform (another track's train), then standing there while the plan's train runs on
        var t = TripTracker(start(), distanceToOriginM: 0)
        var ts = 1020.0
        while ts < 1400 { t.motion(sec(ts, push: ts >= 1040 && ts < 1044 ? 0.08 : 0.01, shake: 0.035)); ts += 1 }
        XCTAssertNil(rc.stopLeftAt(fTrain(), departedTs: 1040, pushTimes: t.pushRuns, now: 1400), "no ride was felt: back to the platform, as before")
        t.notOnTrain()
        XCTAssertEqual(t.phase, .atStation)
        XCTAssertEqual(t.timeline.legsRidden, 0)
        // two stray pushes on a platform are not a ride either
        XCTAssertNil(rc.stopLeftAt(fTrain(), departedTs: 1040, pushTimes: [1040, 1150, 1290], now: 1400))
    }

    func testNotOnATrainBeforeTheTrainReachesAnyStopStartsTheLegOver() {
        XCTAssertNil(rc.stopLeftAt(fTrain(), departedTs: 1040, pushTimes: [1040, 1060, 1075, 1090], now: 1100))
    }

    func testAConnectionsPullAwaysComeFromTheLegsOwnPlatform() {
        var log = DepartureLog()
        func train(_ id: String, key: String, at ts: Double, next: Int) -> LiveTrain {
            LiveTrain(key: key, tripId: id, trainId: nil, route: String(key.split(separator: "_")[0]), points: [TrainPoint(idx: 2, ts: ts), TrainPoint(idx: 3, ts: ts + 120)],
                      nextIdx: 2, nextName: "", etaTs: ts, schedTs: nil, schedMethod: nil, latenessSec: nil, effectiveLatenessSec: nil, position: nil,
                      corroboration: "", trackChanged: false, started: true, segment: nil, lastRun: nil)
        }
        log.observe(trains: [train("a1", key: "A_N", at: 1500, next: 2)], key: "A_N", boardIdx: 2, span: (2, 5), onLeg: true, now: 1400)
        XCTAssertTrue(log.pullAways().isEmpty, "still to come")
        var gone = train("a1", key: "A_N", at: 1500, next: 3); gone.nextIdx = 3; gone.points = [TrainPoint(idx: 3, ts: 1620)]
        log.observe(trains: [gone], key: "A_N", boardIdx: 2, span: (2, 5), onLeg: true, now: 1560)
        XCTAssertEqual(log.pullAways(), [PlatformTiming.pullsAway(1500, route: "A")])
    }
}
