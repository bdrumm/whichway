import XCTest
@testable import WhichWayCore

/// A faster route while one is under way, weighed from where the rider is: on the way to the station, on the
/// train, at the change.
final class RerouteTests: XCTestCase {
    private let lagG = PlatformTiming.recordedLag(route: "G"), lagC = PlatformTiming.recordedLag(route: "C"),
                lagE = PlatformTiming.recordedLag(route: "E")

    private func schedule() throws -> ClientSchedule {
        let json = """
        {"lines": {"G_N": {"stops": ["g0","g1","g2","g3"], "names": ["a","b","Hoyt","Court Sq"], "run_sec": [120, 120, 600]},
                   "C_N": {"stops": ["c0","c1","c2","c3"], "names": ["x","Hoyt","y","Court Sq"], "run_sec": [150, 150, 150]},
                   "E_N": {"stops": ["e1","e2"], "names": ["Hoyt","Court Sq"], "run_sec": [200]}}}
        """
        return try JSONDecoder().decode(ClientSchedule.self, from: Data(json.utf8))
    }
    /// The stops' complexes: Hoyt is g2, c1 and e1; Court Sq is g3, c3 and e2.
    private func station(_ stop: String) -> String {
        ["g2": "Hoyt", "c1": "Hoyt", "e1": "Hoyt", "g3": "Court Sq", "c3": "Court Sq", "e2": "Court Sq"][stop] ?? stop
    }
    private func train(_ id: String, key: String, points: [(Int, Double)]) -> LiveTrain {
        LiveTrain(key: key, tripId: id, trainId: nil, route: String(key.split(separator: "_")[0]), points: points.map { TrainPoint(idx: $0.0, ts: $0.1) },
                  nextIdx: points.first?.0 ?? 0, nextName: "", etaTs: points.first?.1 ?? 0, schedTs: nil, schedMethod: nil, latenessSec: nil,
                  effectiveLatenessSec: nil, position: nil, corroboration: "", trackChanged: false, started: true, segment: nil, lastRun: nil)
    }
    private func board(_ key: String, _ trains: [LiveTrain]) -> LineBoard {
        LineBoard(key: key, route: String(key.split(separator: "_")[0]), direction: "N", now: 0, trains: trains, nHolding: 0, nStalled: 0, nFeedOptimistic: 0)
    }
    /// The G all the way to Court Sq.
    private var direct: PathOption {
        var p = PathOption(id: "G", legs: [PathLeg(from: "g0", to: "g3", keys: ["G_N"], routes: ["G"], idx: ["G_N": (0, 3)], schedRideSec: 840, nStops: 3)], transfer: nil)
        p.schedSec = 840
        return p
    }
    /// The G to Hoyt, then the C (across the station, 120 s) or the E (another platform, 180 s) to Court Sq.
    private func change(_ second: String) -> PathOption {
        let leg2 = second == "C" ? PathLeg(from: "c1", to: "c3", keys: ["C_N"], routes: ["C"], idx: ["C_N": (1, 3)], schedRideSec: 300, nStops: 2)
                                 : PathLeg(from: "e1", to: "e2", keys: ["E_N"], routes: ["E"], idx: ["E_N": (0, 1)], schedRideSec: 200, nStops: 1)
        var p = PathOption(id: "G>\(second)", legs: [PathLeg(from: "g0", to: "g2", keys: ["G_N"], routes: ["G"], idx: ["G_N": (0, 2)], schedRideSec: 240, nStops: 2), leg2],
                           transfer: PathTransfer(stop: "g2", stop2: leg2.from, station: "Hoyt", walkSec: second == "C" ? 120 : 180))
        p.schedSec = 240 + (second == "C" ? 420 : 380)
        p.wait2Sec = 300
        return p
    }
    /// The G boarded at g0 at 1000.
    private var boardedG: BoardingCandidate {
        BoardingCandidate(trainId: "G_N|g1", key: "G_N", route: "G", boardTs: 1000, alightTs: nil, stopsToAlight: nil, chosen: true, onLeg: true,
                          boardIdx: 0, alightIdx: nil, stopTs: [:])
    }

    func testOnTheTrainAChangeAheadThatBeatsStayingOnIsOffered() throws {
        let sched = try schedule()
        // the G crawls from Hoyt to Court Sq (held ahead: 2700); a C leaves Hoyt soon after the G gets there and is in by 2050
        let gHoyt = 1700.0
        let boards = ["G_N": board("G_N", [train("g1", key: "G_N", points: [(2, gHoyt), (3, 2700)])]),
                      "C_N": board("C_N", [train("c1", key: "C_N", points: [(1, gHoyt - lagG + 120 + lagC + 60), (3, 2050)])])]
        let pos = RiderPosition.onTrain(leg: 0, boarded: boardedG)
        let f = try XCTUnwrap(fasterRoute(current: direct, options: [direct, change("C")], at: pos, boards: boards, schedule: sched,
                                          station: station, now: 1500))
        XCTAssertEqual(f.option.id, "G>C")
        XCTAssertEqual(f.itinerary.legs[0].train.tripId, "g1", "the train in hand is kept")
        XCTAssertEqual(f.itinerary.arriveTs, 2050 - lagC)
        XCTAssertEqual(f.currentArriveTs, 2700 - lagG)
        XCTAssertEqual(f.actionTs, gHoyt - lagG, "the first step: off the G at Hoyt")

        // the G is already past Hoyt: the change can no longer be made, nothing to offer
        let past = ["G_N": board("G_N", [train("g1", key: "G_N", points: [(3, 2700)])]), "C_N": boards["C_N"]!]
        XCTAssertNil(fasterRoute(current: direct, options: [direct, change("C")], at: pos, boards: past, schedule: sched, station: station, now: 1500))
        // pulling in to Hoyt in a few seconds: too late to tell the rider
        XCTAssertNil(fasterRoute(current: direct, options: [direct, change("C")], at: pos, boards: boards, schedule: sched, station: station,
                                 now: gHoyt - lagG - 20))
    }

    func testOnTheTrainStayingOnIsOfferedWhenTheConnectionIsLate() throws {
        let sched = try schedule()
        // on the G for the change to the C at Hoyt; the only C in the feed is far behind, while the G itself gets to Court Sq at 2300
        let boards = ["G_N": board("G_N", [train("g1", key: "G_N", points: [(2, 1700), (3, 2300)])]),
                      "C_N": board("C_N", [train("c1", key: "C_N", points: [(1, 2400), (3, 2700)])])]
        let pos = RiderPosition.onTrain(leg: 0, boarded: boardedG)
        let f = try XCTUnwrap(fasterRoute(current: change("C"), options: [change("C"), direct], at: pos, boards: boards, schedule: sched,
                                          station: station, now: 1500))
        XCTAssertEqual(f.option.id, "G")
        XCTAssertEqual(f.savedSec, (2700 - lagC) - (2300 - lagG))
        // a route that rides another line on the leg in hand is not a way on from this train
        XCTAssertFalse(continuesFrom(PathOption(id: "C", legs: [PathLeg(from: "c0", to: "c3", keys: ["C_N"], routes: ["C"], idx: ["C_N": (0, 3)])], transfer: nil),
                                     current: change("C"), at: pos, station: station))
    }

    func testOnTheWayToTheStationOnlyATrainInReachCounts() throws {
        let sched = try schedule()
        // from g0: the G direct boards at 1300 and is in at 2400; the G for the change boards at 1100 and with the C is in at 1900
        let boards = ["G_N": board("G_N", [train("g1", key: "G_N", points: [(0, 1100 + lagG), (2, 1340 + lagG), (3, 1940 + lagG)]),
                                           train("g2", key: "G_N", points: [(0, 1300 + lagG), (2, 1540 + lagG), (3, 2400 + lagG)])]),
                      "C_N": board("C_N", [train("c1", key: "C_N", points: [(1, 1500 + lagC), (3, 1900 + lagC)]),
                                           train("c2", key: "C_N", points: [(1, 1700 + lagC), (3, 2100 + lagC)])])]
        // on the platform by 1050: both ride the first G, and the change saves only 40 s (1900 against 1940): not worth offering
        XCTAssertNil(fasterRoute(current: direct, options: [direct, change("C")], at: .toOrigin(reachTs: 1050), boards: boards, schedule: sched,
                                 station: station, now: 1000))
        // only on the platform at 1200: the first G is gone for both; the direct one on the second G is in at 2400, the
        // change on it makes the second C, in at 2100
        let later = try XCTUnwrap(fasterRoute(current: direct, options: [direct, change("C")], at: .toOrigin(reachTs: 1200), boards: boards, schedule: sched,
                                              station: station, now: 1000))
        XCTAssertEqual(later.itinerary.legs[0].train.tripId, "g2")
        XCTAssertEqual(later.itinerary.arriveTs, 2100)
        XCTAssertEqual(later.savedSec, 300)
    }

    func testAtTheChangeAnotherPlatformCountsTheWalkAndTheOfferHoldsSteady() throws {
        let sched = try schedule()
        // off the G at Hoyt, at the C's platform at 1000: the next C is in at 1900; an E from the other platform (180 s away)
        // leaves at 1250 and is in at 1450; one leaving at 1100 would not be made
        let boards = ["C_N": board("C_N", [train("c1", key: "C_N", points: [(1, 1600 + lagC), (3, 1900 + lagC)])]),
                      "E_N": board("E_N", [train("e0", key: "E_N", points: [(0, 1100 + lagE), (1, 1300 + lagE)]),
                                           train("e1", key: "E_N", points: [(0, 1250 + lagE), (1, 1450 + lagE)])])]
        let f = try XCTUnwrap(fasterRoute(current: change("C"), options: [change("C"), change("E"), direct], at: .atChange(leg: 1), boards: boards,
                                          schedule: sched, station: station, now: 1000))
        XCTAssertEqual(f.option.id, "G>E")
        XCTAssertEqual(f.itinerary.legs[0].train.tripId, "e1", "the E leaving before the walk is done is not the one")
        XCTAssertEqual(f.savedSec, 450)
        // the direct G is behind the rider: not a way on from the change
        XCTAssertFalse(continuesFrom(direct, current: change("C"), at: .atChange(leg: 1), station: station))

        // only 90 s faster: not offered afresh, but kept when it is the one on offer already
        let close = ["C_N": board("C_N", [train("c1", key: "C_N", points: [(1, 1300 + lagC), (3, 1540 + lagC)])]), "E_N": boards["E_N"]!]
        XCTAssertNil(fasterRoute(current: change("C"), options: [change("C"), change("E")], at: .atChange(leg: 1), boards: close, schedule: sched,
                                 station: station, now: 1000))
        XCTAssertEqual(fasterRoute(current: change("C"), options: [change("C"), change("E")], at: .atChange(leg: 1), boards: close, schedule: sched,
                                   station: station, now: 1000, keeping: "G>E")?.option.id, "G>E")
    }
}
