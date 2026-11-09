import XCTest
@testable import WhichWayCore

/// A change short of the route's own (Oct 22 and Oct 27: the F from 4 Av-9 St planned to change at W 4 St, the rider
/// stepped across the platform onto the A at Jay St). The sensors cannot see it, so the route offers it as one tap, and
/// the tap must hand the trip over: the F ride closed at Jay St, the rider on the A.
final class EarlyChangeTests: XCTestCase {
    /// The F: 4 Av (0), Jay St (1, the A's own stop: across the platform), York St (2), W 4 St (3). The A: Hoyt (0),
    /// Jay St (1), High St (2), W 4 St (3), 14 St (4). At W 4 St the change is a 3:00 walk.
    private func network() throws -> (ClientSchedule, StationIndex) {
        let json = """
        {"lines": {"F_N": {"stops": ["F23N","A41N","F18N","D20N"], "names": ["4 Av-9 St","Jay St-MetroTech","York St","W 4 St-Wash Sq"], "run_sec": [480, 90, 540]},
                   "A_N": {"stops": ["A42N","A41N","A40N","A32N","A31N"], "names": ["Hoyt-Schermerhorn Sts","Jay St-MetroTech","High St","W 4 St-Wash Sq","14 St"], "run_sec": [90, 120, 480, 120]}},
         "transfers": {"A41N": [{"line": "A_N", "stop": "A41N", "min_sec": 0}, {"line": "F_N", "stop": "A41N", "min_sec": 0}],
                       "D20N": [{"line": "A_N", "stop": "A32N", "min_sec": 180}],
                       "A32N": [{"line": "F_N", "stop": "D20N", "min_sec": 180}]}}
        """
        let sched = try JSONDecoder().decode(ClientSchedule.self, from: Data(json.utf8))
        return (sched, StationIndex(schedule: sched))
    }

    private func routes() throws -> (planned: PathOption, all: [PathOption], index: StationIndex) {
        let (sched, index) = try network()
        let all = enumeratePaths(schedule: sched, index: index, from: index.stationOf("F23N"), to: index.stationOf("A31N"), maxOptions: 24)
        let planned = try XCTUnwrap(all.first { $0.transfer?.station == "W 4 St-Wash Sq" })
        return (planned, all, index)
    }

    /// The F the phone has the rider on, its feed time at Jay St (stop 1) at `jayFeedTs`.
    private func theF(jayFeedTs: Double?) -> BoardingCandidate {
        var stopTs: [Int: Double] = [2: 2200, 3: 2700]
        if let j = jayFeedTs { stopTs[1] = j }
        return BoardingCandidate(trainId: "F_N|f1", key: "F_N", route: "F", boardTs: 1500, alightTs: 2700, stopsToAlight: 3, chosen: true, onLeg: true,
                                 boardIdx: 0, alightIdx: 3, stopTs: stopTs, progressIdx: 2)
    }

    func testTheChangeAcrossThePlatformAtJaySt() throws {
        let (planned, all, index) = try routes()
        let early = earlierChanges(from: planned, ridingKey: "F_N", among: all, index: index)
        XCTAssertEqual(early.count, 1)
        let jay = try XCTUnwrap(early.first)
        XCTAssertEqual(jay.stationName, "Jay St-MetroTech")
        XCTAssertEqual(jay.stopIdx, 1)
        XCTAssertEqual(jay.nextKeys, ["A_N"])
        XCTAssertTrue(jay.acrossPlatform)
        XCTAssertEqual(jay.text, "A at Jay St-MetroTech")
        // the route that changes at Jay St has nothing earlier to offer, and a direct ride has no change at all
        XCTAssertTrue(earlierChanges(from: jay.option, ridingKey: "F_N", among: all, index: index).isEmpty)
        XCTAssertTrue(earlierChanges(from: planned, ridingKey: "G_N", among: all, index: index).isEmpty)
    }

    func testTheOfferRunsFromPullingInToTenMinutesAfter() throws {
        let (planned, all, index) = try routes()
        let early = earlierChanges(from: planned, ridingKey: "F_N", among: all, index: index)
        let f = theF(jayFeedTs: 2000)
        let atJay = PlatformTiming.atPlatform(2000, route: "F")          // 1920: the feed records the F 80 s after it pulls in
        XCTAssertNil(earlyChangeOffer(early, train: f, now: atJay - 61), "still on the way to Jay St")
        XCTAssertEqual(earlyChangeOffer(early, train: f, now: atJay - 60)?.atTs, atJay)
        XCTAssertEqual(earlyChangeOffer(early, train: f, now: atJay + 600)?.change.stationName, "Jay St-MetroTech")
        XCTAssertNil(earlyChangeOffer(early, train: f, now: atJay + 601), "well past Jay St")
        XCTAssertNil(earlyChangeOffer(early, train: theF(jayFeedTs: nil), now: atJay), "no time for Jay St: nothing to offer")
        // stepped off as the F's doors opened, plus the step across; never after the tap
        let jay = try XCTUnwrap(early.first)
        XCTAssertEqual(earlyChangeAlightTs(jay, train: f, now: atJay + 300), atJay + PlatformTiming.doorsOpenSec + TransferTiming.stepAcrossSec)
        XCTAssertEqual(earlyChangeAlightTs(jay, train: f, now: atJay + 5), atJay + 5)
        XCTAssertEqual(earlyChangeAlightTs(jay, train: nil, now: 3000), 3000)
    }

    func testTheTapHandsTheTripToTheConnection() {
        // on the F from 1500, the change taken at Jay St (an alighting no sensor felt), then the A named: the rider is on
        // the second leg's train. Before Oct 27 a train named between trains was never boarded (the tracker counted the
        // rider on a train already), so the route sat at the change with the F's leg closed and no ride on the A.
        var t = TripTracker(TripTimeline(startTs: 1000, startedBy: "gps", startDistanceM: 40, placeId: nil, originStation: "F23", destStation: "A31",
                                         transferStation: "Jay St-MetroTech", legs: 2), distanceToOriginM: 40)
        t.beginRiding(now: 1500, departedTs: 1500)
        XCTAssertTrue(t.onTrain)
        for i in 0..<300 { t.motion(MotionSecond(ts: 1500 + Double(i), stepEnergy: 0.002, pushG: 0.03, shakeG: 0.04)) }
        t.alightStanding(at: 1935)
        XCTAssertFalse(t.onTrain)
        XCTAssertEqual(t.timeline.legsRidden, 1)
        // the A pulled away a moment before the walk-off on record: the ride starts at the walk-off, not before it
        t.beginRiding(now: 2100, departedTs: 1900)
        XCTAssertTrue(t.onTrain)
        XCTAssertEqual(t.ride(1)?.departedTs, 1935)
        XCTAssertEqual(t.timeline.events.map(\.kind), [.departed, .alighted, .departed])
        // named again on the train: no second departure
        t.beginRiding(now: 2200, departedTs: 2150)
        XCTAssertEqual(t.timeline.events.count, 3)
        t.noteChangedEarly(at: 2100)
        XCTAssertEqual(t.timeline.changedEarlyTaps, [2100])
    }

    // MARK: - the rider's own list of changes (Nov 5: never filtered by where the phone thinks the train is)

    private func riding(legs: Int, at ts: Double = 1500) -> TripTracker {
        var t = TripTracker(TripTimeline(startTs: 1000, startedBy: "gps", startDistanceM: 40, placeId: nil, originStation: "F23", destStation: "A31",
                                         transferStation: legs > 1 ? "W 4 St-Wash Sq" : nil, legs: legs), distanceToOriginM: 40)
        t.beginRiding(now: ts, departedTs: ts)
        return t
    }

    func testEveryChangeIsListedWhateverThePhoneOffers() throws {
        let (planned, all, index) = try routes()
        let listed = changesOnTheWay(from: planned, ridingKey: "F_N", among: all, index: index)
        XCTAssertEqual(listed.map(\.stationName), ["Jay St-MetroTech"], "the one change short of W 4 St")
        // with no offer (no feed time, or the train well past Jay St by the phone's reading) the list is the same
        let f = theF(jayFeedTs: nil)
        XCTAssertNil(earlyChangeOffer(earlierChanges(from: planned, ridingKey: "F_N", among: all, index: index), train: f, now: 5000))
        XCTAssertEqual(changesToName(listed, offered: nil), listed)
        // the offer orders, never removes
        let offered = try XCTUnwrap(listed.first)
        XCTAssertEqual(changesToName(listed, offered: offered), listed)
    }

    func testOfferedChangeGoesFirstAndNothingIsDropped() throws {
        let (planned, all, index) = try routes()
        let jay = try XCTUnwrap(changesOnTheWay(from: planned, ridingKey: "F_N", among: all, index: index).first)
        // a later change too: the route that changes at Jay St lists W 4 St (stayed on the F, then changed)
        let later = changesOnTheWay(from: jay.option, ridingKey: "F_N", among: all, index: index)
        XCTAssertEqual(later.map(\.stationName), ["W 4 St-Wash Sq"])
        XCTAssertFalse(later.contains(jay), "the route in hand's own change is the plan, not a change to name")
        let both = [jay] + later
        let w4 = try XCTUnwrap(later.first)
        XCTAssertEqual(changesToName(both, offered: w4).map(\.stationName), ["W 4 St-Wash Sq", "Jay St-MetroTech"])
        XCTAssertEqual(changesToName(both, offered: nil).count, 2)
        // the phone's offer never reaches beyond the planned change; the rider's list does
        XCTAssertTrue(earlierChanges(from: jay.option, ridingKey: "F_N", among: all, index: index).isEmpty)
    }

    func testANamedChangeOnTheTrainClosesTheRideAndTheNextTrainIsTheSecondLeg() {
        // changing short of the plan, at the plan's station onto another line, or past it: the same hand-off
        var t = riding(legs: 2)
        t.riderChanged(at: 1935, legs: 2, transferStation: "Jay St-MetroTech")
        XCTAssertFalse(t.onTrain)
        XCTAssertEqual(t.timeline.legsRidden, 1)
        XCTAssertEqual(t.phase, .riding, "a change, not the end of the trip")
        t.beginRiding(now: 2100, departedTs: 2000)
        XCTAssertTrue(t.onTrain)
        XCTAssertEqual(t.timeline.events.map(\.kind), [.departed, .alighted, .departed])
    }

    func testAChangeNamedOffADirectRouteDoesNotEndTheTrip() {
        // on a route with no change the one alighting would be the last: the new route's legs are counted first
        var t = riding(legs: 1)
        t.riderChanged(at: 1935, legs: 2, transferStation: "Jay St-MetroTech")
        XCTAssertEqual(t.timeline.legs, 2)
        XCTAssertEqual(t.timeline.transferStation, "Jay St-MetroTech")
        XCTAssertEqual(t.timeline.legsRidden, 1)
        XCTAssertEqual(t.phase, .riding)
        t.beginRiding(now: 2100, departedTs: 2000)
        XCTAssertTrue(t.onTrain)
    }

    func testAChangeNamedAfterTheWalkOffWasFeltAddsNoSecondAlighting() {
        // the phone felt the walk between platforms; the rider names where they changed: the leg stands as felt
        var t = riding(legs: 2)
        t.alightStanding(at: 1935)
        XCTAssertFalse(t.onTrain)
        t.riderChanged(at: 1990, legs: 2, transferStation: "Jay St-MetroTech")
        XCTAssertEqual(t.timeline.events.map(\.kind), [.departed, .alighted])
        XCTAssertEqual(t.phase, .riding)
    }

    // MARK: - "not on the train" said on the way (Nov 9: off the F at Jay St, waiting for the C, the tap sent the route back
    // to 4 Av-9 St and a G leaving there was taken for the next ride)

    /// A felt ride on the F from 4 Av-9 St: steps-free across the platform at Jay St, then waiting there, the phone none
    /// the wiser. The tracker, the time of the felt pull-away and the time now.
    private func offTheFAtJay(waitSec: Int = 120) -> (t: TripTracker, departedTs: Double, now: Double) {
        var t = TripTracker(TripTimeline(startTs: 1000, startedBy: "gps", startDistanceM: 40, placeId: nil, originStation: "F23", destStation: "A31",
                                         transferStation: "W 4 St-Wash Sq", legs: 2), distanceToOriginM: 40)
        var ts = 1000.0
        func sec(push: Double = 0.005, shake: Double = 0.005, walking: Bool = false) -> MotionSecond {
            MotionSecond(ts: ts, stepEnergy: walking ? 0.05 : 0.002, pushG: push, shakeG: shake)
        }
        for _ in 0..<30 { t.motion(sec()); ts += 1 }
        for _ in 0..<6 { t.motion(sec(push: 0.08, shake: 0.03)); ts += 1 }       // the F pulls away
        for _ in 0..<300 { t.motion(sec(shake: 0.04)); ts += 1 }                  // to Jay St
        for _ in 0..<waitSec { t.motion(sec()); ts += 1 }                         // across the platform, standing, waiting
        let dep = t.ride(0)?.departedTs ?? 0
        return (t, dep, ts)
    }

    func testNotOnTrainOnceTheTrainHasReachedJayStIsTheChangeThere() throws {
        let (planned, all, index) = try routes()
        let changes = changesOnTheWay(from: planned, ridingKey: "F_N", among: all, index: index)
        var (t, dep, now) = offTheFAtJay()
        XCTAssertTrue(t.onTrain, "the phone has the rider on the F still")
        // the F reached Jay St (feed 1400, at the platform 80 s before) between the pull-away and now
        let f = theF(jayFeedTs: 1400)
        let reading = readNotOnTrain(train: f, departedTs: dep, changes: changes, now: now)
        guard case let .changed(ch, at) = reading else { return XCTFail("\(reading)") }
        XCTAssertEqual(ch.stationName, "Jay St-MetroTech")
        XCTAssertEqual(at, PlatformTiming.doorsOpen(1400, route: "F") + TransferTiming.stepAcrossSec)
        // the hand-off as the recorder makes it (`takeChange`): the F closed at Jay St, the rider between trains
        var back = t
        t.riderChanged(at: min(at, now), legs: ch.option.legs.count, transferStation: ch.stationName)
        XCTAssertFalse(t.onTrain)
        XCTAssertEqual(t.timeline.legsRidden, 1)
        XCTAssertEqual(t.phase, .riding)
        // the planner then switches to the route changing there (`followEarlyChange` → `replan`)
        t.replan(legs: ch.option.legs.count, transferStation: ch.stationName)
        XCTAssertEqual(t.timeline.transferStation, "Jay St-MetroTech")
        // the next pull-away felt is the C, the second leg; its walk-off ends the trip
        var ts = now
        for _ in 0..<60 { t.motion(MotionSecond(ts: ts, stepEnergy: 0.002, pushG: 0.005, shakeG: 0.005)); ts += 1 }
        for _ in 0..<6 { t.motion(MotionSecond(ts: ts, stepEnergy: 0.002, pushG: 0.08, shakeG: 0.03)); ts += 1 }
        XCTAssertTrue(t.onTrain)
        XCTAssertEqual(t.timeline.events.map(\.kind), [.departed, .alighted, .departed])
        for _ in 0..<600 { t.motion(MotionSecond(ts: ts, stepEnergy: 0.002, pushG: 0.005, shakeG: 0.04)); ts += 1 }
        for _ in 0..<15 { t.motion(MotionSecond(ts: ts, stepEnergy: 0.002, pushG: 0.005, shakeG: 0.005)); ts += 1 }
        for _ in 0..<20 { t.motion(MotionSecond(ts: ts, stepEnergy: 0.05, pushG: 0.005, shakeG: 0.005)); ts += 1 }
        t.tick(now: ts)
        XCTAssertEqual(t.phase, .arrived)
        // what the tap did before: the F withdrawn, the rider back at the 4 Av-9 St platform with no leg ridden
        back.notOnTrain()
        XCTAssertEqual(back.phase, .atStation)
        XCTAssertEqual(back.timeline.legsRidden, 0)
    }

    func testNotOnTrainPastThePlannedChangeIsTheWalkOffThere() throws {
        let (planned, all, index) = try routes()
        let changes = changesOnTheWay(from: planned, ridingKey: "F_N", among: all, index: index)
        let (_, dep, _) = offTheFAtJay()
        // the F has reached W 4 St (stop 3, feed 2700) too: off at the route's own change, ahead of the earlier one
        let f = theF(jayFeedTs: 1400)
        let reading = readNotOnTrain(train: f, departedTs: dep, changes: changes, now: 2800)
        XCTAssertEqual(reading, .alighted(at: PlatformTiming.atPlatform(2700, route: "F")))
    }

    func testNotOnTrainBeforeAnyChangeIsAPullAwayThatWasNotATrain() throws {
        let (planned, all, index) = try routes()
        let changes = changesOnTheWay(from: planned, ridingKey: "F_N", among: all, index: index)
        let (_, dep, _) = offTheFAtJay()
        // tapped while the F the phone named is still short of Jay St: the rider never boarded it
        let early = PlatformTiming.atPlatform(1400, route: "F") - 1
        XCTAssertEqual(readNotOnTrain(train: theF(jayFeedTs: 1400), departedTs: dep, changes: changes, now: early), .backToPlatform)
        // no time for Jay St in the feed, no train in hand, or no pull-away on record: the same
        XCTAssertEqual(readNotOnTrain(train: theF(jayFeedTs: nil), departedTs: dep, changes: changes, now: 2000), .backToPlatform)
        XCTAssertEqual(readNotOnTrain(train: nil, departedTs: dep, changes: changes, now: 2000), .backToPlatform)
        XCTAssertEqual(readNotOnTrain(train: theF(jayFeedTs: 1400), departedTs: nil, changes: changes, now: 2000), .backToPlatform)
        // a Jay St time from before the pull-away is another run, not this ride's
        XCTAssertEqual(readNotOnTrain(train: theF(jayFeedTs: 1400), departedTs: 1400, changes: changes, now: 2000), .backToPlatform)
    }

    func testNotOnTrainCountsOnlyTheChangesOffTheLineInHand() throws {
        let (planned, all, index) = try routes()
        let changes = changesOnTheWay(from: planned, ridingKey: "F_N", among: all, index: index)
        let (_, dep, _) = offTheFAtJay()
        // a train of another line with a time at its own stop 1: that stop is not Jay St on the F
        var g = theF(jayFeedTs: 1400)
        g.key = "G_N"; g.route = "G"; g.trainId = "G_N|g1"
        XCTAssertEqual(readNotOnTrain(train: g, departedTs: dep, changes: changes, now: 2000), .backToPlatform)
    }
}
