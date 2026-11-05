import XCTest
@testable import WhichWayCore

/// The change on the route in hand at the top of the home (Nov 4): the time to make the connecting train and the one
/// after it, from the feeds through `pathTrips` / `ridingItinerary` to what is shown, for each kind of change (a walk
/// between platforms, a step across the platform, a train already standing across it, no connection in the feeds yet,
/// past the change, a direct route).
final class TransferHeadroomTests: XCTestCase {
    private let lagG = PlatformTiming.recordedLag(route: "G"), lagC = PlatformTiming.recordedLag(route: "C"),
                lagA = PlatformTiming.recordedLag(route: "A")

    private func schedule() throws -> ClientSchedule {
        let json = """
        {"lines": {"G_N": {"stops": ["g0","g1","g2","g3"], "names": ["a","b","Hoyt","Court Sq"], "run_sec": [120, 120, 600]},
                   "C_N": {"stops": ["c0","c1","c2","c3"], "names": ["x","Hoyt","y","Court Sq"], "run_sec": [150, 150, 150]},
                   "A_N": {"stops": ["g2","a3"], "names": ["Hoyt","Court Sq"], "run_sec": [240]}}}
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
    private let firstLeg = PathLeg(from: "g0", to: "g2", keys: ["G_N"], routes: ["G"], idx: ["G_N": (0, 2)], schedRideSec: 240, nStops: 2)
    /// The G to Hoyt, a 2:00 walk to the C.
    private var walkToC: PathOption {
        let leg2 = PathLeg(from: "c1", to: "c3", keys: ["C_N"], routes: ["C"], idx: ["C_N": (1, 3)], schedRideSec: 300, nStops: 2)
        var p = PathOption(id: "G>C", legs: [firstLeg, leg2], transfer: PathTransfer(stop: "g2", stop2: "c1", station: "Hoyt", walkSec: 120))
        p.schedSec = 660; p.wait2Sec = 300
        return p
    }
    /// The G to Hoyt, the A across the platform.
    private var acrossToA: PathOption {
        let leg2 = PathLeg(from: "g2", to: "a3", keys: ["A_N"], routes: ["A"], idx: ["A_N": (0, 1)], schedRideSec: 240, nStops: 1)
        var p = PathOption(id: "G>A", legs: [firstLeg, leg2], transfer: PathTransfer(stop: "g2", stop2: "g2", station: "Hoyt", walkSec: 0))
        p.schedSec = 480; p.wait2Sec = 300
        return p
    }
    /// G g1 boards at 1100, Hoyt at 1340.
    private var gBoard: LineBoard { board("G_N", [train("g1", key: "G_N", points: [(0, 1100 + lagG), (2, 1340 + lagG), (3, 2300 + lagG)])]) }

    func testAWalkBetweenPlatformsGivesTheMarginAfterTheWalkAndTheTrainAfter() throws {
        let boards = ["G_N": gBoard,
                      "C_N": board("C_N", [train("c1", key: "C_N", points: [(1, 1600 + lagC), (3, 1900 + lagC)]),
                                           train("c2", key: "C_N", points: [(1, 1950 + lagC), (3, 2250 + lagC)])])]
        let it = try XCTUnwrap(pathTrips(boards: boards, schedule: try schedule(), option: walkToC, now: 1000).first)
        let h = try XCTUnwrap(TransferHeadroom.of(option: walkToC, itinerary: it, rideLeg: 0))
        let off = try XCTUnwrap(h.offTs), on = try XCTUnwrap(h.boardTs), next = try XCTUnwrap(h.nextTs)
        XCTAssertEqual(h.route, "C")
        XCTAssertEqual(on - off, 260, accuracy: 0.5, "off the G at 1340, the C's doors at 1600")
        XCTAssertEqual(try XCTUnwrap(h.marginSec), 140, accuracy: 0.5, "the 2:00 walk taken out of the 4:20 between them")
        XCTAssertEqual(next - on, 350, accuracy: 0.5)
        XCTAssertEqual(h.nextRoute, "C")
        XCTAssertFalse(h.tight)
        XCTAssertFalse(h.standing)
        XCTAssertEqual(h.headline, "2:20 to make the C at Hoyt")
        XCTAssertTrue(h.detail.contains("2:00 walk") && h.detail.contains("next C") && h.detail.contains("+5:50"), h.detail)
    }

    func testAStepAcrossThePlatformWithLittleToSpareIsTight() throws {
        // the A's doors open 30 s after the G's: 15 s for the step leaves 15 s, under the 20 s a step across needs to spare
        let boards = ["G_N": gBoard,
                      "A_N": board("A_N", [train("a1", key: "A_N", points: [(0, 1370 + lagA), (1, 1610 + lagA)])])]
        let it = try XCTUnwrap(pathTrips(boards: boards, schedule: try schedule(), option: acrossToA, now: 1000).first)
        let h = try XCTUnwrap(TransferHeadroom.of(option: acrossToA, itinerary: it, rideLeg: 0))
        XCTAssertEqual(try XCTUnwrap(h.marginSec), 15, accuracy: 0.5)
        XCTAssertTrue(h.tight)
        XCTAssertNil(h.nextTs, "no A after it in the feeds: nothing to say about missing it")
        XCTAssertTrue(h.detail.contains("across the platform"), h.detail)
    }

    func testATrainStandingAcrossThePlatformCountsTheTimeBeforeItsDoorsClose() throws {
        // the A's doors opened 5 s before the G's: still standing there with its doors open when the rider steps across
        let boards = ["G_N": gBoard,
                      "A_N": board("A_N", [train("a1", key: "A_N", points: [(0, 1335 + lagA), (1, 1575 + lagA)]),
                                           train("a2", key: "A_N", points: [(0, 1700 + lagA), (1, 1940 + lagA)])])]
        let it = try XCTUnwrap(pathTrips(boards: boards, schedule: try schedule(), option: acrossToA, now: 1000).first)
        let h = try XCTUnwrap(TransferHeadroom.of(option: acrossToA, itinerary: it, rideLeg: 0))
        XCTAssertTrue(h.standing)
        XCTAssertTrue(h.headline.contains("to board the A across the platform at Hoyt"), h.headline)
        XCTAssertEqual(try XCTUnwrap(h.nextTs) - (try XCTUnwrap(h.boardTs)), 365, accuracy: 0.5)
    }

    func testOnTheFirstTrainTheHeadroomFollowsTheRideInHand() throws {
        let sched = try schedule()
        let boards = ["G_N": gBoard,
                      "C_N": board("C_N", [train("c1", key: "C_N", points: [(1, 1600 + lagC), (3, 1900 + lagC)]),
                                           train("c2", key: "C_N", points: [(1, 1950 + lagC), (3, 2250 + lagC)])])]
        let boarded = BoardingCandidate(trainId: "G_N|g1", key: "G_N", route: "G", boardTs: 1100 + lagG, alightTs: nil, stopsToAlight: nil, chosen: true,
                                        onLeg: true, boardIdx: 0, alightIdx: nil, stopTs: [:])
        let ride = try XCTUnwrap(ridingItinerary(boards: boards, schedule: sched, option: walkToC, leg: 0, boarded: boarded, now: 1200))
        let h = try XCTUnwrap(TransferHeadroom.of(option: walkToC, itinerary: ride, rideLeg: 0))
        XCTAssertEqual(h.route, "C")
        XCTAssertEqual(try XCTUnwrap(h.marginSec), 140, accuracy: 0.5)
        XCTAssertEqual(h.nextRoute, "C")
    }

    func testNoConnectionInTheFeedsYetStillNamesTheChange() throws {
        // on the G with no C in the feeds yet: the ride in hand carries the first leg only
        let boarded = BoardingCandidate(trainId: "G_N|g1", key: "G_N", route: "G", boardTs: 1100 + lagG, alightTs: nil, stopsToAlight: nil, chosen: true,
                                        onLeg: true, boardIdx: 0, alightIdx: nil, stopTs: [:])
        let ride = try XCTUnwrap(ridingItinerary(boards: ["G_N": gBoard], schedule: try schedule(), option: walkToC, leg: 0, boarded: boarded, now: 1200))
        XCTAssertEqual(ride.legs.count, 1)
        let h = try XCTUnwrap(TransferHeadroom.of(option: walkToC, itinerary: ride, rideLeg: 0))
        XCTAssertNil(h.marginSec)
        XCTAssertNotNil(h.offTs)
        XCTAssertEqual(h.headline, "Change at Hoyt")
        XCTAssertTrue(h.detail.contains("connection not in the feeds yet"), h.detail)
        XCTAssertNotNil(TransferHeadroom.of(option: walkToC, itinerary: nil, rideLeg: 0), "no train at all: the change is still named")
    }

    func testPastTheChangeOrOnADirectRouteThereIsNone() {
        XCTAssertNil(TransferHeadroom.of(option: walkToC, itinerary: nil, rideLeg: 1))
        var direct = PathOption(id: "G", legs: [firstLeg], transfer: nil)
        direct.schedSec = 240
        XCTAssertNil(TransferHeadroom.of(option: direct, itinerary: nil, rideLeg: 0))
    }
}
