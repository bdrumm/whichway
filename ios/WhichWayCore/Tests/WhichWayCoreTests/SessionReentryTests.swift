import XCTest
@testable import WhichWayCore

/// "Not on train" crashed the app on every tap during a ride (Nov 12 twice, Nov 13; builds 202611092323 to 202611111119):
/// `RideSession.notOnTrain` called the planner's `changesOnTheWay` closure, which read `trip.currentLeg` back from the
/// `TripRecorder` that was holding the session for writing, and Swift traps on the overlapping access. The class: the
/// session calling out to the app in the middle of its own update. Now nothing it calls reads the app back, what it
/// needs from the planner comes in as a value with the call, and these tests drive every manual override from every
/// state the way the recorder does, with a host whose planner reads the session back as the real one does.
final class SessionReentryTests: XCTestCase {

    // MARK: - the network: F from 4 Av-9 St (0), Jay St (1, across the platform from the A), York St (2), W 4 St (3);
    // A from Hoyt (0), Jay St (1), High St (2), W 4 St (3), 14 St (4). The plan: F to W 4 St, a 3:00 walk, A to 14 St.

    private static func network() throws -> (ClientSchedule, StationIndex) {
        let json = """
        {"lines": {"F_N": {"stops": ["F23N","A41N","F18N","D20N"], "names": ["4 Av-9 St","Jay St-MetroTech","York St","W 4 St-Wash Sq"], "run_sec": [480, 90, 540]},
                   "A_N": {"stops": ["A42N","A41N","A40N","A32N","A31N"], "names": ["Hoyt-Schermerhorn Sts","Jay St-MetroTech","High St","W 4 St-Wash Sq","14 St"], "run_sec": [90, 120, 480, 120]}},
         "transfers": {"A41N": [{"line": "A_N", "stop": "A41N", "min_sec": 0}, {"line": "F_N", "stop": "A41N", "min_sec": 0}],
                       "D20N": [{"line": "A_N", "stop": "A32N", "min_sec": 180}],
                       "A32N": [{"line": "F_N", "stop": "D20N", "min_sec": 180}]}}
        """
        let sched = try JSONDecoder().decode(ClientSchedule.self, from: Data(json.utf8))
        return (sched, StationIndex(schedule: sched))
    }

    private static let t0 = 1000.0
    private static let legs = [LegPlan(keys: ["F_N"], idx: ["F_N": (from: 0, to: 3)], chosenKey: "F_N", chosenTrainId: nil),
                               LegPlan(keys: ["A_N"], idx: ["A_N": (from: 3, to: 4)], chosenKey: "A_N", chosenTrainId: nil)]

    /// The F the rider is on: at its platform at 1500 by the feed, at Jay St at `jay`, York St 2200 and W 4 St `w4`.
    private static func theF(jay: Double? = 1400 + 500, w4: Double = 2700) -> BoardingCandidate {
        var stopTs: [Int: Double] = [2: 2200, 3: w4]
        if let j = jay { stopTs[1] = j }
        return BoardingCandidate(trainId: "F_N|f1", key: "F_N", route: "F", boardTs: 1500, alightTs: w4, stopsToAlight: 3, chosen: true, onLeg: true,
                                 boardIdx: 0, alightIdx: 3, stopTs: stopTs, progressIdx: 1)
    }

    /// The A at W 4 St (stop 3) at `boardTs` by the feed, on to 14 St.
    private static func theA(boardTs: Double = 3000) -> BoardingCandidate {
        BoardingCandidate(trainId: "A_N|a1", key: "A_N", route: "A", boardTs: boardTs, alightTs: boardTs + 600, stopsToAlight: 1, chosen: true, onLeg: true,
                          boardIdx: 3, alightIdx: 4, stopTs: [4: boardTs + 600], progressIdx: 4)
    }

    /// The recorder and the planner as the app has them: the recorder holds the session; the planner's list of changes
    /// reads the recorder's session back (`PlannerView.changesOnTheWayNow` reads `trip.currentLeg` and
    /// `trip.rideTrain`). Each override goes through the host as `TripRecorder` sends it.
    private final class Host {
        var session = RideSession()
        let planned: PathOption, all: [PathOption], index: StationIndex
        var now = SessionReentryTests.t0

        init() throws {
            let (sched, index) = try SessionReentryTests.network()
            self.index = index
            all = enumeratePaths(schedule: sched, index: index, from: index.stationOf("F23N"), to: index.stationOf("A31N"), maxOptions: 24)
            planned = try XCTUnwrap(all.first { $0.transfer?.station == "W 4 St-Wash Sq" })
            // the session's own closures: lookups that never read the host back (see `RideSession.stopCoordinate`)
            session.stopCoordinate = { _, _ in nil }
            session.linePrior = { _, _, _, _, _ in nil }
            let start = TripTimeline(startTs: t0, startedBy: "gps", startDistanceM: 20, placeId: nil, originStation: "F23", destStation: "A31",
                                     transferStation: "W 4 St-Wash Sq", legs: 2)
            session.begin(start, distanceToOriginM: 20, legs: SessionReentryTests.legs, now: t0)
        }

        /// The planner's `changesOnTheWayNow`: reads the session back.
        func plannerChanges() -> [EarlyChange] {
            guard session.currentLeg == 0 else { return [] }
            let keys = session.rideTrain.map { [$0.key] } ?? planned.legs[0].keys
            return keys.flatMap { WhichWayCore.changesOnTheWay(from: planned, ridingKey: $0, among: all, index: index) }
        }

        // `TripRecorder`'s calls, in its order: anything read from the planner first, then the session.
        func notOnTrain() { let ch = plannerChanges(); session.notOnTrain(now: now, changes: ch) }
        func setOnTrain(_ c: BoardingCandidate) { session.setOnTrain(c, now: now) }
        func tick() { session.tick(now: now) }
        func still(_ n: Int, push: Bool = false, shake: Bool = false, steps: Bool = false) {
            for _ in 0..<n {
                session.motion(MotionSecond(ts: now, stepEnergy: steps ? 0.05 : 0.002, pushG: push ? 0.08 : 0.005, shakeG: push ? 0.03 : (shake ? 0.04 : 0.005)))
                if Int(now) % 5 == 0 { session.tick(now: now) }
                now += 1
            }
        }
        var jay: EarlyChange? { WhichWayCore.changesOnTheWay(from: planned, ridingKey: "F_N", among: all, index: index).first { $0.stationName == "Jay St-MetroTech" } }

        var legsRidden: Int { session.tracker?.timeline.legsRidden ?? 0 }
        var kinds: [MotionEvent.Kind] { session.tracker?.timeline.events.map(\.kind) ?? [] }
        var taps: Int { session.tracker?.timeline.notOnTrainTaps?.count ?? 0 }
    }

    // MARK: - the states "Not on train" can be tapped from

    /// Each state a route in progress can be in when the rider reaches for a manual override.
    private enum State: String, CaseIterable {
        case atPlatform          // started, nothing ridden
        case pullAwayFelt        // a pull-away felt, the feed not yet heard ("Boarding?")
        case namedByHand         // on the F, named by hand
        case reachedEarlierChange // on the F, which has reached Jay St (a change short of the plan's)
        case pastPlannedStop     // on the F, which has reached W 4 St (the plan's change)
        case betweenTrains       // off the F at W 4 St, the A not boarded
        case onSecondLeg         // on the A
        case ended               // the route over
    }

    private func host(in state: State) throws -> Host {
        let h = try Host()
        switch state {
        case .atPlatform:
            h.still(30)
        case .pullAwayFelt:
            h.still(30); h.still(6, push: true); h.still(60, shake: true)
        case .namedByHand:
            h.now = 1600; h.setOnTrain(Self.theF(jay: nil)); h.now = 1700
        case .reachedEarlierChange:
            h.now = 1600; h.setOnTrain(Self.theF(jay: 1900)); h.now = 2050
        case .pastPlannedStop:
            h.now = 1600; h.setOnTrain(Self.theF(jay: 1900, w4: 2700)); h.now = 2800
        case .betweenTrains:
            h.now = 1600; h.setOnTrain(Self.theF(jay: 1900, w4: 2700)); h.now = 2800
            h.notOnTrain()           // off at W 4 St, unfelt
            h.now = 2850
        case .onSecondLeg:
            h.now = 1600; h.setOnTrain(Self.theF(jay: 1900, w4: 2700)); h.now = 2800
            h.notOnTrain()
            h.now = 3050; h.setOnTrain(Self.theA(boardTs: 3000)); h.now = 3100
        case .ended:
            h.now = 1600; h.setOnTrain(Self.theF(jay: nil)); h.now = 1700
            _ = h.session.end(by: "hand", now: h.now)
        }
        return h
    }

    // MARK: - "Not on train", state by state, end to end to the leg in hand

    func testNotOnTrainAtThePlatformBeforeAnyRideChangesNothing() throws {
        let h = try host(in: .atPlatform)
        h.notOnTrain()
        XCTAssertFalse(h.session.onTrain)
        XCTAssertEqual(h.legsRidden, 0)
        XCTAssertEqual(h.kinds, [])
        XCTAssertEqual(h.taps, 1, "kept on the record whatever it changed")
    }

    func testNotOnTrainOnAFeltPullAwayWithdrawsIt() throws {
        let h = try host(in: .pullAwayFelt)
        XCTAssertEqual(h.kinds, [.departed], "the pull-away is on the record")
        h.notOnTrain()
        XCTAssertFalse(h.session.onTrain)
        XCTAssertEqual(h.kinds, [], "the pull-away that was not a train is withdrawn")
        XCTAssertEqual(h.legsRidden, 0)
        XCTAssertEqual(h.session.currentLeg, 0)
    }

    func testNotOnTrainOnATrainNamedByHandSendsTheLegBackToThePlatform() throws {
        let h = try host(in: .namedByHand)
        XCTAssertTrue(h.session.onTrain)
        h.notOnTrain()
        XCTAssertFalse(h.session.onTrain)
        XCTAssertEqual(h.kinds, [])
        XCTAssertEqual(h.legsRidden, 0)
        XCTAssertNil(h.session.rideTrain, "the F is no longer the train in hand")
    }

    /// The crash itself: the planner's list is read from the train in hand, and the change it names is taken.
    func testNotOnTrainOnceTheTrainHasReachedAnEarlierChangeIsTheChangeThere() throws {
        let h = try host(in: .reachedEarlierChange)
        XCTAssertEqual(h.session.rideTrain?.trainId, "F_N|f1")
        XCTAssertFalse(h.plannerChanges().isEmpty, "the planner names the changes off the F")
        h.notOnTrain()
        XCTAssertFalse(h.session.onTrain, "off the F")
        XCTAssertEqual(h.legsRidden, 1, "the F ride closed at Jay St")
        XCTAssertEqual(h.kinds, [.departed, .alighted])
        XCTAssertEqual(h.session.changedEarly?.change.stationName, "Jay St-MetroTech", "the planner follows the change at Jay St")
        XCTAssertEqual(h.session.currentLeg, 1, "the next leg is the one in hand")
    }

    func testNotOnTrainOnceTheTrainHasReachedThePlannedChangeIsTheAlightingThere() throws {
        let h = try host(in: .pastPlannedStop)
        h.notOnTrain()
        XCTAssertFalse(h.session.onTrain)
        XCTAssertEqual(h.legsRidden, 1)
        XCTAssertEqual(h.kinds, [.departed, .alighted])
        XCTAssertNil(h.session.changedEarly, "off at the plan's own change: the plan stands")
        XCTAssertEqual(h.session.tracker?.timeline.events.last?.ts ?? 0, PlatformTiming.atPlatform(2700, route: "F"), accuracy: 1)
    }

    func testNotOnTrainBetweenTrainsLeavesTheChangeAsItIs() throws {
        let h = try host(in: .betweenTrains)
        h.notOnTrain()
        XCTAssertFalse(h.session.onTrain)
        XCTAssertEqual(h.legsRidden, 1, "the F ride stands")
        XCTAssertEqual(h.kinds, [.departed, .alighted])
        XCTAssertEqual(h.session.currentLeg, 1)
    }

    func testNotOnTrainOnTheSecondLegSendsItBackToTheChangePlatform() throws {
        let h = try host(in: .onSecondLeg)
        XCTAssertTrue(h.session.onTrain)
        XCTAssertEqual(h.kinds, [.departed, .alighted, .departed])
        h.notOnTrain()
        XCTAssertFalse(h.session.onTrain)
        XCTAssertEqual(h.kinds, [.departed, .alighted], "the A withdrawn, the F ride kept")
        XCTAssertEqual(h.legsRidden, 1)
        XCTAssertEqual(h.session.currentLeg, 1, "waiting for the A at W 4 St, not back at 4 Av-9 St")
    }

    func testNotOnTrainAfterTheRouteEndedDoesNothing() throws {
        let h = try host(in: .ended)
        h.notOnTrain()
        XCTAssertNil(h.session.tracker)
        XCTAssertFalse(h.session.onTrain)
    }

    func testNotOnTrainTwiceInARowIsSafe() throws {
        for state in State.allCases {
            let h = try host(in: state)
            h.notOnTrain()
            let kinds = h.kinds, legs = h.legsRidden
            h.notOnTrain()
            XCTAssertLessThanOrEqual(h.legsRidden, max(legs, 1), "\(state): a second tap never rides a leg")
            XCTAssertTrue(h.kinds.count <= kinds.count + 1, "\(state)")
        }
    }

    /// The other half of the user-control rule: after "Not on train", naming a train by hand still works.
    func testATrainNamedByHandAfterNotOnTrainIsBoarded() throws {
        for state in [State.pullAwayFelt, .namedByHand, .reachedEarlierChange, .onSecondLeg] {
            let h = try host(in: state)
            h.notOnTrain()
            h.now += 60
            let c = h.session.currentLeg == 0 ? Self.theF(jay: nil) : Self.theA(boardTs: h.now - 30)
            h.setOnTrain(c)
            XCTAssertTrue(h.session.onTrain, "\(state): the train named by hand is ridden")
            XCTAssertEqual(h.session.rideTrain?.trainId, c.trainId, "\(state)")
        }
    }

    // MARK: - every manual override, from every state

    private typealias Override = (name: String, run: (Host) -> Void)

    private func overrides(_ h: Host) -> [Override] {
        [("notOnTrain", { $0.notOnTrain() }),
         ("setOnTrain F", { $0.setOnTrain(Self.theF(jay: nil)) }),
         ("setOnTrain A", { $0.setOnTrain(Self.theA(boardTs: $0.now - 30)) }),
         ("confirm F", { $0.session.confirm(trainId: "F_N|f1") }),
         ("confirmBoarding", { $0.session.confirmBoarding() }),
         ("setBoardedByHand F", { $0.session.setBoardedByHand(key: "F_N") }),
         ("setBoardedByHand A", { $0.session.setBoardedByHand(key: "A_N") }),
         ("dismissPrompt", { $0.session.dismissPrompt() }),
         ("takeChange Jay", { h in if let j = h.jay { h.session.takeChange(j, alightTs: h.now - 30, now: h.now) } }),
         ("takeChange Jay waiting", { h in if let j = h.jay { h.session.takeChange(j, alightTs: h.now - 30, now: h.now, waiting: true) } }),
         ("takeEarlyChange", { $0.session.takeEarlyChange(now: $0.now) }),
         ("replan", { $0.session.replan(legs: SessionReentryTests.legs, transferStation: "W 4 St-Wash Sq") }),
         ("seedCurrentLeg", { $0.session.seedCurrentLeg([Self.theF(jay: nil)], now: $0.now) }),
         ("noteDev", { _ = $0.session.noteDev("test", via: "app", at: $0.now) }),
         ("endByHand", { $0.session.endByHand(now: $0.now) })]
    }

    func testEveryManualOverrideFromEveryStateKeepsTheRouteWhole() throws {
        for state in State.allCases {
            for o in overrides(try Host()) {
                let h = try host(in: state)
                o.run(h)
                // then the route goes on: the clock, the sensors and another tap
                h.now += 30; h.tick(); h.still(10)
                h.notOnTrain()
                let kinds = h.kinds
                XCTAssertTrue(kinds.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 0 ? .departed : .alighted) },
                              "\(state) / \(o.name): rides and alightings alternate, \(kinds)")
                XCTAssertTrue((0...2).contains(h.legsRidden), "\(state) / \(o.name): \(h.legsRidden) legs ridden")
                XCTAssertTrue((0...2).contains(h.session.currentLeg), "\(state) / \(o.name): leg \(h.session.currentLeg)")
            }
        }
    }

    // MARK: - the class: what the session can call while it updates

    /// Every closure the session holds, anywhere in it. The session calls these in the middle of its updates, while the
    /// app holds it for writing, so each must be a lookup that never reads the app's session back (Nov 12-13). A new
    /// one fails here: hand the value in with the call instead, or add it below once it is known not to read back.
    func testTheSessionHoldsOnlyClosuresThatDoNotReadTheAppBack() {
        var s = RideSession()
        s.stopCoordinate = { _, _ in nil }
        s.linePrior = { _, _, _, _, _ in nil }
        let start = TripTimeline(startTs: Self.t0, startedBy: "gps", startDistanceM: 20, placeId: nil, originStation: "F23", destStation: "A31",
                                 transferStation: "W 4 St-Wash Sq", legs: 2)
        s.begin(start, distanceToOriginM: 20, legs: Self.legs, now: Self.t0)
        s.setOnTrain(Self.theF(jay: nil), now: 1600)
        var found = Set<String>()
        func walk(_ v: Any, _ path: String, depth: Int) {
            guard depth < 8 else { return }
            let m = Mirror(reflecting: v)
            if m.displayStyle == .optional { if let c = m.children.first { walk(c.value, path, depth: depth) }; return }
            if "\(type(of: v))".contains("->") { found.insert(path); return }
            for c in m.children {
                let name = c.label.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 } ?? "[]"
                walk(c.value, path.isEmpty ? name : "\(path).\(name)", depth: depth + 1)
            }
        }
        walk(s, "", depth: 0)
        XCTAssertEqual(found, ["stopCoordinate", "linePrior", "inference.recordedLag"],
                       "a closure the session calls mid-update must not read the app back; hand values in with the call")
    }
}
