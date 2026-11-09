import XCTest
@testable import WhichWayCore

/// Nov 4 2026, 4 Av-9 St: a G from Church Av was never tracked. The feed played its timetable, stop times and
/// "positions" included (every one on the half minute), and the platform clock and the app both counted down to it.
/// The train came in minutes early. Its timetable put it into Hoyt after the A had left, so the plan named the A behind
/// it; the real G made the earlier A.
///
/// A trip whose next stop times all sit on the timetable's half-minute grid is the feed playing the timetable
/// (`Predictor.isTimetableTrip`). Such a train boards at the early edge of the engine's window, and the change after it is
/// planned from the early edge too, with the train behind as the one if it does not come early. Every way of making the
/// change is checked: a walk between platforms, a step across, a train already standing there, the train in hand once
/// the feed starts tracking it, and a tracked train left as it was.
final class TimetableTripTests: XCTestCase {
    private let lagG = PlatformTiming.recordedLag(route: "G"), lagA = PlatformTiming.recordedLag(route: "A")
    private let doors = PlatformTiming.doorsOpenSec
    /// How far ahead of its timetable the engine's window lets a timetable train come (its p10).
    private let early = 90.0

    private func schedule() throws -> ClientSchedule {
        let json = """
        {"lines": {"G_N": {"stops": ["F23N","F22N","A42N","G33N"], "names": ["4 Av-9 St","Smith-9 Sts","Hoyt","Bedford-Nostrand"], "run_sec": [120, 120, 120]},
                   "A_N": {"stops": ["A43N","A42N","A41N","A31N"], "names": ["Lafayette","Hoyt","Jay St","14 St"], "run_sec": [150, 150, 600]}}}
        """
        return try JSONDecoder().decode(ClientSchedule.self, from: Data(json.utf8))
    }

    /// A train on a predicted board: the engine's times are the feed's here, with a window `early` wide below them for a
    /// timetable train and 20 s for a tracked one.
    private func train(_ id: String, key: String, points: [(Int, Double)], timetable: Bool) -> LiveTrain {
        let route = String(key.split(separator: "_")[0])
        var t = LiveTrain(key: key, tripId: id, trainId: nil, route: route, points: points.map { TrainPoint(idx: $0.0, ts: $0.1) },
                          nextIdx: points.first?.0 ?? 0, nextName: "", etaTs: points.first?.1 ?? 0, schedTs: nil, schedMethod: nil, latenessSec: nil,
                          effectiveLatenessSec: nil, position: nil, corroboration: "", trackChanged: false, started: true, segment: nil, lastRun: nil,
                          timetable: timetable ? true : nil)
        t.feedPoints = t.points
        let below = timetable ? early : 20
        t.pred = PredictedTrain(tripId: id, points: points.map { PredictedPoint(idx: $0.0, feedTs: $0.1, etaTs: $0.1, loTs: $0.1 - below, hiTs: $0.1 + 60, source: "feed") },
                                holdExtraSec: 0, knockOnSec: 0, scenario: "baseline")
        return t
    }
    private func board(_ key: String, _ trains: [LiveTrain]) -> LineBoard {
        LineBoard(key: key, route: String(key.split(separator: "_")[0]), direction: "N", now: 0, trains: trains, nHolding: 0, nStalled: 0, nFeedOptimistic: 0)
    }
    /// The G from 4 Av-9 St to Hoyt, then the A from Hoyt to 14 St, across the platform or by a walk between platforms.
    private func option(across: Bool) -> PathOption {
        var p = PathOption(id: "G>A", legs: [PathLeg(from: "F23N", to: "A42N", keys: ["G_N"], routes: ["G"], idx: ["G_N": (0, 2)], schedRideSec: 240, nStops: 2),
                                            PathLeg(from: "A42N", to: "A31N", keys: ["A_N"], routes: ["A"], idx: ["A_N": (1, 3)], schedRideSec: 750, nStops: 2)],
                           transfer: PathTransfer(stop: "A42N", stop2: across ? "A42N" : "A42S", station: "Hoyt", walkSec: across ? 0 : 60))
        p.schedSec = 240 + Int(p.transfer!.plannedSec) + 750
        p.wait2Sec = 300
        return p
    }
    /// The G timetabled into Hoyt at 1300 (entry); one A in `aOffset` before that, the next two 3 and 6 min later.
    private func boards(gTimetable: Bool, aOffset: Double) -> [String: LineBoard] {
        ["G_N": board("G_N", [train("g1", key: "G_N", points: [(0, 1000 + lagG), (2, 1300 + lagG)], timetable: gTimetable)]),
         "A_N": board("A_N", [train("a1", key: "A_N", points: [(1, 1300 - aOffset + lagA), (3, 2050 - aOffset + lagA)], timetable: false),
                              train("a2", key: "A_N", points: [(1, 1480 - aOffset + lagA), (3, 2230 - aOffset + lagA)], timetable: false),
                              train("a3", key: "A_N", points: [(1, 1660 - aOffset + lagA), (3, 2410 - aOffset + lagA)], timetable: false)])]
    }

    func testTheFeedPlayingTheTimetableIsReadFromItsStopTimes() throws {
        // the board marks the trip from the feed itself: half-minute stop times
        let sched = try schedule()
        func feed(_ times: [Double]) -> [String: RTFeed] {
            var tu = RTTripUpdate()
            tu.trip = RTTrip(tripId: "061700_G..N14R", startDate: "20261104", routeId: "G")
            tu.stops = zip(["F23N", "F22N", "A42N"], times).map { RTStopTime(stopId: $0.0, arrival: $0.1) }
            var v = RTVehicle()
            v.trip = tu.trip; v.status = "IN_TRANSIT_TO"; v.stopId = "F23N"; v.timestamp = times[0] - 120
            return ["g": RTFeed(timestamp: times[0] - 100, trips: [tu], vehicles: [v])]
        }
        let onGrid = [1_700_000_100.0, 1_700_000_220, 1_700_000_400]
        let tracked = [1_700_000_108.0, 1_700_000_233, 1_700_000_401]
        let a = try XCTUnwrap(lineBoard(schedule: sched, lineSched: [], feeds: feed(onGrid), key: "G_N", now: onGrid[0] - 100))
        let b = try XCTUnwrap(lineBoard(schedule: sched, lineSched: [], feeds: feed(tracked), key: "G_N", now: tracked[0] - 100))
        XCTAssertTrue(a.trains.first?.isTimetable == true, "every stop time on the half minute: the timetable")
        XCTAssertFalse(b.trains.first?.isTimetable == true, "a tracked train's times are to the second")
        XCTAssertEqual(Predictor.input(a).first?.timetable, true, "and the engine is told")
    }

    func testATimetableTrainBoardsAtTheEarlyEdgeAndSaysSo() throws {
        let sched = try schedule()
        let single = PathOption(id: "G", legs: [PathLeg(from: "F23N", to: "A42N", keys: ["G_N"], routes: ["G"], idx: ["G_N": (0, 2)], schedRideSec: 240, nStops: 2)], transfer: nil)
        let tt = try XCTUnwrap(pathTrips(boards: boards(gTimetable: true, aOffset: 0), schedule: sched, option: single, now: 800).first)
        XCTAssertEqual(tt.boardTs, 1000 - early + doors, accuracy: 1e-6, "on the platform by the early edge")
        XCTAssertEqual(tt.arriveTs, 1300 + doors, accuracy: 1e-6, "the arrival is the engine's own time")
        XCTAssertEqual(tt.legs[0].boardCentralTs ?? 0, 1000 + doors, accuracy: 1e-6)
        XCTAssertEqual(tt.legs[0].timetableNote, "not tracked yet · may come 1:30 early")
        // the train is not given up at its early edge: it stays the one to take until its own time has passed
        XCTAssertEqual(pathTrips(boards: boards(gTimetable: true, aOffset: 0), schedule: sched, option: single, now: 1000 + doors).first?.legs[0].train.tripId, "g1")
        // a tracked train: as before
        let tr = try XCTUnwrap(pathTrips(boards: boards(gTimetable: false, aOffset: 0), schedule: sched, option: single, now: 800).first)
        XCTAssertEqual(tr.boardTs, 1000 + doors, accuracy: 1e-6)
        XCTAssertNil(tr.legs[0].boardCentralTs)
        XCTAssertNil(tr.legs[0].timetableNote)
    }

    /// The A leaving Hoyt `aOffset` before the G's timetable time there: every way to make the change, timetable G or tracked.
    func testEveryWayToMakeTheChangeAfterATimetableTrain() throws {
        let sched = try schedule()
        for across in [true, false] {
            let p = option(across: across)
            let walk = p.transfer!.plannedSec
            for aOffset in stride(from: -30.0, through: 150, by: 10) {
                let what = "\(across ? "across the platform" : "walk"), A in \(aOffset) s before the G's timetable time"
                let tt = try XCTUnwrap(pathTrips(boards: boards(gTimetable: true, aOffset: aOffset), schedule: sched, option: p, now: 800).first, what)
                let tr = try XCTUnwrap(pathTrips(boards: boards(gTimetable: false, aOffset: aOffset), schedule: sched, option: p, now: 800).first, what)
                // the first A's doors (entry + doors) against the G's doors plus the change, from its early edge or its time
                let aDoors = 1300 - aOffset + doors
                let standing = across ? TransferTiming.standingCatchSec : 0
                let reachEarly = 1300 - early + doors + walk, reachOnTime = 1300 + doors + walk
                func named(_ reach: Double) -> String { aDoors + standing >= reach ? "a1" : (aDoors + 180 + standing >= reach ? "a2" : "a3") }
                XCTAssertEqual(tt.legs[1].train.tripId, named(reachEarly), "timetable G, " + what)
                XCTAssertEqual(tr.legs[1].train.tripId, named(reachOnTime), "tracked G, " + what)
                if tt.legs[1].train.tripId == "a1" && tr.legs[1].train.tripId == "a2" {
                    // planned on the G coming early: the A behind is what it means if it does not
                    XCTAssertEqual(tt.nextIfMissedSec ?? 0, 180, accuracy: 1e-6, what)
                }
                // the arrival never comes before the A named can bring the rider
                XCTAssertEqual(tt.arriveTs, tt.legs[1].arriveTs, what)
            }
        }
    }

    /// At Hoyt: an A leaving before the G's timetable time, inside the window the G may come early by.
    func testAnAInsideTheEarlyWindowIsNamed() throws {
        let sched = try schedule()
        let p = option(across: true)
        // the A's doors 85 s before the G's timetabled doors: inside the G's early window
        let tt = try XCTUnwrap(pathTrips(boards: boards(gTimetable: true, aOffset: 85), schedule: sched, option: p, now: 800).first)
        XCTAssertEqual(tt.legs[1].train.tripId, "a1")
        let tr = try XCTUnwrap(pathTrips(boards: boards(gTimetable: false, aOffset: 85), schedule: sched, option: p, now: 800).first)
        XCTAssertEqual(tr.legs[1].train.tripId, "a2", "a tracked G on that time would not make it: the plan stays as before")
    }

    func testOnTheTrainOnceTheFeedTracksItTheConnectionFollowsTheRealTrain() throws {
        // the G boarded as a timetable train; the feed picks it up (no longer on the grid) 2 min ahead of its timetable,
        // and the ride in hand plans from the real times: the A in 100 s before the timetable time is made
        let sched = try schedule()
        let p = option(across: true)
        var b = boards(gTimetable: false, aOffset: 100)
        b["G_N"] = board("G_N", [train("g1", key: "G_N", points: [(2, 1180 + lagG)], timetable: false)])
        let g = BoardingCandidate(trainId: "G_N|g1", key: "G_N", route: "G", boardTs: 1000 - 90 + lagG, alightTs: 1300 + lagG, stopsToAlight: 2,
                                  chosen: true, onLeg: true, boardIdx: 0, alightIdx: 2, stopTs: [2: 1300 + lagG])
        let it = try XCTUnwrap(ridingItinerary(boards: b, schedule: sched, option: p, leg: 0, boarded: g, now: 1100))
        XCTAssertEqual(it.legs.first?.arriveTs ?? 0, 1180 + doors, accuracy: 1e-6, "the live time, not the timetable the train was boarded on")
        XCTAssertEqual(it.legs.last?.train.tripId, "a1")
    }
}
