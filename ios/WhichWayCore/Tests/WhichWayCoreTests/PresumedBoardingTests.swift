import XCTest
@testable import WhichWayCore

/// The rider at the leg's platform when the plan's train leaves it, by the feed, and no pull-away felt: presumed on that
/// train, however late it left (Nov 10 evening: the F boarded unfelt a little after its predicted time, and the planner
/// moved on to the next F). End to end from the motion and the feed's boards to the leg in hand, with the rider's way
/// to say otherwise.
final class PresumedBoardingTests: XCTestCase {
    private let t0 = 10_000.0

    private func train(_ id: String, key: String, points: [(Int, Double)], standingAt idx: Int? = nil) -> LiveTrain {
        let pos = idx.map { TrainPosition(status: "STOPPED_AT", stopId: "s\($0)", stopIdx: $0, stopName: "", sinceSec: 10, holding: false, stalled: false, atTerminal: false) }
        return LiveTrain(key: key, tripId: id, trainId: nil, route: String(key.split(separator: "_")[0]), points: points.map { TrainPoint(idx: $0.0, ts: $0.1) },
                         nextIdx: points.first?.0 ?? 0, nextName: "", etaTs: points.first?.1 ?? 0, schedTs: nil, schedMethod: nil, latenessSec: nil,
                         effectiveLatenessSec: nil, position: pos, corroboration: "", trackChanged: false, started: true, segment: nil, lastRun: nil)
    }
    private func board(_ key: String, _ trains: [LiveTrain], now: Double) -> LineBoard {
        LineBoard(key: key, route: String(key.split(separator: "_")[0]), direction: "N", now: now, trains: trains, nHolding: 0, nStalled: 0, nFeedOptimistic: 0)
    }

    /// One leg on the F from stop 4 to stop 9, the plan's train f1; the rider at the station (`distanceToOriginM`).
    private func session(distanceToOriginM: Double = 20) -> RideSession {
        var s = RideSession()
        let start = TripTimeline(startTs: t0, startedBy: "hand", startDistanceM: distanceToOriginM, placeId: nil, originStation: "S4", destStation: "S9",
                                 transferStation: nil, legs: 1)
        let leg = LegPlan(keys: ["F_N"], idx: ["F_N": (from: 4, to: 9)], chosenKey: "F_N", chosenTrainId: nil)
        s.begin(start, distanceToOriginM: distanceToOriginM, legs: [leg], now: t0)
        s.updatePlannedTrains([0: (key: "F_N", trainId: "F_N|f1")], now: t0)
        return s
    }

    private struct Clock {
        var ts: Double
        var boards: (Double) -> [String: LineBoard]
        mutating func run(_ s: inout RideSession, _ n: Int, push: Bool = false, steps: Bool = false) {
            for _ in 0..<n {
                s.motion(MotionSecond(ts: ts, stepEnergy: steps ? 0.05 : 0.002, pushG: push ? 0.08 : 0.005, shakeG: push ? 0.03 : 0.005))
                if Int(ts) % 30 == 0 { s.observeBoards(boards(ts), now: ts) }
                if Int(ts) % 5 == 0 { s.tick(now: ts) }
                ts += 1
            }
        }
        mutating func stand(_ s: inout RideSession, _ n: Int) { run(&s, n) }
    }

    /// The F predicted at the platform at +120, in two minutes late, leaving at +260; the feed then shows it past the
    /// platform. With `held`, the feed keeps it listed at the platform until `leaves`.
    private func fBoards(predicted: Double, leaves: Double) -> (Double) -> [String: LineBoard] {
        { now in
            let f = now < leaves ? self.train("f1", key: "F_N", points: [(4, max(predicted, min(now + 20, leaves - 20))), (5, leaves + 100)], standingAt: now > leaves - 40 ? 4 : nil)
                                 : self.train("f1", key: "F_N", points: [(5, leaves + 100), (6, leaves + 220), (9, leaves + 600)])
            let f2 = self.train("f2", key: "F_N", points: [(4, self.t0 + 900), (5, self.t0 + 1000)])
            return ["F_N": self.board("F_N", [f, f2], now: now)]
        }
    }

    func testThePlansTrainLeavingLateWithNoPullAwayFeltIsPresumedBoarded() {
        var s = session()
        let leaves = t0 + 260
        var c = Clock(ts: t0, boards: fBoards(predicted: t0 + 120, leaves: leaves))
        c.stand(&s, 250)
        XCTAssertFalse(s.onTrain, "the F still stands at the platform past its time: nothing is presumed")
        c.stand(&s, 100)
        XCTAssertTrue(s.onTrain, "the F left with the rider at the platform: presumed on it")
        XCTAssertTrue(s.onTrainShown, "shown on the train, not as boarding")
        let b = s.belief(leg: 0)
        XCTAssertEqual(b?.bestKey, "F_N")
        XCTAssertEqual(b?.bestTrain, "F_N|f1", "the chosen route's train, not the next F")
        XCTAssertTrue(b?.assumed ?? false, "presumed: the prompt asks the rider \(String(describing: b?.evidence))")
        let dep = s.rideDepartedTs(leg: 0) ?? 0
        XCTAssertGreaterThanOrEqual(dep, leaves - 30, "the ride dates from when the feed had the F leave")
        XCTAssertLessThanOrEqual(dep, leaves + 30)
        // and the felt-pull-away checks leave it alone: still on the F two minutes on
        c.stand(&s, 120)
        XCTAssertTrue(s.onTrain)
    }

    func testATrainGoneFromTheFeedAfterItsTimeIsPresumedBoarded() {
        var s = session()
        let leaves = t0 + 200
        var c = Clock(ts: t0) { now in
            // the feed drops the F as it leaves, never showing it past the platform
            let f = self.train("f1", key: "F_N", points: [(4, leaves - 20), (5, leaves + 100)], standingAt: now > leaves - 40 ? 4 : nil)
            let f2 = self.train("f2", key: "F_N", points: [(4, self.t0 + 900), (5, self.t0 + 1000)])
            return ["F_N": self.board("F_N", now < leaves ? [f, f2] : [f2], now: now)]
        }
        c.stand(&s, 260)
        XCTAssertTrue(s.onTrain)
        XCTAssertEqual(s.belief(leg: 0)?.bestTrain, "F_N|f1")
    }

    func testRiderNotYetAtTheStationWhenTheTrainLeftIsNotPresumedOnIt() {
        // on the way (900 m out): the planner weighs the routes again instead (`RouteLapseWatch`)
        var s = session(distanceToOriginM: 900)
        var c = Clock(ts: t0, boards: fBoards(predicted: t0 + 120, leaves: t0 + 200))
        c.stand(&s, 400)
        XCTAssertFalse(s.onTrain)
        XCTAssertEqual(s.tracker?.phase, .approaching)
    }

    func testNotOnTrainTakesThePresumedRideBackAndThatTrainIsNotPresumedAgain() {
        var s = session()
        var c = Clock(ts: t0, boards: fBoards(predicted: t0 + 120, leaves: t0 + 200))
        c.stand(&s, 260)
        XCTAssertTrue(s.onTrain)
        s.notOnTrain(now: c.ts)
        XCTAssertFalse(s.onTrain, "the rider let the F go: back at the platform")
        XCTAssertEqual(s.tracker?.phase, .atStation)
        XCTAssertTrue(s.declinedTrain("F_N|f1"))
        c.stand(&s, 120)
        XCTAssertFalse(s.onTrain, "the F declined is never presumed again")
        // the next F: its own pull-away felt is the ride, as ever
        s.updatePlannedTrains([0: (key: "F_N", trainId: "F_N|f2")], now: c.ts)
        XCTAssertEqual(s.belief(leg: 0), nil)
    }

    func testWithTheSensorsOffNothingIsPresumedFromTheFeed() {
        // no motion at all: the tracker assumes the ride from the timetable instead, as before
        var s = session()
        let boards = fBoards(predicted: t0 + 120, leaves: t0 + 200)
        var ts = t0
        while ts < t0 + 260 { if Int(ts) % 30 == 0 { s.observeBoards(boards(ts), now: ts) }; ts += 1 }
        XCTAssertFalse(s.tracker?.sensing ?? true)
        XCTAssertNil(s.belief(leg: 0)?.evidence.first { $0 == "plan" }, "not this path")
    }

    func testAtTheChangeTheConnectionLeavingWithNoPullAwayFeltIsPresumedBoarded() {
        // the F from stop 4 to the change at its stop 6, then the C from its stop 2; the rider named the F by hand
        var s = RideSession()
        let start = TripTimeline(startTs: t0, startedBy: "hand", startDistanceM: 20, placeId: nil, originStation: "S4", destStation: "S9",
                                 transferStation: "X", legs: 2)
        let legs = [LegPlan(keys: ["F_N"], idx: ["F_N": (from: 4, to: 6)], chosenKey: "F_N", chosenTrainId: nil),
                    LegPlan(keys: ["C_N"], idx: ["C_N": (from: 2, to: 5)], chosenKey: "C_N", chosenTrainId: nil)]
        s.begin(start, distanceToOriginM: 20, legs: legs, now: t0)
        let fOff = t0 + 300, cLeaves = t0 + 520
        let boards: (Double) -> [String: LineBoard] = { now in
            let f = self.train("f1", key: "F_N", points: now < self.t0 + 60 ? [(4, self.t0 + 60), (6, fOff)] : (now < fOff ? [(5, self.t0 + 180), (6, fOff)] : [(7, fOff + 120)]))
            let c = now < cLeaves ? self.train("c1", key: "C_N", points: [(2, cLeaves - 20), (3, cLeaves + 100)], standingAt: now > cLeaves - 40 ? 2 : nil)
                                  : self.train("c1", key: "C_N", points: [(3, cLeaves + 100), (5, cLeaves + 400)])
            return ["F_N": self.board("F_N", [f], now: now), "C_N": self.board("C_N", [c], now: now)]
        }
        s.observeBoards(boards(t0), now: t0)
        s.setOnTrain(BoardingCandidate(trainId: "F_N|f1", key: "F_N", route: "F", boardTs: t0 + 60, alightTs: fOff, stopsToAlight: 2, chosen: true,
                                       onLeg: true, boardIdx: 4, alightIdx: 6, stopTs: [6: fOff]), now: t0 + 90)
        s.updatePlannedTrains([1: (key: "C_N", trainId: "C_N|c1")], now: t0 + 90)
        var c = Clock(ts: t0 + 90, boards: boards)
        c.run(&s, 190, push: false)
        c.run(&s, 6, push: true)                                  // braking into the change
        c.stand(&s, 20)
        c.run(&s, 30, steps: true)                                // off and across to the C
        XCTAssertEqual(s.currentLeg, 1, "off the F at the change")
        XCTAssertFalse(s.onTrain)
        c.stand(&s, Int(cLeaves - c.ts) + 70)                     // onto the C with no steps felt, no pull-away felt
        XCTAssertTrue(s.onTrain, "the C left with the rider at its platform: presumed on it")
        XCTAssertEqual(s.belief(leg: 1)?.bestTrain, "C_N|c1")
    }
}
