import XCTest
@testable import WhichWayCore

/// The change across the platform at Jay St, end to end: from the motion and the feed's boards to the leg in hand, the
/// train named for the A leg, and whether the rider is on a train. One test per way a rider makes (or does not make) the
/// change (CLAUDE.md, transfers rules 1 and 2).
///
/// Nov 10 2026: off the F at Jay St, the A pulled in a minute behind it and the rider took it. The phone only called the
/// change once the F reached York St (the stop beyond), so the countdown ran out on the F; by then the rider was already
/// moving on the A, the detector stood down at that late moment, and the A was dated from it and taken for the one
/// behind. The route's timing now calls the change as soon as the F has left Jay St with nothing felt, the A boarded in
/// between is dated from its own pull-away, and a stay-on felt later still undoes the call.
final class ChangeByTimingTests: XCTestCase {
    private let t0 = 10_000.0
    /// The F reaches Jay St (its stop 6, the route's change) at this moment, at the platform.
    private var jay: Double { t0 + 600 }

    // MARK: - the feed

    private func train(_ id: String, key: String, points: [(Int, Double)], standingAt idx: Int? = nil) -> LiveTrain {
        let pos = idx.map { TrainPosition(status: "STOPPED_AT", stopId: "s\($0)", stopIdx: $0, stopName: "", sinceSec: 10, holding: false, stalled: false, atTerminal: false) }
        return LiveTrain(key: key, tripId: id, trainId: nil, route: String(key.split(separator: "_")[0]), points: points.map { TrainPoint(idx: $0.0, ts: $0.1) },
                         nextIdx: points.first?.0 ?? 0, nextName: "", etaTs: points.first?.1 ?? 0, schedTs: nil, schedMethod: nil, latenessSec: nil,
                         effectiveLatenessSec: nil, position: pos, corroboration: "", trackChanged: false, started: true, segment: nil, lastRun: nil)
    }
    private func board(_ key: String, _ trains: [LiveTrain], now: Double) -> LineBoard {
        LineBoard(key: key, route: String(key.split(separator: "_")[0]), direction: "N", now: now, trains: trains, nHolding: 0, nStalled: 0, nFeedOptimistic: 0)
    }

    /// A train at its stops (platform moments), as the feed shows it at `now`: the stops it has not left yet, with the
    /// feed's own lag, standing at a stop for `dwell` seconds from its moment there.
    private func live(_ id: String, key: String, stops: [(Int, Double)], dwell: Double, now: Double) -> LiveTrain? {
        let lag = PlatformTiming.recordedLag(route: String(key.split(separator: "_")[0]))
        let ahead = stops.filter { now < $0.1 + dwell }
        guard let first = ahead.first, now >= stops[0].1 - 900 else { return nil }
        let standing = now >= first.1 ? first.0 : nil
        return train(id, key: key, points: ahead.map { ($0.0, $0.1 + lag) }, standingAt: standing)
    }

    /// The F (stops 4 to 8: Jay St 6, York St 7, East Broadway 8) and A trains at Jay St (their stop 6, then High St 7)
    /// arriving at the given moments, each standing there 30 s.
    private func feed(aArrivals: [Double], fHeldTo: Double? = nil) -> (Double) -> [String: LineBoard] {
        { now in
            let fStops: [(Int, Double)] = [(4, self.t0 + 80), (5, self.t0 + 340), (6, self.jay), (7, self.jay + 150), (8, self.jay + 330)]
            var f = self.live("f1", key: "F_N", stops: fStops, dwell: 40, now: now)
            if let held = fHeldTo, now >= self.jay - 60 {
                // held at Jay St: standing there until `held`, its time there republished as the moment it will leave
                let lag = PlatformTiming.recordedLag(route: "F")
                if now < held {
                    f = self.train("f1", key: "F_N", points: [(6, max(now + 30, held) + lag), (7, held + 110 + lag), (8, held + 290 + lag)], standingAt: now >= self.jay ? 6 : nil)
                } else {
                    f = self.live("f1", key: "F_N", stops: [(7, held + 110), (8, held + 290)], dwell: 40, now: now)
                }
            }
            let a = aArrivals.enumerated().compactMap { i, at in
                self.live("a\(i + 1)", key: "A_N", stops: [(6, at), (7, at + 130), (8, at + 250)], dwell: 30, now: now)
            }
            return ["F_N": self.board("F_N", f.map { [$0] } ?? [], now: now), "A_N": self.board("A_N", a, now: now)]
        }
    }

    /// The F from stop 4 to Jay St, then the A from Jay St, a change across the platform (no walk).
    private func session() -> RideSession {
        var s = RideSession()
        let start = TripTimeline(startTs: t0, startedBy: "hand", startDistanceM: 20, placeId: nil, originStation: "S4", destStation: "S9",
                                 transferStation: "Jay St-MetroTech", legs: 2)
        let legs = [LegPlan(keys: ["F_N"], idx: ["F_N": (from: 4, to: 6)], chosenKey: "F_N", chosenTrainId: "F_N|f1"),
                    LegPlan(keys: ["A_N"], idx: ["A_N": (from: 6, to: 9)], chosenKey: "A_N", chosenTrainId: nil, walkSec: 0)]
        s.begin(start, distanceToOriginM: 20, legs: legs, now: t0)
        return s
    }

    // MARK: - the motion

    private struct Second { var push = false; var steps = false; var shake = 0.005 }

    /// Drives the session second by second to `until`, the feed polled every 30 s and the clock ticked every 5.
    private func drive(_ s: inout RideSession, from: Double, until: Double, feed: (Double) -> [String: LineBoard], motion: (Double) -> Second) {
        var ts = from
        while ts < until {
            let m = motion(ts)
            s.motion(MotionSecond(ts: ts, stepEnergy: m.steps ? 0.05 : 0.002, pushG: m.push ? 0.08 : 0.005, shakeG: m.push ? max(m.shake, 0.03) : m.shake))
            if Int(ts) % 30 == 0 { s.observeBoards(feed(ts), now: ts) }
            if Int(ts) % 5 == 0 { s.tick(now: ts) }
            ts += 1
        }
    }

    private func inRun(_ ts: Double, _ starts: [Double], len: Double = 6) -> Bool { starts.contains { ts >= $0 && ts < $0 + len } }

    /// On the F from its pull-away at stop 4 to Jay St: riding shakes, a push leaving and braking at each stop.
    private func onTheF(_ ts: Double) -> Second? {
        if ts < t0 + 118 { return Second() }
        if ts < jay { return Second(push: inRun(ts, [t0 + 118, t0 + 334, t0 + 380, jay - 6]), shake: 0.04) }
        return nil
    }

    private func legsAndTrain(_ s: RideSession) -> (leg: Int, onTrain: Bool, train: String?) {
        (s.currentLeg, s.onTrain, s.belief(leg: 1)?.bestTrain)
    }

    // MARK: - the change

    /// Nov 10: steps across, the A pulls in a minute behind the F, the rider steps on and it pulls away (felt). The rider
    /// is between trains as soon as the F has left Jay St, before the A even arrives, and the A leg is that A.
    func testTheAAMinuteBehindTheFIsTheOneTakenAndTheChangeIsCalledBeforeItComes() {
        var s = session()
        let fd = feed(aArrivals: [jay + 60, jay + 330])
        drive(&s, from: t0, until: jay + 85, feed: fd) { ts in
            if let f = self.onTheF(ts) { return f }
            return Second(steps: ts < self.jay + 4 || (ts >= self.jay + 58 && ts < self.jay + 61))
        }
        XCTAssertEqual(s.currentLeg, 1, "the F left Jay St with nothing felt: off at the change by the route's timing, not one stop later")
        XCTAssertFalse(s.onTrain, "between trains, waiting for the A")
        drive(&s, from: jay + 85, until: jay + 320, feed: fd) { ts in
            Second(push: self.inRun(ts, [self.jay + 90, self.jay + 184, self.jay + 230]), shake: ts >= self.jay + 90 ? 0.04 : 0.005)
        }
        XCTAssertTrue(s.onTrain)
        XCTAssertEqual(s.currentLeg, 1)
        XCTAssertEqual(s.belief(leg: 1)?.bestTrain, "A_N|a1", "the A that came a minute behind the F, not the one after it")
        XCTAssertEqual(s.rideDepartedTs(leg: 1) ?? 0, jay + 90, accuracy: 3)
        XCTAssertNil(s.stayedOn)
    }

    /// No steps at all onto an A standing across the platform, which pulls away 20 s after the F gets in; the phone, held in
    /// the hand, feels no push, only the A running. The change is told at the F's pull-away by the timing, after the A has
    /// left; the detector, standing down only then, feels the phone moving at once, and that pull-away is the A that left
    /// after the rider stepped off, dated from its own pull-away.
    func testAnAStandingAcrossThePlatformLeavingUnfeltIsDatedFromItsOwnPullAway() {
        var s = session()
        let fd = feed(aArrivals: [jay - 10, jay + 300])
        drive(&s, from: t0, until: jay + 330, feed: fd) { ts in
            if let f = self.onTheF(ts) { return f }
            return Second(push: self.inRun(ts, [self.jay + 114, self.jay + 160, self.jay + 234]), shake: ts >= self.jay + 20 ? 0.04 : 0.005)
        }
        XCTAssertEqual(s.currentLeg, 1)
        XCTAssertTrue(s.onTrain)
        XCTAssertEqual(s.belief(leg: 1)?.bestTrain, "A_N|a1")
        let a1PullAway = PlatformTiming.pullsAway(jay - 10 + PlatformTiming.recordedLag(route: "A"), route: "A")
        XCTAssertEqual(s.rideDepartedTs(leg: 1) ?? 0, a1PullAway, accuracy: 1, "the ride began when that A left, not when the change was told")
    }

    /// The rider steps across but lets the first A go (crowded); a train on the next track shakes the platform just as the
    /// change is told, and the detector calls a pull-away. It is moved back to the A that had left, a guess: the next push
    /// is a train of the leg leaving the platform, so that is the rider's train, and the A leg is the second A.
    func testLettingTheFirstAGoTheNextOneIsTheRide() {
        var s = session()
        let fd = feed(aArrivals: [jay - 10, jay + 200])
        drive(&s, from: t0, until: jay + 400, feed: fd) { ts in
            if let f = self.onTheF(ts) { return f }
            let passing = ts >= self.jay + 82 && ts < self.jay + 94
            let onA2 = ts >= self.jay + 230
            return Second(push: self.inRun(ts, [self.jay + 230, self.jay + 324]), steps: ts < self.jay + 4 || (ts >= self.jay + 212 && ts < self.jay + 215),
                          shake: passing || onA2 ? 0.04 : 0.005)
        }
        XCTAssertEqual(s.currentLeg, 1)
        XCTAssertTrue(s.onTrain)
        XCTAssertEqual(s.belief(leg: 1)?.bestTrain, "A_N|a2")
        XCTAssertEqual(s.rideDepartedTs(leg: 1) ?? 0, jay + 230, accuracy: 3)
    }

    /// Waiting on a quiet platform for an A three minutes behind: nothing is claimed until its pull-away, which is the ride.
    func testWaitingOnAQuietPlatformTheAsOwnPullAwayIsTheRide() {
        var s = session()
        let fd = feed(aArrivals: [jay + 180, jay + 500])
        drive(&s, from: t0, until: jay + 360, feed: fd) { ts in
            if let f = self.onTheF(ts) { return f }
            return Second(push: self.inRun(ts, [self.jay + 210, self.jay + 304]), steps: ts < self.jay + 4, shake: ts >= self.jay + 210 ? 0.04 : 0.005)
        }
        XCTAssertEqual(s.currentLeg, 1)
        XCTAssertTrue(s.onTrain)
        XCTAssertEqual(s.belief(leg: 1)?.bestTrain, "A_N|a1")
        XCTAssertEqual(s.rideDepartedTs(leg: 1) ?? 0, jay + 210, accuracy: 3)
    }

    // MARK: - staying on

    /// Staying on the F past Jay St, its pull-away felt: no change is called, and the stay-on is told by York St.
    func testStayingOnWithThePullAwayFeltIsAStayOn() {
        var s = session()
        let fd = feed(aArrivals: [jay + 100, jay + 400])
        drive(&s, from: t0, until: jay + 85, feed: fd) { ts in
            self.onTheF(ts) ?? Second(push: self.inRun(ts, [self.jay + 40]), shake: ts >= self.jay + 40 ? 0.04 : 0.005)
        }
        XCTAssertEqual(s.currentLeg, 0, "a push as the F pulled away from Jay St, and no A leaving then: not off by the timing")
        XCTAssertTrue(s.onTrain)
        drive(&s, from: jay + 85, until: jay + 200, feed: fd) { ts in
            Second(push: self.inRun(ts, [self.jay + 144, self.jay + 190]), shake: 0.04)
        }
        XCTAssertEqual(s.stayedOn?.key, "F_N")
        XCTAssertEqual(s.currentLeg, 0)
        XCTAssertTrue(s.onTrain)
    }

    /// Staying on the F with its pull-away from Jay St unfelt (the phone in the hand): the timing calls the change, then the
    /// F is felt running on to York St and East Broadway with no A leaving to explain it, so the change is struck and the
    /// rider stayed on.
    func testStayingOnWithThePullAwayUnfeltIsUndoneOnceTheFIsFeltRunningOn() {
        var s = session()
        let fd = feed(aArrivals: [jay + 300, jay + 600])
        drive(&s, from: t0, until: jay + 85, feed: fd) { ts in self.onTheF(ts) ?? Second(shake: 0.04) }
        XCTAssertEqual(s.currentLeg, 1, "nothing felt as the F left Jay St: the route's timing says off as planned")
        drive(&s, from: jay + 85, until: jay + 400, feed: fd) { ts in
            Second(push: self.inRun(ts, [self.jay + 144, self.jay + 190, self.jay + 324]), shake: 0.04)
        }
        XCTAssertEqual(s.currentLeg, 0, "the F was felt running on: the change is struck")
        XCTAssertTrue(s.onTrain)
        XCTAssertEqual(s.stayedOn?.key, "F_N")
        XCTAssertEqual(s.tracker?.timeline.events.map(\.kind), [.departed])
    }

    // MARK: - the rider's word

    /// Whatever the phone picked, the rider names the other A from every train that left, and it is the leg's train.
    func testTheRiderCanNameAnyAAfterThePhonePicked() {
        var s = session()
        let fd = feed(aArrivals: [jay + 60, jay + 150])
        drive(&s, from: t0, until: jay + 320, feed: fd) { ts in
            if let f = self.onTheF(ts) { return f }
            return Second(push: self.inRun(ts, [self.jay + 90, self.jay + 184]), steps: ts < self.jay + 4, shake: ts >= self.jay + 90 ? 0.04 : 0.005)
        }
        XCTAssertEqual(s.belief(leg: 1)?.bestTrain, "A_N|a1")
        let lag = PlatformTiming.recordedLag(route: "A")
        let a2 = BoardingCandidate(trainId: "A_N|a2", key: "A_N", route: "A", boardTs: jay + 150 + lag, alightTs: nil, stopsToAlight: 3, chosen: false, onLeg: true,
                                   boardIdx: 6, alightIdx: 9)
        s.setOnTrain(a2, now: jay + 320)
        XCTAssertEqual(s.belief(leg: 1)?.bestTrain, "A_N|a2")
        XCTAssertTrue(s.belief(leg: 1)?.byHand ?? false)
        XCTAssertEqual(s.currentLeg, 1)
        XCTAssertTrue(s.onTrain)
    }

    /// The rider says they stayed on, by naming the F from "On a train?" after the timing called the change: the ride is on
    /// the F by their word, and the route follows it along the line (`lineToFollow`), whatever the timing said.
    func testTheRiderCanSayTheyAreStillOnTheFAfterTheTimingCalledTheChange() {
        var s = session()
        let fd = feed(aArrivals: [jay + 300])
        drive(&s, from: t0, until: jay + 85, feed: fd) { ts in self.onTheF(ts) ?? Second() }
        XCTAssertEqual(s.currentLeg, 1)
        XCTAssertFalse(s.onTrain)
        let lag = PlatformTiming.recordedLag(route: "F")
        let f = BoardingCandidate(trainId: "F_N|f1", key: "F_N", route: "F", boardTs: jay + lag, alightTs: nil, stopsToAlight: nil, chosen: false, onLeg: false,
                                  boardIdx: 6, alightIdx: nil)
        s.setOnTrain(f, now: jay + 90)
        XCTAssertTrue(s.onTrain)
        XCTAssertEqual(s.belief(leg: 1)?.bestKey, "F_N")
        XCTAssertTrue(s.belief(leg: 1)?.byHand ?? false)
        XCTAssertEqual(s.lineToFollow(routeKeys: ["A_N"], now: jay + 90, lastSwitchTs: 0), "F_N", "the route follows the F on the rider's word")
    }

    // MARK: - the F held at Jay St (Nov 10: the F stood there for minutes while the rider crossed to the A)

    /// Off the held F in bursts of steps with pauses (a crowded car), onto the A a minute behind it: the walk-off counts at
    /// the route's change, and the A is the one that left after it.
    func testWalkingOffAHeldFInBurstsIsTheChange() {
        var s = session()
        let fd = feed(aArrivals: [jay + 60, jay + 400], fHeldTo: jay + 420)
        let bursts: [(Double, Double)] = [(80, 82), (85, 86), (88, 91), (94, 96), (99, 104), (107, 111), (114, 116)]
        drive(&s, from: t0, until: jay + 125, feed: fd) { ts in
            if let f = self.onTheF(ts) { return f }
            let r = ts - self.jay
            return Second(steps: bursts.contains { r >= $0.0 && r < $0.1 }, shake: 0.03)
        }
        XCTAssertEqual(s.currentLeg, 1, "steps in bursts at the route's change, the F standing there: off")
        drive(&s, from: jay + 125, until: jay + 330, feed: fd) { ts in
            Second(push: self.inRun(ts, [self.jay + 184, self.jay + 230]), shake: 0.04)
        }
        XCTAssertTrue(s.onTrain)
        XCTAssertEqual(s.belief(leg: 1)?.bestTrain, "A_N|a1")
        XCTAssertNil(s.stayedOn)
    }

    /// Two steps onto an A standing across the platform from the held F; its pull-away goes unfelt, then it is felt running
    /// (braking into High St, pulling out). The F has not moved: those pushes are the A's.
    func testPushesWhileTheFIsHeldAreTheConnection() {
        var s = session()
        let fd = feed(aArrivals: [jay - 10, jay + 400], fHeldTo: jay + 420)
        drive(&s, from: t0, until: jay + 240, feed: fd) { ts in
            if let f = self.onTheF(ts) { return f }
            return Second(push: self.inRun(ts, [self.jay + 114, self.jay + 160]), steps: ts < self.jay + 2, shake: ts >= self.jay + 20 ? 0.04 : 0.01)
        }
        XCTAssertEqual(s.currentLeg, 1)
        XCTAssertTrue(s.onTrain)
        XCTAssertEqual(s.belief(leg: 1)?.bestTrain, "A_N|a1")
    }

    /// Sitting on the held F while an A comes and goes: nothing pushes the phone, so the rider is still on the F.
    func testSittingOnTheHeldFIsNoChange() {
        var s = session()
        let fd = feed(aArrivals: [jay + 60, jay + 400], fHeldTo: jay + 360)
        drive(&s, from: t0, until: jay + 300, feed: fd) { ts in self.onTheF(ts) ?? Second(shake: 0.01) }
        XCTAssertEqual(s.currentLeg, 0)
        XCTAssertTrue(s.onTrain)
    }
}
