import XCTest
@testable import WhichWayCore

/// Nov 13 at 4 Av-9 St (build 202611111119): the route started at the platform, the F three minutes off. The platform
/// shook (a G at the same platform, no push at all), and eight seconds in the detector called a pull-away. No poll had
/// come in yet, so the feed had nothing to say (`PullAwayVerdict.unchecked`), and that was read as backed: the rider was
/// shown on the F, the plan's train, three minutes before it came. The first poll then showed a G leaving, and the leg
/// switched to the G, which was not the chosen route. The gate that holds another line's train as "Boarding?" never ran,
/// because the claim had already been taken as a ride.
///
/// The class: a boarding shown with nothing placing a train at the rider's platform then. A felt pull-away alone is a
/// claim, whether or not the feed has been read; the plan names a train only when it could be the one leaving. Every way
/// a rider boards, end to end, from the motion and the feed's boards to the leg in hand, what is shown and the route.
final class BoardingBeforeFeedTests: XCTestCase {
    private let t0 = 50_000.0

    private func train(_ id: String, key: String, points: [(Int, Double)], standingAt idx: Int? = nil) -> LiveTrain {
        let pos = idx.map { TrainPosition(status: "STOPPED_AT", stopId: "s\($0)", stopIdx: $0, stopName: "", sinceSec: 10, holding: false, stalled: false, atTerminal: false) }
        return LiveTrain(key: key, tripId: id, trainId: nil, route: String(key.split(separator: "_")[0]), points: points.map { TrainPoint(idx: $0.0, ts: $0.1) },
                         nextIdx: points.first?.0 ?? 0, nextName: "", etaTs: points.first?.1 ?? 0, schedTs: nil, schedMethod: nil, latenessSec: nil,
                         effectiveLatenessSec: nil, position: pos, corroboration: "", trackChanged: false, started: true, segment: nil, lastRun: nil)
    }
    private func board(_ key: String, _ trains: [LiveTrain], now: Double) -> LineBoard {
        LineBoard(key: key, route: String(key.split(separator: "_")[0]), direction: "N", now: now, trains: trains, nHolding: 0, nStalled: 0, nFeedOptimistic: 0)
    }

    /// One leg on the F from stop 4 to stop 9, the plan's train f1; the G calls at the same platform (its stop 4).
    private func session(fBoardTs: Double) -> RideSession {
        var s = RideSession()
        let start = TripTimeline(startTs: t0, startedBy: "gps", startDistanceM: 50, placeId: nil, originStation: "S4", destStation: "S9", transferStation: nil, legs: 1)
        let leg = LegPlan(keys: ["F_N"], idx: ["F_N": (from: 4, to: 9)], chosenKey: "F_N", chosenTrainId: "F_N|f1", platformKeys: ["G_N": 4], lineFit: ["G_N": 0.5])
        s.begin(start, distanceToOriginM: 20, legs: [leg], now: t0)
        s.updateForecast(boardTs: fBoardTs, arriveTs: fBoardTs + 900, now: t0)
        return s
    }

    /// The rider's motion second by second, with the feed polled every 30 s from `firstPoll` (nil: no signal at all).
    private struct Clock {
        var ts: Double
        var firstPoll: Double?
        var boards: (Double) -> [String: LineBoard]
        mutating func run(_ s: inout RideSession, _ n: Int, push: Bool = false, shake: Bool = false, steps: Bool = false) {
            for _ in 0..<n {
                s.motion(MotionSecond(ts: ts, stepEnergy: steps ? 0.05 : 0.002, pushG: push ? 0.08 : 0.005, shakeG: push || shake ? 0.04 : 0.005))
                if let f = firstPoll, ts >= f, Int(ts - f) % 30 == 0 { s.observeBoards(boards(ts), now: ts) }
                if Int(ts) % 5 == 0 { s.tick(now: ts) }
                ts += 1
            }
        }
        mutating func pullAway(_ s: inout RideSession) { run(&s, 6, push: true) }
        mutating func ride(_ s: inout RideSession, _ n: Int, everySec: Int = 45) {
            var left = n
            while left > 0 {
                let quiet = min(everySec - 6, left); run(&s, quiet, shake: true); left -= quiet
                if left > 0 { let p = min(6, left); run(&s, p, push: true); left -= p }
            }
        }
        /// Whether the rider was ever shown on a train, or the plan's train named, over the next `n` seconds of `body`.
        mutating func watch(_ s: inout RideSession, _ n: Int, shake: Bool = false, onShown: inout Bool, fNamed: inout Bool, followed: inout Bool) {
            for _ in 0..<n {
                run(&s, 1, shake: shake)
                if s.onTrainShown { onShown = true }
                if s.belief(leg: 0)?.bestTrain == "F_N|f1" { fNamed = true }
                if s.lineToFollow(routeKeys: ["F_N"], now: ts, lastSwitchTs: -.infinity) != nil { followed = true }
            }
        }
    }

    /// The F three minutes off; the G stands at the platform and leaves 8 s after the route started, shaking it for half a
    /// minute with no push. The first poll comes 20 s in. The rider is never shown on a train, the F is never named before
    /// it comes, the route never follows the G, and the claim is withdrawn; the F's own pull-away, felt running on, is the ride.
    func testAPlatformShakeBeforeTheFirstPollNeverPutsTheRiderOnTheChosenTrainOrAnotherLine() {
        let fLeaves = t0 + 200, gLeaves = t0 + 8
        var s = session(fBoardTs: fLeaves - 20)
        var c = Clock(ts: t0, firstPoll: t0 + 20) { now in
            let g = self.train("g1", key: "G_N", points: [(5, gLeaves + 100), (6, gLeaves + 220)])
            let f = now < fLeaves ? self.train("f1", key: "F_N", points: [(4, fLeaves - 20), (5, fLeaves + 100)], standingAt: now > fLeaves - 30 ? 4 : nil)
                                  : self.train("f1", key: "F_N", points: [(5, fLeaves + 100), (6, fLeaves + 220), (9, fLeaves + 600)])
            return ["G_N": self.board("G_N", [g], now: now), "F_N": self.board("F_N", [f], now: now)]
        }
        var shown = false, fNamed = false, followed = false
        c.watch(&s, 19, shake: true, onShown: &shown, fNamed: &fNamed, followed: &followed)
        XCTAssertTrue(s.onTrain, "the detector felt a pull-away in the shaking: a claim the sensors keep watching")
        XCTAssertTrue(s.tracker?.boardingPending ?? false, "before the first poll: shown as boarding, not riding")
        c.watch(&s, 11, shake: true, onShown: &shown, fNamed: &fNamed, followed: &followed)
        c.watch(&s, Int(fLeaves - 30 - c.ts), onShown: &shown, fNamed: &fNamed, followed: &followed)
        XCTAssertFalse(shown, "never shown on a train while waiting for the F")
        XCTAssertFalse(fNamed, "the F is never named before it reaches the platform")
        XCTAssertFalse(followed, "the route never follows the G or anything else on a claim")
        XCTAssertFalse(s.onTrain, "nothing felt after it for longer than any ride goes without: back on the platform")
        XCTAssertEqual(s.tracker?.timeline.withdrawnDepartures?.count, 1)
        c.run(&s, Int(fLeaves - c.ts) - 2); c.pullAway(&s); c.ride(&s, 240)
        XCTAssertTrue(s.onTrainShown)
        XCTAssertEqual(s.belief(leg: 0)?.bestKey, "F_N")
        XCTAssertNil(s.lineToFollow(routeKeys: ["F_N"], now: c.ts, lastSwitchTs: -.infinity))
    }

    /// No signal at the platform at all: a shake with no push is never a ride, however long the feed stays silent.
    func testAShakeWithNoFeedAtAllIsNeverShownAsARide() {
        var s = session(fBoardTs: t0 + 400)
        var c = Clock(ts: t0, firstPoll: nil) { _ in [:] }
        var shown = false, fNamed = false, followed = false
        c.watch(&s, 40, shake: true, onShown: &shown, fNamed: &fNamed, followed: &followed)
        XCTAssertTrue(s.onTrain)
        c.watch(&s, 300, onShown: &shown, fNamed: &fNamed, followed: &followed)
        XCTAssertFalse(shown)
        XCTAssertFalse(fNamed, "the plan's train was minutes away when the shake came")
        XCTAssertFalse(s.onTrain, "withdrawn by the motion alone, with no poll")
    }

    /// No signal, and the rider boards an F earlier than the plan's (the plan's is minutes behind): the plan's line is the
    /// guess, not its train, and the ride's pushes back it.
    func testAnEarlierTrainOfThePlansLineIsNamedByLineNotAsThePlansTrain() {
        var s = session(fBoardTs: t0 + 400)
        var c = Clock(ts: t0, firstPoll: nil) { _ in [:] }
        c.run(&s, 58); c.pullAway(&s)
        XCTAssertEqual(s.belief(leg: 0)?.bestKey, "F_N", "the plan's line is the guess")
        XCTAssertNil(s.belief(leg: 0)?.bestTrain, "not the plan's train, still minutes off")
        c.ride(&s, 110)
        XCTAssertTrue(s.onTrainShown)
    }

    /// No signal at the platform, and the rider does board the F as it comes: the ride's own pushes back the pull-away
    /// with no poll needed, and the plan's train (due then) is the leg's guess.
    func testARealRideWithNoFeedIsBackedByItsOwnPushes() {
        let fDue = t0 + 60
        var s = session(fBoardTs: fDue)
        var c = Clock(ts: t0, firstPoll: nil) { _ in [:] }
        c.run(&s, 58); c.pullAway(&s)
        XCTAssertTrue(s.onTrain)
        XCTAssertFalse(s.onTrainShown, "a pull-away alone is a claim")
        XCTAssertEqual(s.belief(leg: 0)?.bestTrain, "F_N|f1", "the plan's train was due: named as the guess")
        c.ride(&s, 110)
        XCTAssertTrue(s.onTrainShown, "two pushes after the pull-away: the train ran on with the phone")
        c.ride(&s, 400)
        XCTAssertTrue(s.onTrainShown)
        XCTAssertNil(s.tracker?.timeline.withdrawnDepartures)
    }

    /// The rider takes the G on purpose (it came first): the feed shows the G leaving then and the ride runs on, so the
    /// claim is backed by the motion and the leg is the G. Detection still reaches an off-plan train; it only needs more
    /// than a shake.
    func testTakingTheGOnPurposeIsBackedByTheRide() {
        let gLeaves = t0 + 60
        var s = session(fBoardTs: t0 + 400)
        var c = Clock(ts: t0, firstPoll: t0 + 20) { now in
            let g = now < gLeaves ? self.train("g1", key: "G_N", points: [(4, gLeaves - 20), (5, gLeaves + 100), (9, gLeaves + 500)], standingAt: now > gLeaves - 40 ? 4 : nil)
                                  : self.train("g1", key: "G_N", points: [(5, gLeaves + 100), (6, gLeaves + 220), (9, gLeaves + 500)])
            return ["G_N": self.board("G_N", [g], now: now), "F_N": self.board("F_N", [self.train("f1", key: "F_N", points: [(4, self.t0 + 400)])], now: now)]
        }
        c.run(&s, 58); c.pullAway(&s)
        XCTAssertFalse(s.onTrainShown, "another line's train leaving does not back it by itself")
        c.ride(&s, 120)
        XCTAssertTrue(s.onTrainShown, "the ride ran on with the phone")
        XCTAssertEqual(s.belief(leg: 0)?.bestKey, "G_N")
    }

    /// "Not on train" while the claim waits: back on the platform at once, the leg starts over.
    func testNotOnTrainWhileTheClaimWaitsIsBackOnThePlatform() {
        var s = session(fBoardTs: t0 + 200)
        var c = Clock(ts: t0, firstPoll: nil) { _ in [:] }
        c.run(&s, 30, shake: true)
        XCTAssertTrue(s.tracker?.boardingPending ?? false)
        s.notOnTrain(now: c.ts)
        XCTAssertFalse(s.onTrain)
        XCTAssertNil(s.belief(leg: 0))
        XCTAssertEqual(s.tracker?.phase, .atStation)
    }

    /// The rider names the train by hand while the claim waits: their word is the ride, shown at once.
    func testATrainNamedByHandWhileTheClaimWaitsIsTheRide() {
        var s = session(fBoardTs: t0 + 200)
        var c = Clock(ts: t0, firstPoll: nil) { _ in [:] }
        c.run(&s, 30, shake: true)
        let f = BoardingCandidate(trainId: "F_N|f1", key: "F_N", route: "F", boardTs: c.ts - 20, alightTs: nil, stopsToAlight: nil, chosen: true, onLeg: true,
                                  boardIdx: 4, stopTs: [5: c.ts + 100])
        s.setOnTrain(f, now: c.ts)
        XCTAssertTrue(s.onTrainShown)
        XCTAssertEqual(s.belief(leg: 0)?.bestTrain, "F_N|f1")
        c.run(&s, 400)
        XCTAssertTrue(s.onTrain, "a ride the rider named is not the motion's to take back")
    }
}
