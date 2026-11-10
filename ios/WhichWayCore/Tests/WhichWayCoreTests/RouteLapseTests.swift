import XCTest
@testable import WhichWayCore

/// The chosen route lapsing: the train it counts on for the leg boarded next goes without the rider, every way that
/// happens, and the ways it must not be read as lapsed (a boarding felt, the sensors off at the platform).
final class RouteLapseTests: XCTestCase {
    private let approaching = BoardingWatch(place: .approaching, boarding: false, sensing: true)
    private let platform = BoardingWatch(place: .atPlatform, boarding: false, sensing: true)
    private let noRoute = BoardingWatch(place: .noRoute, boarding: false, sensing: false)

    /// A watch counting on train "f1" boarding at 1000 on route "F", leg `leg`.
    private func counting(_ watch: BoardingWatch, leg: Int = 0, routeId: String = "F") -> RouteLapseWatch {
        var w = RouteLapseWatch()
        XCTAssertNil(w.check(routeId: routeId, leg: leg, first: ("f1", 1000), watch: watch, now: 900))
        XCTAssertEqual(w.counted, CountedTrain(routeId: routeId, leg: leg, trainId: "f1", boardTs: 1000))
        return w
    }

    // MARK: on the way, no station proximity

    func testOnTheWayTheCountdownReachesZeroWithNothingBoardedLapses() {
        var w = counting(approaching)
        // the planner moves on to the next F the moment the first one's time passes
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: approaching, now: 1000))
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: approaching, now: 1000 + Lapse.approachGraceSec - 1),
                     "the pull-away may still be felt from a platform the GPS never saw")
        XCTAssertEqual(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: approaching, now: 1000 + Lapse.approachGraceSec), .departed)
        // counted afresh after the re-weighing: the next call names the next train and does not lapse again
        XCTAssertNil(w.check(routeId: "A", leg: 0, first: ("a1", 1200), watch: approaching, now: 1061))
        XCTAssertEqual(w.counted?.trainId, "a1")
        XCTAssertNil(w.check(routeId: "A", leg: 0, first: ("a1", 1200), watch: approaching, now: 1100))
    }

    func testOnTheWayAPullAwayFeltInTheGraceHoldsTheRoute() {
        var w = counting(approaching)
        let boarded = BoardingWatch(place: .approaching, boarding: true, sensing: true)
        // the F boarded from a platform the GPS never placed the rider at: the felt pull-away (waiting for the feed) holds
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: boarded, now: 1030))
        XCTAssertNil(w.counted)
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: boarded, now: 1200))
    }

    func testOnTheWayATrainOutOfReachLapsesBeforeItsTime() {
        var w = counting(approaching)
        // the rider's pace from the last fix puts them on the platform after the F: the planner names the next one
        XCTAssertEqual(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: approaching, now: 950), .movedOn)
    }

    func testOnTheWayATrainDroppedFromTheFeedLapses() {
        var w = counting(approaching)
        XCTAssertEqual(w.check(routeId: "F", leg: 0, first: nil, watch: approaching, now: 950), .movedOn)
    }

    func testAnEarlierTrainOrALaterTimeForTheSameTrainIsNoLapse() {
        var w = counting(approaching)
        // the feed lists an earlier F in reach: a better train, counted from here
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f0", 980), watch: approaching, now: 910))
        XCTAssertEqual(w.counted?.trainId, "f0")
        // that train runs late: its time moves and the clock goes by the new one
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f0", 1100), watch: approaching, now: 1000))
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f0", 1100), watch: approaching, now: 1100 + Lapse.approachGraceSec - 1))
        XCTAssertEqual(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: approaching, now: 1100 + Lapse.approachGraceSec), .departed)
    }

    // MARK: at the platform, or between trains at the change

    func testAtThePlatformWithTheSensorsOnATrainGoneWithoutAPullAwayLapses() {
        var w = counting(platform)
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: platform, now: 1060),
                     "the rider is at the station and may have boarded: the pull-away has its grace")
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: platform, now: 1000 + Lapse.platformGraceSec - 1))
        XCTAssertEqual(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: platform, now: 1000 + Lapse.platformGraceSec), .departed)
    }

    func testAtThePlatformAPullAwayFeltHoldsTheRoute() {
        var w = counting(platform)
        let rode = BoardingWatch(place: .atPlatform, boarding: true, sensing: true)
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: rode, now: 1050))
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: rode, now: 1500))
    }

    func testAtThePlatformWithTheSensorsOffTheRouteIsTakenAsPlanned() {
        var w = counting(BoardingWatch(place: .atPlatform, boarding: false, sensing: false))
        let off = BoardingWatch(place: .atPlatform, boarding: false, sensing: false)
        // the tracker assumes the ride from the timetable: nothing here contradicts it
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: off, now: 1500))
    }

    func testAtThePlatformATrainWithdrawnWellAheadOfItsTimeLapsesAtOnce() {
        var w = counting(platform)
        XCTAssertEqual(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: platform, now: 1000 - Lapse.droppedEarlySec - 1), .movedOn)
        // gone from the feed just ahead of its time is the train leaving (`forecastTrainDeparted`): the grace runs
        var v = counting(platform)
        XCTAssertNil(v.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: platform, now: 1000 - Lapse.droppedEarlySec + 10))
    }

    func testAtTheChangeAMissedConnectionLapses() {
        // off the first train at the change, waiting for leg 1's train
        var w = counting(platform, leg: 1)
        XCTAssertNil(w.check(routeId: "F", leg: 1, first: ("f2", 1400), watch: platform, now: 1100))
        XCTAssertEqual(w.check(routeId: "F", leg: 1, first: ("f2", 1400), watch: platform, now: 1000 + Lapse.platformGraceSec), .departed)
        // stepped onto it with no steps at all, or onto one standing there: the pull-away holds the route as before
        var v = counting(platform, leg: 1)
        XCTAssertNil(v.check(routeId: "F", leg: 1, first: ("f2", 1400), watch: BoardingWatch(place: .atPlatform, boarding: true, sensing: true), now: 1030))
        XCTAssertNil(v.check(routeId: "F", leg: 1, first: ("f2", 1400), watch: platform, now: 1300), "counted afresh, not the train ridden")
        XCTAssertEqual(v.counted?.trainId, "f2")
    }

    func testAnotherRouteOrLegIsCountedAfreshNotLapsed() {
        var w = counting(approaching)
        // the rider picked another route by hand, or the leg moved on: whatever that route counts on is counted from here
        XCTAssertNil(w.check(routeId: "A", leg: 0, first: ("a2", 1500), watch: approaching, now: 1200))
        XCTAssertEqual(w.counted?.routeId, "A")
        XCTAssertNil(w.check(routeId: "A", leg: 1, first: ("c1", 1600), watch: platform, now: 1300))
        XCTAssertEqual(w.counted?.leg, 1)
    }

    // MARK: no route under way

    func testWithNoRouteTheHomeCountdownReachingZeroLapsesAtOnce() {
        var w = counting(noRoute)
        XCTAssertNil(w.check(routeId: "F", leg: 0, first: ("f1", 1000), watch: noRoute, now: 999))
        XCTAssertEqual(w.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: noRoute, now: 1000), .departed)
        var v = counting(noRoute)
        XCTAssertEqual(v.check(routeId: "F", leg: 0, first: ("f2", 1400), watch: noRoute, now: 950), .movedOn)
    }

    func testTheNoteSaysWhatHappened() {
        XCTAssertEqual(lapseNote(.departed, from: "F", to: "A"), "train left without you: now A")
        XCTAssertEqual(lapseNote(.movedOn, from: "F", to: "F"), "train out of reach: next train on F")
        XCTAssertEqual(lapseNote(.departed, from: "F", to: nil), "train left without you: next train on F")
    }

    // MARK: the tracker lets the train go

    func testTheTrackerForecastFollowsTheNextTrainOnceTheFrozenOneIsLetGo() {
        let start = TripTimeline(startTs: 900, startedBy: "hand", startDistanceM: 40, placeId: nil, originStation: "S1", destStation: "S9",
                                 transferStation: nil, legs: 1)
        var t = TripTracker(start, distanceToOriginM: 40)
        t.updateForecast(boardTs: 1000, arriveTs: 1600, now: 900)
        // its time passed with the rider at the station: frozen ("presumably took this one")
        t.updateForecast(boardTs: 1400, arriveTs: 2000, now: 1010)
        XCTAssertEqual(t.timeline.forecastBoardTs, 1000)
        t.letForecastGo()
        t.updateForecast(boardTs: 1400, arriveTs: 2000, now: 1130)
        XCTAssertEqual(t.timeline.forecastBoardTs, 1400)
        XCTAssertEqual(t.timeline.liveArriveTs, 2000)
    }
}

/// The way on from the change once the connection counted on has gone.
final class BestWayOnTests: XCTestCase {
    private let lagC = PlatformTiming.recordedLag(route: "C"), lagE = PlatformTiming.recordedLag(route: "E")

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
    private var direct: PathOption {
        var p = PathOption(id: "G", legs: [PathLeg(from: "g0", to: "g3", keys: ["G_N"], routes: ["G"], idx: ["G_N": (0, 3)], schedRideSec: 840, nStops: 3)], transfer: nil)
        p.schedSec = 840
        return p
    }
    private func change(_ second: String) -> PathOption {
        let leg2 = second == "C" ? PathLeg(from: "c1", to: "c3", keys: ["C_N"], routes: ["C"], idx: ["C_N": (1, 3)], schedRideSec: 300, nStops: 2)
                                 : PathLeg(from: "e1", to: "e2", keys: ["E_N"], routes: ["E"], idx: ["E_N": (0, 1)], schedRideSec: 200, nStops: 1)
        var p = PathOption(id: "G>\(second)", legs: [PathLeg(from: "g0", to: "g2", keys: ["G_N"], routes: ["G"], idx: ["G_N": (0, 2)], schedRideSec: 240, nStops: 2), leg2],
                           transfer: PathTransfer(stop: "g2", stop2: leg2.from, station: "Hoyt", walkSec: second == "C" ? 120 : 180))
        p.schedSec = 240 + (second == "C" ? 420 : 380)
        p.wait2Sec = 300
        return p
    }

    func testAMissedConnectionMovesToTheWayOnThatGetsInFirst() throws {
        let sched = try schedule()
        // at Hoyt at 1000, the C counted on gone: the next C is in at 1900; an E from the other platform (180 s away) is in at 1450
        let boards = ["C_N": board("C_N", [train("c2", key: "C_N", points: [(1, 1600 + lagC), (3, 1900 + lagC)])]),
                      "E_N": board("E_N", [train("e1", key: "E_N", points: [(0, 1250 + lagE), (1, 1450 + lagE)])])]
        let best = bestWayOn(current: change("C"), options: [change("C"), change("E"), direct], at: .atChange(leg: 1), boards: boards,
                             schedule: sched, station: station, now: 1000)
        XCTAssertEqual(best?.id, "G>E", "any saving moves the route: the one in hand has lapsed, so no offer threshold applies")
    }

    func testTheRouteInHandOnItsNextTrainStaysWhenNothingBeatsIt() throws {
        let sched = try schedule()
        // the next C is in at 1500, the E at 1600
        let boards = ["C_N": board("C_N", [train("c2", key: "C_N", points: [(1, 1200 + lagC), (3, 1500 + lagC)])]),
                      "E_N": board("E_N", [train("e1", key: "E_N", points: [(0, 1400 + lagE), (1, 1600 + lagE)])])]
        XCTAssertEqual(bestWayOn(current: change("C"), options: [change("C"), change("E")], at: .atChange(leg: 1), boards: boards,
                                 schedule: sched, station: station, now: 1000)?.id, "G>C")
    }

    func testAWayWhoseTrainHasAlsoGoneDoesNotCount() throws {
        let sched = try schedule()
        // the only E in the feed left before the walk to its platform could be done; the C's next train is in at 2000
        let boards = ["C_N": board("C_N", [train("c2", key: "C_N", points: [(1, 1700 + lagC), (3, 2000 + lagC)])]),
                      "E_N": board("E_N", [train("e0", key: "E_N", points: [(0, 1100 + lagE), (1, 1300 + lagE)])])]
        XCTAssertEqual(bestWayOn(current: change("C"), options: [change("C"), change("E")], at: .atChange(leg: 1), boards: boards,
                                 schedule: sched, station: station, now: 1000)?.id, "G>C")
    }
}
