import XCTest
@testable import WhichWayCore

/// A felt pull-away nothing has backed yet is a claim. The feed can back it (a train of the leg's lines left the
/// platform then) or take it back (no train could have); the rider's own motion has the last word either way: a train
/// that runs on with the phone on it is felt as pushes after its pull-away, and one that leaves without the rider is not.
///
/// Nov 5 evening at 4 Av-9 St: a B's pull-away was claimed, nothing was felt for six minutes, and the shaking of the
/// platform read as stops on the B until the rider's own train left. Oct 29 at Hoyt-Schermerhorn: an A's pull-away was
/// claimed while the rider waited for the C ("On c"). Nov 5 morning: the route switched to the G on a claim the rider
/// had already said was wrong. End to end, from the motion and the feed's boards to the leg in hand and the route.
final class PendingBoardingTests: XCTestCase {
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

    /// One leg on the F from stop 4 to stop 9; the G calls at the same platform (its stop 4) on its own way.
    private func session() -> RideSession {
        var s = RideSession()
        let start = TripTimeline(startTs: t0, startedBy: "hand", startDistanceM: 20, placeId: nil, originStation: "S4", destStation: "S9", transferStation: nil, legs: 1)
        let leg = LegPlan(keys: ["F_N"], idx: ["F_N": (from: 4, to: 9)], chosenKey: "F_N", chosenTrainId: nil, platformKeys: ["G_N": 4], lineFit: ["G_N": 0.5])
        s.begin(start, distanceToOriginM: 20, legs: [leg], now: t0)
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
        mutating func pullAway(_ s: inout RideSession) { run(&s, 6, push: true) }
        /// Riding between stations: quiet, a braking push about every `everySec`.
        mutating func ride(_ s: inout RideSession, _ n: Int, everySec: Int = 70) {
            var left = n
            while left > 0 {
                let quiet = min(everySec - 6, left); run(&s, quiet); left -= quiet
                if left > 0 { let p = min(6, left); run(&s, p, push: true); left -= p }
            }
        }
    }

    /// The G stands at the platform and leaves as the platform shakes; the F is four minutes off and the rider waits for
    /// it. The G's pull-away is never backed (not the leg's line), nothing is felt after it, and once no ride could go
    /// that long without a push the claim is withdrawn: the rider is at the platform, and the F's own pull-away, felt
    /// running on, is the ride.
    func testAnotherLinesPullAwayWithNothingFeltAfterIsWithdrawnAndTheRidersOwnTrainIsTheRide() {
        var s = session()
        let gLeaves = t0 + 120, fLeaves = t0 + 480
        var c = Clock(ts: t0) { now in
            let g = now < gLeaves ? self.train("g1", key: "G_N", points: [(4, gLeaves - 20), (5, gLeaves + 100)], standingAt: now > gLeaves - 30 ? 4 : nil)
                                  : self.train("g1", key: "G_N", points: [(5, gLeaves + 100), (6, gLeaves + 220)])
            let f = now < fLeaves ? self.train("f1", key: "F_N", points: [(4, fLeaves - 20), (5, fLeaves + 100)], standingAt: now > fLeaves - 30 ? 4 : nil)
                                  : self.train("f1", key: "F_N", points: [(5, fLeaves + 100), (6, fLeaves + 220), (9, fLeaves + 600)])
            return ["G_N": self.board("G_N", [g], now: now), "F_N": self.board("F_N", [f], now: now)]
        }
        c.stand(&s, 118); c.pullAway(&s)
        XCTAssertTrue(s.onTrain, "the tracker felt a pull-away")
        XCTAssertFalse(s.onTrainShown, "another line's train leaving does not back it")
        c.stand(&s, 200)
        XCTAssertTrue(s.onTrain, "still a claim: three minutes is within a ride's first wait")
        XCTAssertFalse(s.onTrainShown)
        XCTAssertNil(s.lineToFollow(routeKeys: ["F_N"], now: c.ts, lastSwitchTs: -.infinity), "the route never follows a claim")
        c.stand(&s, 100)
        XCTAssertFalse(s.onTrain, "nothing felt for longer than any ride goes without: the rider is on the platform")
        XCTAssertEqual(s.tracker?.timeline.withdrawnDepartures?.count, 1)
        // the F pulls in and leaves with the rider; the ride is felt
        c.stand(&s, Int(fLeaves - c.ts) - 2); c.pullAway(&s)
        c.ride(&s, 240)
        XCTAssertTrue(s.onTrainShown)
        XCTAssertEqual(s.belief(leg: 0)?.bestKey, "F_N")
        XCTAssertNil(s.lineToFollow(routeKeys: ["F_N"], now: c.ts, lastSwitchTs: -.infinity))
    }

    /// The F was due about then and the feed has not shown it leave yet (a poll late, or the train untracked): the
    /// pushes of the ride itself back the pull-away, and the rider is shown riding without waiting on the feed.
    func testPushesAfterThePullAwayBackItBeforeTheFeedDoes() {
        var s = session()
        let fDue = t0 + 120
        var c = Clock(ts: t0) { now in
            // due about then, and gone from the feed after (an untracked train, a feed gone quiet underground)
            ["F_N": self.board("F_N", now < fDue ? [self.train("f1", key: "F_N", points: [(4, fDue), (5, fDue + 120)])] : [], now: now)]
        }
        c.stand(&s, 118); c.pullAway(&s)
        XCTAssertFalse(s.onTrainShown)
        c.ride(&s, 110, everySec: 45)      // short runs between stations: two pushes, and the poll after them
        XCTAssertTrue(s.onTrainShown, "two pushes after the pull-away: the train ran on with the phone")
        c.ride(&s, 300)
        XCTAssertTrue(s.onTrainShown, "and the feed's quiet does not take a ride the motion confirmed back")
        XCTAssertNil(s.tracker?.timeline.withdrawnDepartures)
    }

    /// The rider's own line leaves while they let it go (too full, the wrong F): the feed backs the pull-away, but
    /// nothing is felt after it, and the ride is taken back.
    func testAPlanTrainTheRiderLetGoIsTakenBackWhenNothingIsFeltAfter() {
        var s = session()
        let f1 = t0 + 120
        var c = Clock(ts: t0) { now in
            let a = now < f1 ? self.train("f1", key: "F_N", points: [(4, f1 - 20), (5, f1 + 100)], standingAt: now > f1 - 40 ? 4 : nil)
                             : self.train("f1", key: "F_N", points: [(5, f1 + 100), (6, f1 + 220)])
            let b = self.train("f2", key: "F_N", points: [(4, f1 + 900), (5, f1 + 1020)])
            return ["F_N": self.board("F_N", [a, b], now: now)]
        }
        c.stand(&s, 118); c.pullAway(&s)
        c.stand(&s, 60)
        XCTAssertTrue(s.onTrainShown, "the feed saw the F leave then: shown riding")
        c.stand(&s, 240)
        XCTAssertFalse(s.onTrain, "no push in four and a half minutes: the rider is still on the platform")
        XCTAssertEqual(s.tracker?.timeline.withdrawnDepartures?.count, 1)
    }

    /// The rider's own word stands whatever the motion: a train named by hand is followed at once and never withdrawn.
    func testATrainNamedByHandIsFollowedAtOnceAndKept() {
        var s = session()
        let gLeaves = t0 + 120
        var c = Clock(ts: t0) { now in
            ["G_N": self.board("G_N", [self.train("g1", key: "G_N", points: [(4, gLeaves - 20), (5, gLeaves + 100)], standingAt: now > gLeaves - 30 ? 4 : nil)], now: now)]
        }
        c.stand(&s, 118); c.pullAway(&s)
        let g = BoardingCandidate(trainId: "G_N|g1", key: "G_N", route: "G", boardTs: gLeaves - 20, alightTs: nil, stopsToAlight: nil, chosen: false, onLeg: false,
                                  boardIdx: 4, stopTs: [5: gLeaves + 100])
        s.setOnTrain(g, now: c.ts)
        XCTAssertEqual(s.lineToFollow(routeKeys: ["F_N"], now: c.ts, lastSwitchTs: c.ts), "G_N", "the rider's word switches at once")
        c.stand(&s, 400)
        XCTAssertTrue(s.onTrain, "a ride the rider named is not the motion's to take back")
    }

    /// Nov 2 at Jay St: the F was held at the change for four minutes, and the rider walked across to the C as soon as
    /// it stood. A held train keeps republishing its time at the stop as the moment it will leave, so by its time the
    /// walk began four minutes before it got there; the feed had it standing at the stop then, and the walk is the
    /// change. Without it the ride ran on, the C's pushes read as staying on the F, and the route went to W 4 St.
    func testAWalkOffWhileTheTrainIsHeldAtTheChangeIsTheChange() {
        var s = RideSession()
        let start = TripTimeline(startTs: t0, startedBy: "hand", startDistanceM: 20, placeId: nil, originStation: "S4", destStation: "S9", transferStation: "S6", legs: 2)
        let legs = [LegPlan(keys: ["F_N"], idx: ["F_N": (from: 4, to: 6)], chosenKey: "F_N", chosenTrainId: "F_N|f1"),
                    LegPlan(keys: ["C_N"], idx: ["C_N": (from: 6, to: 9)], chosenKey: "C_N", chosenTrainId: nil, walkSec: 0)]
        s.begin(start, distanceToOriginM: 20, legs: legs, now: t0)
        let fLeaves = t0 + 120, inAt6 = t0 + 330, heldTo = t0 + 600
        var c = Clock(ts: t0) { now in
            let f: LiveTrain
            if now < fLeaves { f = self.train("f1", key: "F_N", points: [(4, fLeaves - 20), (5, fLeaves + 100), (6, inAt6)], standingAt: now > fLeaves - 40 ? 4 : nil) }
            else if now < inAt6 { f = self.train("f1", key: "F_N", points: [(5, fLeaves + 100), (6, inAt6)]) }
            else { f = self.train("f1", key: "F_N", points: [(6, max(now + 30, heldTo)), (7, heldTo + 120)], standingAt: now < heldTo ? 6 : nil) }   // held: its time there is when it leaves
            return ["F_N": self.board("F_N", [f], now: now)]
        }
        c.stand(&s, 118); c.pullAway(&s)
        c.ride(&s, Int(inAt6 - c.ts) + 20)
        XCTAssertTrue(s.onTrainShown)
        XCTAssertEqual(s.currentLeg, 0)
        // braking, people boarding: no still seconds before the steps, so the detector alone does not call it a stop
        c.run(&s, 4, push: true); c.run(&s, 12, steps: true)
        XCTAssertEqual(s.currentLeg, 1, "stepped off the held F at the change")
        XCTAssertFalse(s.onTrain)
    }
}
