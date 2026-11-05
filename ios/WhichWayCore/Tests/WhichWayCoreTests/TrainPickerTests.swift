import XCTest
@testable import WhichWayCore

/// The "On a train?" sheet is the override for when the phone's reading is wrong, so it lists every train at the
/// station: any line, either direction, standing, due or just gone. Until Nov 5 it showed only trains that had left,
/// on lines with a route to the destination, the plan's way, short of the plan's alighting stop.
final class TrainPickerTests: XCTestCase {
    /// 4 Av: the F both ways (stop 1 northbound, stop 3 southbound) and the G (stop 0, its first), and the R one stop
    /// over at another station.
    private func network() throws -> (ClientSchedule, StationIndex) {
        let json = """
        {"lines": {"F_N": {"stops": ["F24N","F23N","F22N","F21N","F20N"], "names": ["7 Av","4 Av","Smith","Bergen","Jay St"], "run_sec": [120, 120, 120, 120]},
                   "F_S": {"stops": ["F20S","F21S","F22S","F23S","F24S"], "names": ["Jay St","Bergen","Smith","4 Av","7 Av"], "run_sec": [120, 120, 120, 120]},
                   "G_N": {"stops": ["F23N","G22N","G21N"], "names": ["4 Av","Smith","Bergen"], "run_sec": [120, 120]},
                   "R_N": {"stops": ["R33N","R32N"], "names": ["Union St","Atlantic"], "run_sec": [150]}}}
        """
        let sched = try JSONDecoder().decode(ClientSchedule.self, from: Data(json.utf8))
        return (sched, StationIndex(schedule: sched))
    }
    private func train(_ id: String, key: String, next: Int, points: [(Int, Double)], standing: Int? = nil) -> LiveTrain {
        let pos = standing.map { TrainPosition(status: "STOPPED_AT", stopId: "", stopIdx: $0, stopName: "", sinceSec: 10, holding: false, stalled: false, atTerminal: false) }
        return LiveTrain(key: key, tripId: id, trainId: nil, route: String(key.split(separator: "_")[0]), points: points.map { TrainPoint(idx: $0.0, ts: $0.1) },
                         nextIdx: next, nextName: "", etaTs: points.first?.1 ?? 0, schedTs: nil, schedMethod: nil, latenessSec: nil,
                         effectiveLatenessSec: nil, position: pos, corroboration: "", trackChanged: false, started: true, segment: nil, lastRun: nil)
    }
    private func board(_ key: String, _ trains: [LiveTrain]) -> LineBoard {
        LineBoard(key: key, route: String(key.split(separator: "_")[0]), direction: "", now: 0, trains: trains, nHolding: 0, nStalled: 0, nFeedOptimistic: 0)
    }

    func testEveryTrainAtTheStationIsListedWhateverTheRoute() throws {
        let (sched, index) = try network()
        let station = try XCTUnwrap(index.stations[index.stationOf("F23N")])
        let now = 10_000.0
        let boards = [
            "F_N": board("F_N", [train("f-standing", key: "F_N", next: 1, points: [(1, now - 20), (2, now + 100)], standing: 1),
                                 train("f-due", key: "F_N", next: 0, points: [(0, now + 60), (1, now + 180), (2, now + 300)]),
                                 train("f-gone", key: "F_N", next: 3, points: [(3, now + 100), (4, now + 220)]),     // left 4 Av ~2 min ago, past Smith
                                 train("f-far", key: "F_N", next: 0, points: [(0, now + 1500), (1, now + 1620)])]),    // 27 min off: not at the station
            "F_S": board("F_S", [train("fs-due", key: "F_S", next: 2, points: [(2, now + 30), (3, now + 150)])]),
            "G_N": board("G_N", [train("g-due", key: "G_N", next: 0, points: [(0, now + 240), (1, now + 360)])]),
            "R_N": board("R_N", [train("r-elsewhere", key: "R_N", next: 0, points: [(0, now + 10)])]),
        ]
        let picks = trainsToPick(boards: boards, schedule: sched, station: station, planKeys: ["F_N"], now: now)
        let ids = Set(picks.map(\.trainId))
        XCTAssertEqual(ids, ["F_N|f-standing", "F_N|f-due", "F_N|f-gone", "F_S|fs-due", "G_N|g-due"],
                       "standing, due, just gone, the other direction and another line all listed; a train 27 min off and another station's are not")
        XCTAssertEqual(picks.first?.trainId, "F_N|f-standing", "a train at the platform now first")
        let gone = try XCTUnwrap(picks.first { $0.trainId == "F_N|f-gone" })
        XCTAssertEqual(gone.boardTs, now + 100 - 240, accuracy: 0.1, "its time at 4 Av, back from Bergen by the timetable")
        XCTAssertNil(gone.alightIdx, "no alighting stop assumed: the picked train's own route is found from it")
        XCTAssertFalse(picks.first { $0.trainId == "G_N|g-due" }!.onLeg)
        XCTAssertTrue(picks.first { $0.trainId == "F_N|f-due" }!.onLeg)
    }

    func testNothingIsListedTwiceAndAnEmptyFeedListsNothing() throws {
        let (sched, index) = try network()
        let station = try XCTUnwrap(index.stations[index.stationOf("F23N")])
        XCTAssertTrue(trainsToPick(boards: [:], schedule: sched, station: station, planKeys: ["F_N"], now: 0).isEmpty)
        let t = train("f1", key: "F_N", next: 1, points: [(1, 30)])
        let picks = trainsToPick(boards: ["F_N": board("F_N", [t, t])], schedule: sched, station: station, planKeys: ["F_N"], now: 0)
        XCTAssertEqual(picks.count, 1)
    }
}
