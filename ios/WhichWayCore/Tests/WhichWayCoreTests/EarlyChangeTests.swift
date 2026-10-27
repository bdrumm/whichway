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
        // stepped off as the F pulled in, plus the step to the doors; never after the tap
        let jay = try XCTUnwrap(early.first)
        XCTAssertEqual(earlyChangeAlightTs(jay, train: f, now: atJay + 300), atJay + TransferTiming.stepAcrossSec)
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
}
