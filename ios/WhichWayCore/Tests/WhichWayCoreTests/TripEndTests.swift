import XCTest
@testable import WhichWayCore

/// Every way a ride can fail to end, from the tracker's motion, fixes and clock to the route closed (`phase == .arrived`).
///
/// Nov 9 evening: the phone kept the rider "on the train" long after the trip. The trip ends by a clock, `liveArriveTs`,
/// and the planner works that out from now whenever a connection is still to catch (the leg's next train after now, or
/// after the first leg's arrival once that has passed), so the arrival slid on with the clock and only the three-hour cap
/// could end the route. Each scenario below runs with that sliding clock: a poll every 15 s sets the arrival a fixed
/// time ahead of now, as the planner does then. Synthetic data only.
final class TripEndTests: XCTestCase {
    private struct Trip {
        var t: TripTracker
        var ts = 1000.0
        /// The planner's arrival this far ahead of now at every poll once riding (nil: it holds still at `arriveTs`).
        var slide: Double?
        var lastPoll = 0.0

        init(legs: Int = 2, arriveTs: Double = 2200, slide: Double? = 480) {
            t = TripTracker(TripTimeline(startTs: 1000, startedBy: "gps", startDistanceM: 20, placeId: nil, originStation: "S1",
                                         destStation: "S9", transferStation: legs > 1 ? "X" : nil, legs: legs), distanceToOriginM: 20)
            t.updateForecast(boardTs: 1030, arriveTs: arriveTs, now: 1000)
            self.slide = slide
        }

        private mutating func second(_ m: MotionSecond) {
            t.motion(m)
            ts += 1
            if ts - lastPoll >= 15 { poll() }
        }
        /// A planner poll: the arrival (sliding, once riding) and the clock.
        mutating func poll() {
            lastPoll = ts
            if t.phase == .riding, let s = slide { t.setLiveArrival(ts + s) }
            t.tick(now: ts)
        }
        mutating func stand(_ n: Int) { for _ in 0..<n { second(MotionSecond(ts: ts, stepEnergy: 0.002, pushG: 0.005, shakeG: 0.005)) } }
        mutating func depart() { for _ in 0..<6 { second(MotionSecond(ts: ts, stepEnergy: 0.002, pushG: 0.08, shakeG: 0.03)) } }
        /// On a moving train: rolling, with a station's braking and pull-away push every two minutes.
        mutating func ride(_ n: Int) {
            for i in 0..<n { second(MotionSecond(ts: ts, stepEnergy: 0.002, pushG: i % 120 < 4 ? 0.08 : 0.005, shakeG: 0.04)) }
        }
        mutating func walk(_ n: Int) { for _ in 0..<n { second(MotionSecond(ts: ts, stepEnergy: 0.05, pushG: 0.005, shakeG: 0.005)) } }
        /// Walking with a still second every so often (a kerb, a door): `looseWalkSecs` carries on through single gaps.
        mutating func stroll(_ n: Int) {
            for i in 0..<n { second(MotionSecond(ts: ts, stepEnergy: i % 20 == 19 ? 0.002 : 0.05, pushG: 0.005, shakeG: 0.005)) }
        }
        mutating func fix(toDestM: Double, accuracyM: Double = 30) {
            t.location(ts: ts, toOriginM: 5000, toDestM: toDestM, now: ts, accuracyM: accuracyM)
        }
        var over: Bool { t.phase == .arrived }
    }

    /// The first leg ridden and the change across the platform unseen (no steps, no stop: Oct 22 and 27 at Jay St). The phone
    /// has the rider on the first train still, and the arrival slides with the connection it waits for.
    private func onTheSecondTrainUnseen(slide: Double? = 480) -> Trip {
        var r = Trip(slide: slide)
        r.stand(30); r.depart(); r.ride(900)       // the F, then the A across the platform: one long ride to the phone
        XCTAssertTrue(r.t.onTrain)
        XCTAssertEqual(r.t.timeline.legsRidden, 0)
        return r
    }

    // MARK: - the rider gets off and the phone sees it

    func testOffAtTheDestinationWithTheChangeUnseenEndsOnTheFix() {
        var r = onTheSecondTrainUnseen()
        r.stand(15); r.walk(45)                    // off at the destination: one walk-off for a two-leg route
        XCTAssertEqual(r.t.timeline.legsRidden, 1)
        XCTAssertFalse(r.over, "a leg short, and the sliding clock never comes")
        r.fix(toDestM: 120)                        // up the stairs, at the destination
        XCTAssertTrue(r.over)
        XCTAssertEqual(r.t.timeline.endedBy, "arrived")
    }

    func testOffAtTheDestinationWithACoarseFixEndsToo() {
        var r = onTheSecondTrainUnseen()
        r.stand(15); r.walk(45)
        r.fix(toDestM: 260, accuracyM: 100)        // 260 m give or take 100: within the radius on half its uncertainty
        XCTAssertTrue(r.over)
        XCTAssertEqual(r.t.timeline.endedBy, "arrived")
    }

    func testOffWithNoFixAndAWalkHomeEndsOnTheWalk() {
        var r = onTheSecondTrainUnseen()
        r.stand(15); r.walk(45)
        XCTAssertFalse(r.over)
        r.stroll(300)
        XCTAssertFalse(r.over, "five minutes of steps after a walk-off can still be a long change")
        r.stroll(120)                              // seven minutes of steps, no stop: out of the station
        XCTAssertTrue(r.over)
        XCTAssertEqual(r.t.timeline.endedBy, "walked")
    }

    func testOffWithNoFixAndThenSittingStillEndsAfterHalfAnHour() {
        var r = onTheSecondTrainUnseen()
        r.stand(15); r.walk(45)
        let off = r.t.timeline.events.last!.ts
        r.stand(1700)
        XCTAssertFalse(r.over, "under half an hour: a slow connection")
        r.stand(200)
        XCTAssertTrue(r.over)
        XCTAssertEqual(r.t.timeline.endedBy, "stale")
        XCTAssertGreaterThanOrEqual(r.t.timeline.endedTs!, off + 1800)
    }

    // MARK: - the phone never sees the rider get off

    func testNoWalkOffFeltEndsAQuarterHourAfterTheTrainStopsMoving() {
        // the phone in a bag on a chair at the other end: no steps, no push, the clock sliding
        var r = onTheSecondTrainUnseen()
        r.stand(600)
        XCTAssertFalse(r.over, "ten minutes with no push: a held train, perhaps")
        r.stand(400)
        XCTAssertTrue(r.over)
        XCTAssertEqual(r.t.timeline.endedBy, "stale")
    }

    func testTheSlidingClockIsHeldNearTheArrivalTheRideBeganWith() {
        var r = onTheSecondTrainUnseen()
        XCTAssertEqual(r.t.arriveAnchor ?? 0, 2200, accuracy: 1)
        XCTAssertGreaterThan(r.t.timeline.liveArriveTs!, r.ts)
        XCTAssertEqual(r.t.endClockTs!, min(r.t.timeline.liveArriveTs!, 2200 + r.t.maxOverrunSec), accuracy: 0.001)
    }

    // MARK: - rides that are still going must not end

    func testAWaitForTheConnectionUnderHalfAnHourDoesNotEndAndTheNextTrainCarriesOn() {
        var r = Trip()
        r.stand(30); r.depart(); r.ride(600); r.stand(15); r.walk(45)   // off at the change, felt
        XCTAssertEqual(r.t.timeline.legsRidden, 1)
        r.stand(1500)                              // a 25-minute wait at the change, the connection's arrival sliding
        XCTAssertFalse(r.over)
        r.depart(); r.ride(600)
        XCTAssertFalse(r.over)
        XCTAssertTrue(r.t.onTrain)
        r.stand(15); r.walk(45)
        r.fix(toDestM: 80)
        XCTAssertTrue(r.over)
        XCTAssertEqual(r.t.timeline.endedBy, "arrived")
    }

    func testALongRideOnAMovingTrainWaitsPastTheCapUntilTheTrainStops() {
        // a train that runs very late (the clock past its cap) is ridden on while it is felt moving
        var r = onTheSecondTrainUnseen()
        r.ride(4000)                               // past 2200 + 2700 + 600 with pushes every two minutes
        XCTAssertFalse(r.over)
        XCTAssertTrue(r.t.onTrain)
        r.stand(1000)                              // then nothing moves
        XCTAssertTrue(r.over)
    }

    func testAMovingTrainForeverStillStopsAtThreeHours() {
        var r = onTheSecondTrainUnseen()
        while !r.over, r.ts < 1000 + 3 * 3600 + 60 { r.ride(120) }
        XCTAssertTrue(r.over)
        XCTAssertEqual(r.t.timeline.endedBy, "timeout")
        XCTAssertGreaterThanOrEqual(r.t.timeline.endedTs!, 1000 + 3 * 3600)
    }

    func testOnTheTrainUnderTheDestinationBeforeItsTimeIsNotTheEnd() {
        // a fix at the destination while still on the train, well before the arrival: the train passing (or pulling in)
        var r = Trip(legs: 1, arriveTs: 4000, slide: nil)
        r.stand(30); r.depart(); r.ride(600)
        r.fix(toDestM: 100)
        XCTAssertFalse(r.over)
        XCTAssertTrue(r.t.onTrain)
    }

    func testAStillClockEndsAsBeforeOnTheWalkOff() {
        var r = Trip(legs: 1, arriveTs: 1700, slide: nil)
        r.stand(30); r.depart(); r.ride(600); r.stand(15); r.walk(45)
        r.poll()
        XCTAssertTrue(r.over)
        XCTAssertEqual(r.t.timeline.endedBy, "alighted")
    }

    // MARK: - the rider's own word

    func testEndByHandWorksInEveryPhase() {
        var approaching = TripTracker(TripTimeline(startTs: 1000, startedBy: "gps", startDistanceM: 900, placeId: nil, originStation: "S1",
                                                   destStation: "S9", transferStation: nil, legs: 1), distanceToOriginM: 900)
        XCTAssertEqual(approaching.phase, .approaching)
        approaching.endByHand(now: 1010)
        XCTAssertEqual(approaching.phase, .arrived)
        XCTAssertEqual(approaching.timeline.endedBy, "hand")

        var atStation = Trip()
        atStation.stand(30)
        XCTAssertEqual(atStation.t.phase, .atStation)
        atStation.t.endByHand(now: atStation.ts)
        XCTAssertEqual(atStation.t.timeline.endedBy, "hand")

        var onTrain = onTheSecondTrainUnseen()
        onTrain.t.endByHand(now: onTrain.ts)
        XCTAssertTrue(onTrain.over)
        XCTAssertEqual(onTrain.t.timeline.endedBy, "hand")

        var between = Trip()
        between.stand(30); between.depart(); between.ride(600); between.stand(15); between.walk(45)
        XCTAssertFalse(between.t.onTrain)
        between.t.endByHand(now: between.ts)
        XCTAssertEqual(between.t.timeline.endedBy, "hand")

        // and once over, it stays as it ended
        var done = Trip(legs: 1, arriveTs: 1700, slide: nil)
        done.stand(30); done.depart(); done.ride(600); done.stand(15); done.walk(45); done.poll()
        done.t.endByHand(now: done.ts + 60)
        XCTAssertEqual(done.t.timeline.endedBy, "alighted")
    }

    func testNotOnTheTrainAtTheEndThenAnHourOnThePlatformCloses() {
        // "Not on the train" said after a ride whose pull-away was not one: back on the platform, and the hour's wait rule
        // closes a route nobody boards again
        var r = Trip(legs: 1, arriveTs: 1700, slide: nil)
        r.stand(30); r.depart(); r.ride(60)
        r.t.notOnTrain()
        XCTAssertEqual(r.t.phase, .atStation)
        XCTAssertNil(r.t.arriveAnchor)
        r.stand(3700)
        XCTAssertTrue(r.over)
    }
}
