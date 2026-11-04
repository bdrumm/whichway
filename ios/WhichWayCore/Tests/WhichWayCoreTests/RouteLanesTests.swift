import XCTest
@testable import WhichWayCore

/// The home's lanes: every way on one clock in the routes page's order, the route in hand marked where it ranks,
/// weighed from where the rider is as the trip goes on (on the platform, on the first train, at the change, on the
/// last train).
final class RouteLanesTests: XCTestCase {
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
    /// The G to Hoyt, then the C (120 s across the station) or the E (another platform, 180 s) to Court Sq.
    private func change(_ second: String) -> PathOption {
        let leg2 = second == "C" ? PathLeg(from: "c1", to: "c3", keys: ["C_N"], routes: ["C"], idx: ["C_N": (1, 3)], schedRideSec: 300, nStops: 2)
                                 : PathLeg(from: "e1", to: "e2", keys: ["E_N"], routes: ["E"], idx: ["E_N": (0, 1)], schedRideSec: 200, nStops: 1)
        var p = PathOption(id: "G>\(second)", legs: [PathLeg(from: "g0", to: "g2", keys: ["G_N"], routes: ["G"], idx: ["G_N": (0, 2)], schedRideSec: 240, nStops: 2), leg2],
                           transfer: PathTransfer(stop: "g2", stop2: leg2.from, station: "Hoyt", walkSec: second == "C" ? 120 : 180))
        p.schedSec = 240 + (second == "C" ? 420 : 380)
        p.wait2Sec = 300
        return p
    }
    /// The C from its own first stop: another line from another platform.
    private var otherLine: PathOption {
        PathOption(id: "C", legs: [PathLeg(from: "c0", to: "c3", keys: ["C_N"], routes: ["C"], idx: ["C_N": (0, 3)], schedRideSec: 450, nStops: 3)], transfer: nil)
    }
    /// G g1 boards g0 at 1100, Hoyt 1340, Court Sq 2300; G g2 boards at 1400. C c1 at Hoyt 1600, in 1900. E e1 at Hoyt 1650, in 1850.
    private var boards: [String: LineBoard] {
        ["G_N": board("G_N", [train("g1", key: "G_N", points: [(0, 1100 + lagG), (2, 1340 + lagG), (3, 2300 + lagG)]),
                              train("g2", key: "G_N", points: [(0, 1400 + lagG), (2, 1640 + lagG), (3, 2600 + lagG)])]),
         "C_N": board("C_N", [train("c1", key: "C_N", points: [(1, 1600 + lagC), (3, 1900 + lagC)]),
                              train("c2", key: "C_N", points: [(1, 1950 + lagC), (3, 2250 + lagC)])]),
         "E_N": board("E_N", [train("e1", key: "E_N", points: [(0, 1650 + lagE), (1, 1850 + lagE)])])]
    }
    private var boardedG: BoardingCandidate {
        BoardingCandidate(trainId: "G_N|g1", key: "G_N", route: "G", boardTs: 1100 + lagG, alightTs: nil, stopsToAlight: nil, chosen: true, onLeg: true,
                          boardIdx: 0, alightIdx: nil, stopTs: [:])
    }
    private var boardedC: BoardingCandidate {
        BoardingCandidate(trainId: "C_N|c1", key: "C_N", route: "C", boardTs: 1600 + lagC, alightTs: nil, stopsToAlight: nil, chosen: true, onLeg: true,
                          boardIdx: 1, alightIdx: nil, stopTs: [:])
    }

    /// The lanes as the home builds them: the route in hand from where the rider is, the ways that go on from there.
    private func lanes(_ current: PathOption, _ options: [PathOption], at pos: RiderPosition?, now: Double,
                       affinity: [String: Double] = [:]) throws -> RouteLanes {
        let sched = try schedule()
        let here = pos ?? .toOrigin(reachTs: nil)
        let it = try XCTUnwrap(currentItinerary(boards: boards, schedule: sched, option: current, at: here, now: now))
        let alts: [(PathOption, Itinerary)] = options.compactMap { p in
            guard p.id != current.id, continuesFrom(p, current: current, at: here, station: station),
                  let i = itineraryFromHere(boards: boards, schedule: sched, option: p, at: here, current: current, now: now) else { return nil }
            return (p, i)
        }
        return routeLanes(current: current, currentIt: it, alternatives: alts, affinity: affinity, at: pos, now: now, station: station)
    }

    func testTheLaneIsTheWaitTheRideTheChangeAndTheNextRideOnTheClock() throws {
        let l = try lanes(change("C"), [], at: nil, now: 1000)
        let s = l.current.segments
        XCTAssertEqual(s.map(\.kind), [.wait, .ride(route: "G", estimated: false), .change(acrossPlatform: false), .wait, .ride(route: "C", estimated: false)])
        XCTAssertEqual(s[0].startTs, 1000, "the clock starts now")
        XCTAssertEqual(s[1].startTs, 1100 + PlatformTiming.doorsOpenSec)
        XCTAssertEqual(s[2].startTs, 1340 + PlatformTiming.doorsOpenSec)
        XCTAssertEqual(s[2].endTs, 1460 + PlatformTiming.doorsOpenSec, "the change takes the planned walk")
        XCTAssertEqual(s[4].endTs, 1900 + PlatformTiming.doorsOpenSec)
        XCTAssertEqual(l.current.routes, ["G", "C"])
        XCTAssertEqual(l.current.changeAt, "Hoyt")
        XCTAssertGreaterThanOrEqual(l.endTs, 1900)
        XCTAssertEqual(l.endTs.truncatingRemainder(dividingBy: 300), 0, "the clock ends on a whole five minutes")
    }

    func testOnThePlatformTheWaysAreListedByArrivalWithTheRouteInHandWhereItRanks() throws {
        let l = try lanes(change("C"), [change("C"), direct, change("E"), otherLine], at: nil, now: 1000)
        // the C from another station is not a way on from this platform; the E at Hoyt gets in 50 s sooner
        XCTAssertEqual(l.lanes.map(\.id), ["G>E", "G>C", "G"], "earliest arrival first, the route in hand not lifted to the top")
        XCTAssertEqual(l.lanes.filter(\.isCurrent).map(\.id), ["G>C"])
        XCTAssertNil(l.typicalId, "no habits yet")
        XCTAssertEqual(l.moreCount, 0)
        let e = l.lanes[0]
        XCTAssertEqual(e.parting, .otherConnection(station: "Hoyt"))
        XCTAssertEqual(e.partsTs, 1340 + PlatformTiming.doorsOpenSec, "it leaves the route in hand when the G gets to Hoyt")
        XCTAssertEqual(e.deltaSec, -50, "the E gets in 50 s sooner")
        XCTAssertEqual(l.lanes[2].parting, .stayOn(station: "Hoyt"))
        XCTAssertEqual(l.lanes[2].segments.map(\.kind), [.wait, .ride(route: "G", estimated: false)], "staying on: one ride to the end")
    }

    func testChoosingAnotherWayKeepsTheListAndItsOrder() throws {
        let all = [change("C"), direct, change("E")]
        let onC = try lanes(change("C"), all, at: nil, now: 1000)
        let onE = try lanes(change("E"), all, at: nil, now: 1000)
        XCTAssertEqual(onE.lanes.map(\.id), onC.lanes.map(\.id), "the list stays as it is; only the mark moves")
        XCTAssertEqual(onE.lanes.filter(\.isCurrent).map(\.id), ["G>E"])
    }

    func testTheUsualWayComesFirstUnlessAnotherIsAMarginSooner() throws {
        let all = [change("C"), direct, change("E")]
        // the C at Hoyt is the rider's usual: 50 s behind the E is no reason to list the E first
        let usualC = try lanes(change("E"), all, at: nil, now: 1000, affinity: ["G>C": 0.7, "G>E": 0.2, "G": 0.1])
        XCTAssertEqual(usualC.typicalId, "G>C")
        XCTAssertEqual(usualC.lanes.map(\.id), ["G>C", "G>E", "G"])
        // the G direct is the usual, but it gets in 450 s after the E and 400 s after the C: both stay ahead of it
        let usualG = try lanes(change("C"), all, at: nil, now: 1000, affinity: ["G": 0.8, "G>C": 0.2])
        XCTAssertEqual(usualG.typicalId, "G")
        XCTAssertEqual(usualG.lanes.map(\.id), ["G>E", "G>C", "G"])
    }

    func testOnTheFirstTrainThePlatformChoicesDropAndTheClockStartsOnTheTrain() throws {
        let l = try lanes(change("C"), [change("C"), direct, change("E")], at: .onTrain(leg: 0, boarded: boardedG), now: 1200)
        XCTAssertEqual(l.current.segments.first?.kind, .ride(route: "G", estimated: false), "no wait: on the train now")
        XCTAssertEqual(l.current.segments.first?.startTs, 1200)
        XCTAssertEqual(l.lanes.map(\.id), ["G>E", "G>C", "G"], "stay on, or the E at the same change")
        for lane in l.lanes { XCTAssertEqual(lane.segments.first?.kind, .ride(route: "G", estimated: false)) }
        let next = try XCTUnwrap(l.nextChoice(after: 1200))
        XCTAssertEqual(next.station, "Hoyt")
        XCTAssertEqual(next.ts, 1340 + PlatformTiming.doorsOpenSec)
    }

    func testAtTheChangeOnlyTheConnectionsAreLeft() throws {
        let l = try lanes(change("C"), [change("C"), direct, change("E")], at: .atChange(leg: 1), now: 1400)
        XCTAssertEqual(l.current.routes, ["C"])
        XCTAssertNil(l.current.changeAt)
        XCTAssertEqual(l.current.segments.map(\.kind), [.wait, .ride(route: "C", estimated: false)])
        XCTAssertEqual(l.lanes.map(\.id), ["G>E", "G>C"], "the G stayed on is behind the rider")
        XCTAssertEqual(l.lanes[0].parting, .otherConnection(station: "Hoyt"))
    }

    func testOnTheLastTrainThereIsOneWayLeft() throws {
        let l = try lanes(change("C"), [change("C"), direct, change("E")], at: .onTrain(leg: 1, boarded: boardedC), now: 1700)
        XCTAssertEqual(l.lanes.map(\.id), ["G>C"])
        XCTAssertNil(l.nextChoice(after: 1700))
        XCTAssertEqual(l.current.segments.map(\.kind), [.ride(route: "C", estimated: false)])
        XCTAssertEqual(l.current.arriveTs, 1900 + PlatformTiming.doorsOpenSec)
    }

    func testGettingOffSoonerAndTheSameTrainsAreNotTwoWays() throws {
        // the G direct in hand: the change at Hoyt leaves it sooner
        XCTAssertEqual(laneParting(change("C"), from: direct, at: nil, station: station), .offEarlier(station: "Hoyt"))
        XCTAssertEqual(laneParting(otherLine, from: direct, at: nil, station: station), .atStart)
        // a way on the very trains of the route in hand is the same journey
        let sched = try schedule()
        let it = try XCTUnwrap(pathTrips(boards: boards, schedule: sched, option: change("C"), now: 1000, maxN: 1).first)
        var twin = change("C"); twin.id = "twin"
        let l = routeLanes(current: change("C"), currentIt: it, alternatives: [(twin, it)], at: nil, now: 1000, station: station)
        XCTAssertEqual(l.lanes.map(\.id), ["G>C"])
    }

    func testAConnectionNotInTheFeedsIsTheTimetablesGuess() throws {
        let sched = try schedule()
        // on the G, no C in the feeds: the itinerary carries the G alone and the arrival the timetable's
        let noC = ["G_N": boards["G_N"]!]
        let it = try XCTUnwrap(ridingItinerary(boards: noC, schedule: sched, option: change("C"), leg: 0, boarded: boardedG, now: 1200))
        XCTAssertEqual(it.legs.count, 1)
        let s = laneSegments(it, option: change("C"), ridingFirst: true, from: 1200)
        XCTAssertEqual(s.last?.kind, .ride(route: "C", estimated: true))
        XCTAssertEqual(s.last?.endTs, it.arriveTs)
        XCTAssertEqual(s.last.map { $0.endTs - $0.startTs }, 300, "the C's scheduled ride")
    }
}
