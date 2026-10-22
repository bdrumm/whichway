import XCTest
@testable import WhichWayCore

/// The itinerary of a ride in progress, from the train the phone believes the rider boarded: its own arrival at the
/// leg's last stop and the connection it makes, for the clock the trip ends by.
final class RidingItineraryTests: XCTestCase {
    /// The itinerary's times are moments at the platform: the feed's times less each line's lag.
    private let lagG = PlatformTiming.recordedLag(route: "G"), lagC = PlatformTiming.recordedLag(route: "C")

    private func schedule() throws -> ClientSchedule {
        let json = """
        {"lines": {"G_N": {"stops": ["g0","g1","g2","g3"], "names": ["a","b","Hoyt","d"], "run_sec": [120, 120, 120]},
                   "C_N": {"stops": ["c0","c1","c2","c3"], "names": ["x","Hoyt","y","14 St"], "run_sec": [150, 150, 150]}}}
        """
        return try JSONDecoder().decode(ClientSchedule.self, from: Data(json.utf8))
    }
    private func train(_ id: String, key: String, points: [(Int, Double)]) -> LiveTrain {
        LiveTrain(key: key, tripId: id, trainId: nil, route: String(key.split(separator: "_")[0]), points: points.map { TrainPoint(idx: $0.0, ts: $0.1) },
                  nextIdx: points.first?.0 ?? 0, nextName: "", etaTs: points.first?.1 ?? 0, schedTs: nil, schedMethod: nil, latenessSec: nil,
                  effectiveLatenessSec: nil, position: nil, corroboration: "", trackChanged: false, started: true, segment: nil, lastRun: nil)
    }
    private func board(_ key: String, _ trains: [LiveTrain]) -> LineBoard {
        LineBoard(key: key, route: String(key.split(separator: "_")[0]), direction: "N", now: 0, trains: trains, nHolding: 0, nStalled: 0, nFeedOptimistic: 0)
    }
    /// The G from g0 to Hoyt (idx 2), a 120 s walk, the C from Hoyt (idx 1) to 14 St (idx 3).
    private var option: PathOption {
        var p = PathOption(id: "G>C", legs: [PathLeg(from: "g0", to: "g2", keys: ["G_N"], routes: ["G"], idx: ["G_N": (0, 2)], schedRideSec: 240, nStops: 2),
                                            PathLeg(from: "c1", to: "c3", keys: ["C_N"], routes: ["C"], idx: ["C_N": (1, 3)], schedRideSec: 300, nStops: 2)],
                           transfer: PathTransfer(stop: "g2", stop2: "c1", station: "Hoyt", walkSec: 120))
        p.schedSec = 240 + 120 + 300
        p.wait2Sec = 300
        return p
    }
    /// The G boarded at 1000, as the departure log kept it: its time at the platform, and the feed's latest times since.
    private var boardedG: BoardingCandidate {
        BoardingCandidate(trainId: "G_N|g1", key: "G_N", route: "G", boardTs: 1000, alightTs: 1690, stopsToAlight: 2, chosen: false, onLeg: true,
                          boardIdx: 0, alightIdx: 2, stopTs: [1: 1400, 2: 1690])
    }

    func testATrainFeltLeavingLateOrGoneFromTheFeedStillGivesTheLegsRide() {
        // Oct 21: the A stood at 14 St past its time, then the feed went quiet underground. The G here: the log has it at the
        // platform at 1000 and at Hoyt at 1690, and the board no longer carries it
        let sched = try! schedule()
        let p = option
        let gone = ridingItinerary(boards: [:], schedule: sched, option: p, leg: 0, boarded: boardedG, now: 1100)
        XCTAssertNotNil(gone, "followed from what the log kept")
        XCTAssertEqual(gone?.legs.first?.key, "G_N")
        XCTAssertEqual(gone?.legs.first?.arriveTs ?? 0, 1690 - lagG, accuracy: 0.5)
        // felt leaving at 1500, long after the feed's 1000: the ride runs on from then, the scheduled 240 s at least
        let late = ridingItinerary(boards: [:], schedule: sched, option: p, leg: 0, boarded: boardedG, now: 1600, departedTs: 1500)
        XCTAssertEqual(late?.legs.first?.boardTs, 1500)
        XCTAssertEqual(late?.legs.first?.arriveTs ?? 0, 1740, accuracy: 0.5)
        // a pull-away within a minute of the feed's time changes nothing
        let onTime = ridingItinerary(boards: [:], schedule: sched, option: p, leg: 0, boarded: boardedG, now: 1100, departedTs: 1000 - lagG + 30)
        XCTAssertEqual(onTime?.legs.first?.arriveTs ?? 0, 1690 - lagG, accuracy: 0.5)
        // with nothing kept at the alighting stop, the scheduled run from the platform moment
        var bare = boardedG; bare.stopTs = [:]; bare.alightTs = nil
        XCTAssertEqual(ridingItinerary(boards: [:], schedule: sched, option: p, leg: 0, boarded: bare, now: 1100)?.legs.first?.arriveTs ?? 0,
                       1000 + 240 - lagG, accuracy: 0.5)
    }

    func testAcrossThePlatformTheConnectionIsTimedFromTheEarlyEndOfTheArrival() {
        // Oct 22 at Jay St: the F due at the platform in a window; the A across the platform a little before the F's
        // expected moment, the C after it. The A is named, the C a short wait behind it
        let sched = try! schedule()
        var p = option
        p.transfer = PathTransfer(stop: "c1", stop2: "c1", station: "Hoyt", walkSec: 0)      // one platform: across it
        var g = train("g1", key: "G_N", points: [(2, 1690)])
        g.pred = nil
        let a = train("a", key: "C_N", points: [(1, 1650 - lagG + lagC), (3, 2000)])
        let c = train("c", key: "C_N", points: [(1, 1800), (3, 2100)])
        let boards = ["G_N": board("G_N", [g]), "C_N": board("C_N", [a, c])]
        // without a window for the G's arrival, the expected moment stands: the first one is gone by then
        let plain = ridingItinerary(boards: boards, schedule: sched, option: p, leg: 0, boarded: boardedG, now: 1100)
        XCTAssertEqual(plain?.legs.last?.train.tripId, "c")
        // with the G due as early as 1690 - lag - 60, the first one is in reach
        var early = boards
        var ge = g
        ge.pred = PredictedTrain(tripId: "g1", points: [PredictedPoint(idx: 2, feedTs: 1690, etaTs: 1690, loTs: 1630, hiTs: 1750, source: "test")],
                                 holdExtraSec: 0, knockOnSec: 0, scenario: "test")
        early["G_N"] = board("G_N", [ge])
        let it = ridingItinerary(boards: early, schedule: sched, option: p, leg: 0, boarded: boardedG, now: 1100)
        XCTAssertEqual(it?.legs.last?.train.tripId, "a")
        XCTAssertNotNil(it?.nextIfMissedSec, "the next one behind it is shown too")
    }

    func testStopsToTheChangeCountDownWithTheTrainsProgress() {
        // the G from g0 to Hoyt (idx 2): two stops, Hoyt counted
        func cand(next: Int, stoppedAt: Int? = nil) -> TripCandidate {
            var t = train("g", key: "G_N", points: [(next, 1000)])
            if let i = stoppedAt {
                t.position = TrainPosition(status: "STOPPED_AT", stopId: "g\(i)", stopIdx: i, stopName: "", sinceSec: 10, holding: false, stalled: false,
                                           atTerminal: false, expectedRunSec: nil, positionLatenessSec: nil)
            }
            return TripCandidate(train: t, key: "G_N", boardTs: 1000, arriveTs: 1240, rideSec: 240, schedRideSec: 240, stopsToOrigin: 0)
        }
        let p = option
        XCTAssertEqual(rideStopsLeft(cand(next: 0), option: p, leg: 0)?.left, 2, "not yet at the boarding stop: the whole ride")
        XCTAssertEqual(rideStopsLeft(cand(next: 1), option: p, leg: 0)?.left, 2, "pulled out of g0, next stop g1")
        XCTAssertEqual(rideStopsLeft(cand(next: 2), option: p, leg: 0)?.left, 1, "Hoyt next")
        let at = rideStopsLeft(cand(next: 2, stoppedAt: 2), option: p, leg: 0)
        XCTAssertEqual(at?.left, 0)
        XCTAssertEqual(at?.at, true)
        XCTAssertEqual(rideStopsLeft(cand(next: 3), option: p, leg: 0)?.left, 0, "past Hoyt")
        XCTAssertEqual(rideStopsLeft(cand(next: 0), option: p, leg: 0)?.total, 2)
        XCTAssertNil(rideStopsLeft(cand(next: 0), option: p, leg: 1), "a G is not on the C's leg")
    }

    func testAChangeAcrossThePlatformIsTimedAsOneAndCatchesATrainStandingThere() throws {
        // the A to Jay St and the F from the same platform: the feed lists 0 s, the step across takes 15; an F that
        // pulled in with the A is still there with its doors open (20 s of its stand counted), one 30 s before is gone
        let across = PathTransfer(stop: "j", stop2: "j", station: "Jay St", walkSec: 0)
        XCTAssertTrue(across.acrossPlatform)
        XCTAssertEqual(across.plannedSec, TransferTiming.stepAcrossSec)
        XCTAssertEqual(across.kindText, "across the platform")
        XCTAssertEqual(across.tightSec, TransferTiming.tightAcrossSec)
        let walk = PathTransfer(stop: "a", stop2: "b", station: "W 4 St", walkSec: 180)
        XCTAssertFalse(walk.acrossPlatform)
        XCTAssertEqual(walk.plannedSec, 180)
        XCTAssertEqual(walk.tightSec, 60)
        XCTAssertEqual(PathTransfer(stop: "a", stop2: "b", station: "x", walkSec: 400).tightSec, 100)
        func cand(_ id: String, _ board: Double) -> TripCandidate {
            TripCandidate(train: train(id, key: "F_N", points: [(0, board)]), key: "F_N", boardTs: board, arriveTs: board + 600, rideSec: 600, schedRideSec: nil, stopsToOrigin: 0)
        }
        let aOff = 1000.0, ready = aOff + across.plannedSec               // off the A at 1000, on the F side at 1015
        let standing = try XCTUnwrap(connection([cand("f1", 1000), cand("f2", 1300)], ready: ready, transfer: across))
        XCTAssertEqual(standing.train.train.tripId, "f1")
        XCTAssertTrue(standing.standing)
        XCTAssertEqual(standing.marginSec, 5)                             // its doors close 20 s after it pulled in
        let gone = try XCTUnwrap(connection([cand("f1", 970), cand("f2", 1300)], ready: ready, transfer: across))
        XCTAssertEqual(gone.train.train.tripId, "f2")
        XCTAssertFalse(gone.standing)
        XCTAssertEqual(gone.marginSec, 285)
        // between platforms a train already in is never the connection
        let walking = try XCTUnwrap(connection([cand("f1", 1170), cand("f2", 1300)], ready: aOff + 180, transfer: walk))
        XCTAssertEqual(walking.train.train.tripId, "f2")
    }

    func testATrainTheRiderCannotReachIsSkippedForTheNextRealisticOne() throws {
        // the G pulls in at 1060 and 1500 (platform moments); the rider is 0.2 mi out, 5 min at their pace: on the
        // platform at 1300, so the first G is gone and the route offers the second; at 1075 the first is still caught
        let sched = try schedule()
        let one = PathOption(id: "G", legs: [PathLeg(from: "g0", to: "g2", keys: ["G_N"], routes: ["G"], idx: ["G_N": (0, 2)], schedRideSec: 240, nStops: 2)],
                             transfer: nil)
        let boards = ["G_N": board("G_N", [train("g1", key: "G_N", points: [(0, 1060 + lagG), (2, 1300 + lagG)]),
                                           train("g2", key: "G_N", points: [(0, 1500 + lagG), (2, 1740 + lagG)])])]
        XCTAssertEqual(pathTrips(boards: boards, schedule: sched, option: one, now: 1000, maxN: 1).first?.legs[0].train.tripId, "g1")
        XCTAssertEqual(pathTrips(boards: boards, schedule: sched, option: one, now: 1000, maxN: 1, reachTs: 1300).first?.legs[0].train.tripId, "g2")
        XCTAssertEqual(pathTrips(boards: boards, schedule: sched, option: one, now: 1000, maxN: 1, reachTs: 1060 + reachDoorsSec).first?.legs[0].train.tripId, "g1",
                       "pulling in as the rider reaches the platform, its doors still open")
        // nothing in the feed is in reach (the rider far from the station): the next train anyway, not an empty route
        XCTAssertEqual(pathTrips(boards: boards, schedule: sched, option: one, now: 1000, maxN: 1, reachTs: 5000).first?.legs[0].train.tripId, "g1")
        // a reachable train beyond the first several is still found (the filter runs before the count)
        var many = (0..<12).map { i in train("m\(i)", key: "G_N", points: [(0, 1100 + Double(i) * 120 + lagG), (2, 1340 + Double(i) * 120 + lagG)]) }
        many.append(train("late", key: "G_N", points: [(0, 3000 + lagG), (2, 3240 + lagG)]))
        XCTAssertEqual(pathTrips(boards: ["G_N": board("G_N", many)], schedule: sched, option: one, now: 1000, maxN: 1, reachTs: 2900).first?.legs[0].train.tripId, "late")
    }

    func testTheBoardedTrainAndTheFirstConnectionItMakes() throws {
        let sched = try schedule()
        // the G has passed g0 and g1: the feed lists only Hoyt now; one C leaves Hoyt too soon for the walk, the next makes it
        // (feed times; the G pulls in at Hoyt at 1700 − lagG, the walk takes 120, the C pulls in at its feed time − lagC)
        let gAt = 1700 - lagG
        let boards = ["G_N": board("G_N", [train("g1", key: "G_N", points: [(2, 1700), (3, 1820)])]),
                      "C_N": board("C_N", [train("c1", key: "C_N", points: [(1, gAt + 120 + lagC - 30), (2, 1950), (3, 2100)]),
                                           train("c2", key: "C_N", points: [(1, gAt + 120 + lagC + 80), (2, 2050), (3, 2200)]),
                                           train("c3", key: "C_N", points: [(1, gAt + 120 + lagC + 280), (3, 2400)])])]
        let it = try XCTUnwrap(ridingItinerary(boards: boards, schedule: sched, option: option, leg: 0, boarded: boardedG, now: 1500))
        XCTAssertEqual(it.legs.count, 2)
        XCTAssertEqual(it.boardTs, 1000 - lagG)
        XCTAssertEqual(it.legs[0].arriveTs, gAt)                // the feed's latest for Hoyt, not the log's older 1690
        XCTAssertEqual(it.legs[1].train.tripId, "c2")
        XCTAssertEqual(it.arriveTs, 2200 - lagC)
        XCTAssertEqual(it.walkSec, 120)
        XCTAssertEqual(it.connectionMarginSec, 80)
        XCTAssertEqual(it.nextIfMissedSec, 200)
        XCTAssertEqual(it.legs[0].schedRideSec, 240)
    }

    func testWithoutAConnectingTrainTheScheduleStandsInAndWithTheTrainGoneTheLogsTimesDo() throws {
        let sched = try schedule()
        var boards = ["G_N": board("G_N", [train("g1", key: "G_N", points: [(3, 1820)])]), "C_N": board("C_N", [])]
        // the G is past Hoyt already (the alighting not yet felt): the log's kept time at Hoyt stands, and the
        // connection is the schedule's: the walk from now, half a headway, the scheduled ride
        let it = try XCTUnwrap(ridingItinerary(boards: boards, schedule: sched, option: option, leg: 0, boarded: boardedG, now: 1750))
        XCTAssertEqual(it.legs.count, 1)
        XCTAssertEqual(it.legs[0].arriveTs, 1690 - lagG)
        XCTAssertEqual(it.arriveTs, max(1690 - lagG + 120, 1750) + 300 + 300)
        XCTAssertNil(it.connectionMarginSec)
        // the G gone from the feed: the same ride, from the times the log kept
        boards["G_N"] = board("G_N", [])
        let kept = try XCTUnwrap(ridingItinerary(boards: boards, schedule: sched, option: option, leg: 0, boarded: boardedG, now: 1750))
        XCTAssertEqual(kept.legs[0].arriveTs, 1690 - lagG)
        XCTAssertEqual(kept.arriveTs, it.arriveTs)
    }

    func testOnTheLastLegTheTrainsOwnArrivalIsTheItinerary() throws {
        let sched = try schedule()
        let boards = ["C_N": board("C_N", [train("c2", key: "C_N", points: [(2, 2050), (3, 2210)])])]
        let c = BoardingCandidate(trainId: "C_N|c2", key: "C_N", route: "C", boardTs: 1900, alightTs: 2200, stopsToAlight: 2, chosen: true, onLeg: true,
                                  boardIdx: 1, alightIdx: 3, stopTs: [2: 2050, 3: 2200])
        let it = try XCTUnwrap(ridingItinerary(boards: boards, schedule: sched, option: option, leg: 1, boarded: c, now: 2000))
        XCTAssertEqual(it.legs.count, 1)
        XCTAssertEqual(it.boardTs, 1900 - lagC)
        XCTAssertEqual(it.arriveTs, 2210 - lagC)
        XCTAssertEqual(it.totalSec, 210 - lagC)
        XCTAssertEqual(it.rideVsSchedSec, 310 - 660)
    }


    func testThePlansTrainBecomesTheRideWhenNoneWasFeltAndTheConnectionStandsBetweenTrains() throws {
        // no pull-away felt or named: the train the planner's itinerary boards is the ride, as the log would have kept it
        let sched = try schedule()
        let g = train("g1", key: "G_N", points: [(0, 1000 + lagG), (1, 1400 + lagG), (2, 1690 + lagG)])
        let c = train("c1", key: "C_N", points: [(1, 1900 + lagC), (3, 2500 + lagC)])
        let c2 = train("c2", key: "C_N", points: [(1, 2200 + lagC), (3, 2800 + lagC)])
        let boards = ["G_N": board("G_N", [g]), "C_N": board("C_N", [c, c2])]
        let it = try XCTUnwrap(pathTrips(boards: boards, schedule: sched, option: option, now: 900).first)
        let pc = try XCTUnwrap(plannedCandidate(it, option: option, leg: 0))
        XCTAssertEqual(pc.trainId, "G_N|g1")
        XCTAssertEqual(pc.key, "G_N")
        XCTAssertEqual(pc.boardTs, 1000 + lagG, accuracy: 1e-6, "the feed's time at the boarding stop, as the log keeps it")
        XCTAssertEqual(pc.boardIdx, 0)
        XCTAssertEqual(pc.alightIdx, 2)
        XCTAssertEqual(pc.stopsToAlight, 2)
        XCTAssertEqual(pc.stopTs[2]!, 1690 + lagG, accuracy: 1e-6)
        XCTAssertTrue(pc.chosen)
        // the ride it describes: the G's own arrival at Hoyt and the C it makes there
        let ride = try XCTUnwrap(ridingItinerary(boards: boards, schedule: sched, option: option, leg: 0, boarded: pc, now: 1100))
        XCTAssertEqual(ride.legs.count, 2)
        XCTAssertEqual(ride.legs[0].arriveTs, 1690, accuracy: 1e-6)
        XCTAssertEqual(ride.legs[1].train.id, "C_N|c1")
        XCTAssertEqual(ride.nextIfMissedSec!, 300, accuracy: 1e-6)
        // an itinerary carrying only the leg in hand names its train at index 0
        XCTAssertEqual(plannedCandidate(ride, option: option, leg: 0)?.trainId, "G_N|g1")
        // walked off at Hoyt: the connection from there, with the one after it
        let conn = try XCTUnwrap(connectionItinerary(boards: boards, schedule: sched, option: option, leg: 1, now: 1750))
        XCTAssertEqual(conn.legs.count, 1)
        XCTAssertEqual(conn.legs[0].train.id, "C_N|c1")
        XCTAssertEqual(conn.boardTs, 1900, accuracy: 1e-6)
        XCTAssertEqual(conn.arriveTs, 2500, accuracy: 1e-6)
        XCTAssertEqual(conn.nextIfMissedSec!, 300, accuracy: 1e-6)
        // once the first C has pulled away the next one is the connection
        XCTAssertEqual(connectionItinerary(boards: boards, schedule: sched, option: option, leg: 1, now: 1900 + PlatformTiming.dwellSec + 1)?.legs[0].train.id, "C_N|c2")
    }
}
