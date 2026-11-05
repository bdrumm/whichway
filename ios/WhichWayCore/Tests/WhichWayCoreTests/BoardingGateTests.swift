import XCTest
@testable import WhichWayCore

/// No single sensor reading puts the rider on a train (Oct 28 at 4 Av-9 St and Jay St, Nov 2 and Nov 5 at 4 Av-9 St: a
/// train on another track shook the platform three to five minutes before the rider's F, the phone showed them on the F,
/// and their "Not on the train" tap got there before the feed's check). Every way a rider boards, from the tracker's
/// felt pull-away and the feed's trains at the platform to the leg in hand and what the rider is shown.
final class BoardingGateTests: XCTestCase {
    private func start(legs: Int = 1, transfer: String? = nil) -> TripTimeline {
        TripTimeline(startTs: 1000, startedBy: "hand", startDistanceM: 900, placeId: "home", originStation: "S1", destStation: "S9",
                     transferStation: transfer, legs: legs)
    }
    private func train(_ id: String, key: String, points: [(Int, Double)], standingAt idx: Int? = nil) -> LiveTrain {
        let pos = idx.map { TrainPosition(status: "STOPPED_AT", stopId: "s\($0)", stopIdx: $0, stopName: "", sinceSec: 10, holding: false, stalled: false, atTerminal: false) }
        return LiveTrain(key: key, tripId: id, trainId: nil, route: String(key.split(separator: "_")[0]), points: points.map { TrainPoint(idx: $0.0, ts: $0.1) },
                         nextIdx: points.first?.0 ?? 0, nextName: "", etaTs: points.first?.1 ?? 0, schedTs: nil, schedMethod: nil, latenessSec: nil,
                         effectiveLatenessSec: nil, position: pos, corroboration: "", trackChanged: false, started: true, segment: nil, lastRun: nil)
    }

    /// The rider's motion, second by second, from `ts`.
    private struct Rider {
        var t: TripTracker
        var ts: Double
        mutating func stand(_ n: Int) { for _ in 0..<n { t.motion(MotionSecond(ts: ts, stepEnergy: 0.002, pushG: 0.005, shakeG: 0.005)); ts += 1 } }
        mutating func walk(_ n: Int) { for _ in 0..<n { t.motion(MotionSecond(ts: ts, stepEnergy: 0.05, pushG: 0.005, shakeG: 0.005)); ts += 1 } }
        mutating func pullAway() { for _ in 0..<6 { t.motion(MotionSecond(ts: ts, stepEnergy: 0.002, pushG: 0.08, shakeG: 0.03)); ts += 1 } }
        mutating func ride(_ n: Int) { for _ in 0..<n { t.motion(MotionSecond(ts: ts, stepEnergy: 0.002, pushG: 0.005, shakeG: 0.04)); ts += 1 } }
        var feltTs: Double { t.timeline.events.last(where: { $0.kind == .departed })?.ts ?? .nan }
    }

    // MARK: - the feed's word on one pull-away

    func testAPullAwayMinutesBeforeTheTrainReachesThePlatformIsNoTrains() {
        // the F's feed time at the platform (idx 4) is 260 s after the shake: it reaches the platform at ~200
        var log = DepartureLog()
        log.observe(trains: [train("f1", key: "F_N", points: [(3, 140), (4, 260)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: -10)
        XCTAssertEqual(log.judgePullAway(at: 0, now: 0), .noTrain)
        // with the feed quiet for minutes there is nothing to check it against: the sensors stand alone
        XCTAssertEqual(log.judgePullAway(at: 0, now: 300), .unchecked)
        XCTAssertEqual(DepartureLog().judgePullAway(at: 0, now: 0), .unchecked, "no feed at the platform at all")
        // a train on another platform of the station is not one the rider could be on, and does not keep the claim open
        log.observe(trains: [train("r1", key: "R_N", points: [(4, 20), (5, 140)])], key: "R_N", boardIdx: 4, span: nil, onLeg: false, now: -10, samePlatform: false)
        XCTAssertEqual(log.judgePullAway(at: 0, now: 0), .noTrain)
    }

    func testATrainDueAboutThenLeavesTheClaimOpenUntilTheFeedSeesItGo() {
        var log = DepartureLog()
        log.observe(trains: [train("f1", key: "F_N", points: [(4, 60), (5, 180)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: -10)
        log.observe(trains: [train("f2", key: "F_N", points: [(4, 600), (5, 720)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: -10)
        XCTAssertEqual(log.judgePullAway(at: 0, now: 0), .pending, "the F was about due: the feed lags the platform")
        log.observe(trains: [train("f1", key: "F_N", points: [(5, 150), (6, 270)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: 80)
        log.observe(trains: [train("f2", key: "F_N", points: [(4, 600), (5, 720)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: 80)
        XCTAssertEqual(log.judgePullAway(at: 0, now: 80), .backed)
    }

    func testATrainStandingAtThePlatformBacksThePullAwayAtOnce() {
        var log = DepartureLog()
        log.observe(trains: [train("a1", key: "A_N", points: [(4, -40), (5, 100)], standingAt: 4)], key: "A_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: -20)
        log.observe(trains: [train("a2", key: "A_N", points: [(4, 500)])], key: "A_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: -20)
        XCTAssertEqual(log.judgePullAway(at: 0, now: 0), .backed)
    }

    func testATrainHeldPastItsPostedTimeKeepsTheClaimOpen() {
        // the F's posted time at the platform was four minutes ago and the feed still lists the stop: held there
        var log = DepartureLog()
        log.observe(trains: [train("f1", key: "F_N", points: [(4, -240), (5, -120)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: -30)
        log.observe(trains: [train("f2", key: "F_N", points: [(4, 500)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: -30)
        XCTAssertEqual(log.judgePullAway(at: 0, now: 0), .pending)
    }

    /// Nov 5 at 4 Av-9 St: the G left the rider's own platform minutes before their F. Another line's train
    /// leaving backs nothing: the claim waits for the rider's word or the ride's own evidence.
    func testAnotherLinesTrainLeavingThePlatformDoesNotBackThePullAway() {
        var log = DepartureLog()
        log.observe(trains: [train("g1", key: "G_N", points: [(4, -40), (5, 100)], standingAt: 4)], key: "G_N", boardIdx: 4, span: nil, onLeg: false, now: -20)
        log.observe(trains: [train("f1", key: "F_N", points: [(4, 240), (5, 360)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: -20)
        XCTAssertEqual(log.judgePullAway(at: 0, now: 0), .pending, "the G stood there: maybe the rider's train, maybe what shook them")
        log.observe(trains: [train("g1", key: "G_N", points: [(5, 90), (6, 210)])], key: "G_N", boardIdx: 4, span: nil, onLeg: false, now: 90)
        log.observe(trains: [train("f1", key: "F_N", points: [(4, 240), (5, 360)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: 90)
        XCTAssertTrue(log.departureCheck(at: 0).left, "the G did leave then")
        XCTAssertEqual(log.judgePullAway(at: 0, now: 90), .pending, "still not the plan's line")
        // the F standing there just before is the plan's own: backed
        var f = DepartureLog()
        f.observe(trains: [train("f1", key: "F_N", points: [(4, -40), (5, 100)], standingAt: 4)], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: -20)
        f.observe(trains: [train("g1", key: "G_N", points: [(4, 300)])], key: "G_N", boardIdx: 4, span: nil, onLeg: false, now: -20)
        XCTAssertEqual(f.judgePullAway(at: 0, now: 0), .backed)
    }

    // MARK: - every way of boarding, end to end

    /// Nov 5: on the platform at 4 Av-9 St, a train on another track shakes it; the F is three minutes off. The rider is
    /// never shown on a train, stays at the station, and the F's own pull-away is the ride.
    func testAShakeBeforeTheTrainArrivesNeverShowsTheRiderOnATrain() {
        var r = Rider(t: TripTracker(start(), distanceToOriginM: 20), ts: 1000)
        r.t.updateForecast(boardTs: 1250, arriveTs: 2000, now: 1000)
        r.stand(40); r.pullAway()
        XCTAssertTrue(r.t.onTrain, "the tracker felt it")
        var log = DepartureLog()
        log.observe(trains: [train("f1", key: "F_N", points: [(4, r.feltTs + 230)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: r.ts)
        XCTAssertTrue(r.t.applyPullAwayVerdict(log.judgePullAway(at: r.feltTs, now: r.ts)))
        XCTAssertFalse(r.t.onTrainShown)
        XCTAssertFalse(r.t.onTrain)
        XCTAssertEqual(r.t.phase, .atStation)
        XCTAssertEqual(r.t.timeline.legsRidden, 0)
        XCTAssertEqual(r.t.timeline.withdrawnDepartures?.count, 1)
        // the F pulls in, stands, and leaves with the rider
        r.stand(150)
        log.observe(trains: [train("f1", key: "F_N", points: [(4, r.ts + 40), (5, r.ts + 160)], standingAt: 4)], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: r.ts)
        r.stand(30); r.pullAway()
        XCTAssertFalse(r.t.applyPullAwayVerdict(log.judgePullAway(at: r.feltTs, now: r.ts)))
        XCTAssertTrue(r.t.onTrainShown)
        XCTAssertEqual(r.t.timeline.events.filter { $0.kind == .departed }.count, 1)
    }

    /// The train reached the platform about when the push was felt, but the feed has not shown it leave: the rider is
    /// shown boarding, not riding, until it does.
    func testAPullAwayTheFeedCannotSayYetShowsAsBoarding() {
        var r = Rider(t: TripTracker(start(), distanceToOriginM: 20), ts: 1000)
        r.t.updateForecast(boardTs: 1050, arriveTs: 2000, now: 1000)
        r.stand(40); r.pullAway()
        var log = DepartureLog()
        log.observe(trains: [train("f1", key: "F_N", points: [(4, r.feltTs + 60), (5, r.feltTs + 180)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: r.feltTs - 5)
        XCTAssertFalse(r.t.applyPullAwayVerdict(log.judgePullAway(at: r.feltTs, now: r.ts)))
        XCTAssertTrue(r.t.boardingPending)
        XCTAssertTrue(r.t.onTrain, "the sensors keep watching the ride")
        XCTAssertFalse(r.t.onTrainShown, "but the rider is shown boarding")
        r.ride(80)
        log.observe(trains: [train("f1", key: "F_N", points: [(5, r.feltTs + 150), (6, r.feltTs + 270)])], key: "F_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: r.ts)
        XCTAssertFalse(r.t.applyPullAwayVerdict(log.judgePullAway(at: r.feltTs, now: r.ts)))
        XCTAssertTrue(r.t.onTrainShown)
    }

    /// Stepping onto a train already standing there (no walk, the push is the first sign): backed at once.
    func testBoardingAStandingTrainIsShownAtOnce() {
        var r = Rider(t: TripTracker(start(), distanceToOriginM: 20), ts: 1000)
        r.stand(40)
        var log = DepartureLog()
        log.observe(trains: [train("g1", key: "G_N", points: [(4, r.ts - 30), (5, r.ts + 120)], standingAt: 4)], key: "G_N", boardIdx: 4, span: (from: 4, to: 9), onLeg: true, now: r.ts)
        r.stand(20); r.pullAway()
        XCTAssertFalse(r.t.applyPullAwayVerdict(log.judgePullAway(at: r.feltTs, now: r.ts)))
        XCTAssertTrue(r.t.onTrainShown)
    }

    /// At the change: off the first train, a walk to the other platform, and a shake there before the connection is in.
    /// The rider stays between trains at the change, with the first leg ridden, and the connection's pull-away is the
    /// second leg.
    func testAShakeAtTheChangeKeepsTheRiderBetweenTrains() {
        var r = Rider(t: TripTracker(start(legs: 2, transfer: "W 4 St"), distanceToOriginM: 20), ts: 1000)
        r.t.updateForecast(boardTs: 1030, arriveTs: 3000, now: 1000)
        r.stand(30); r.pullAway(); r.t.backBoarding(); r.ride(300); r.stand(15); r.walk(60); r.stand(20); r.pullAway()
        XCTAssertEqual(r.t.timeline.legsRidden, 1)
        var log = DepartureLog()
        log.observe(trains: [train("a1", key: "A_S", points: [(7, r.feltTs + 300)])], key: "A_S", boardIdx: 7, span: (from: 7, to: 9), onLeg: true, now: r.ts)
        XCTAssertTrue(r.t.applyPullAwayVerdict(log.judgePullAway(at: r.feltTs, now: r.ts)))
        XCTAssertEqual(r.t.phase, .riding, "between trains at the change")
        XCTAssertFalse(r.t.onTrain)
        XCTAssertEqual(r.t.timeline.legsRidden, 1)
        r.stand(260)
        log.observe(trains: [train("a1", key: "A_S", points: [(7, r.ts - 20), (8, r.ts + 120)], standingAt: 7)], key: "A_S", boardIdx: 7, span: (from: 7, to: 9), onLeg: true, now: r.ts)
        r.stand(10); r.pullAway()
        XCTAssertFalse(r.t.applyPullAwayVerdict(log.judgePullAway(at: r.feltTs, now: r.ts)))
        XCTAssertTrue(r.t.onTrainShown)
        XCTAssertEqual(r.t.timeline.events.filter { $0.kind == .departed }.count, 2)
    }

    /// Steps across the platform onto a train standing at the change (Oct 27 at Jay St, no walk at all): backed by the
    /// train standing there, so the second leg shows at once.
    func testAStepAcrossOntoAStandingTrainAtTheChangeIsShownAtOnce() {
        var r = Rider(t: TripTracker(start(legs: 2, transfer: "Jay St"), distanceToOriginM: 20), ts: 1000)
        r.t.updateForecast(boardTs: 1030, arriveTs: 3000, now: 1000)
        r.stand(30); r.pullAway(); r.t.backBoarding(); r.ride(300); r.stand(15); r.walk(8); r.stand(20)
        var log = DepartureLog()
        log.observe(trains: [train("a1", key: "A_N", points: [(1, r.ts - 30), (2, r.ts + 100)], standingAt: 1)], key: "A_N", boardIdx: 1, span: (from: 1, to: 4), onLeg: true, now: r.ts)
        r.pullAway()
        XCTAssertEqual(r.t.timeline.legsRidden, 1)
        XCTAssertFalse(r.t.applyPullAwayVerdict(log.judgePullAway(at: r.feltTs, now: r.ts)))
        XCTAssertTrue(r.t.onTrainShown)
    }

    /// No signal on the platform: nothing to check the pull-away against, so it stands as felt (the rider can still say
    /// "Not on the train").
    func testAPullAwayWithNoFeedAtThePlatformStandsAsFelt() {
        var r = Rider(t: TripTracker(start(), distanceToOriginM: 20), ts: 1000)
        r.stand(40); r.pullAway()
        XCTAssertFalse(r.t.applyPullAwayVerdict(DepartureLog().judgePullAway(at: r.feltTs, now: r.ts)))
        XCTAssertTrue(r.t.onTrainShown)
    }

    // MARK: - the rider's word settles it

    /// "On it" while boarding: shown riding at once, whatever the feed has not yet said.
    func testOnItShowsTheRideAtOnce() {
        var r = Rider(t: TripTracker(start(), distanceToOriginM: 20), ts: 1000)
        r.stand(40); r.pullAway()
        XCTAssertFalse(r.t.applyPullAwayVerdict(.pending))
        XCTAssertFalse(r.t.onTrainShown)
        r.t.backBoarding()
        XCTAssertTrue(r.t.onTrainShown)
    }

    /// "Not on the train" while boarding: back on the platform, the claim gone.
    func testNotOnTheTrainWhileBoardingIsBackOnThePlatform() {
        var r = Rider(t: TripTracker(start(), distanceToOriginM: 20), ts: 1000)
        r.stand(40); r.pullAway()
        r.t.applyPullAwayVerdict(.pending)
        r.t.notOnTrain()
        XCTAssertFalse(r.t.boardingPending)
        XCTAssertFalse(r.t.onTrain)
        XCTAssertEqual(r.t.phase, .atStation)
    }

    /// A train named by hand while boarding (the sheet, or the boarding prompt): the rider's word is the ride.
    func testATrainNamedByHandWhileBoardingIsTheRide() {
        var r = Rider(t: TripTracker(start(), distanceToOriginM: 20), ts: 1000)
        r.stand(40); r.pullAway()
        r.t.applyPullAwayVerdict(.pending)
        r.t.beginRiding(now: r.ts, departedTs: r.ts - 10)
        XCTAssertTrue(r.t.onTrainShown)
        XCTAssertEqual(r.t.timeline.events.filter { $0.kind == .departed }.count, 1, "the felt pull-away stands, not a second ride")
    }

    /// A ride long enough to walk off at the end was a ride: the alighting settles it.
    func testAWalkOffAfterAFullRideSettlesThePullAway() {
        var r = Rider(t: TripTracker(start(legs: 2, transfer: "X"), distanceToOriginM: 20), ts: 1000)
        r.stand(30); r.pullAway()
        r.t.applyPullAwayVerdict(.pending)
        r.ride(300); r.stand(15); r.walk(30)
        XCTAssertEqual(r.t.timeline.legsRidden, 1)
        XCTAssertFalse(r.t.boardingPending)
    }
}
