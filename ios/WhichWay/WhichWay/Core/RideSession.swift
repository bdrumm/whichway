import Foundation

/// One leg of the plan, as the line inference needs it: the lines the leg can use and where it boards and alights
/// on each, the train and line the plan picked, and the other lines at the boarding platform in the same
/// direction (a train the rider could board by mistake, or on purpose).
struct LegPlan {
    var keys: [String]
    var idx: [String: (from: Int, to: Int)]
    var chosenKey: String?
    var chosenTrainId: String?
    var platformKeys: [String: Int] = [:]     // other same-direction lines at the platform -> their boarding stop index
    var origin: String = ""                   // the trip, for the rider's own history of lines taken on it
    var dest: String = ""
    var walkSec: Double = 0                   // the walk before boarding this leg (0: the first leg, or a same-platform change)
    var otherPlatformKeys: Set<String> = []   // of platformKeys, those boarding at another platform of the station (the 8 Av L beside the A/C/E)
    /// Per line other than the plan's, how well it suits the trip (`platformLineFit`: one that reaches the destination
    /// or the change outweighs one that leads away), times the rider's own habits on this trip when there are any. The
    /// line prior scales each line's weight by it; a line missing is 1.
    var lineFit: [String: Double] = [:]
}

/// What the Go tab asks the rider when the phone is not sure which train they boarded, or believes they boarded a
/// train off the plan, or has only assumed the ride from the schedule.
/// The rider walked off the train somewhere else than the plan's change or destination: the stop on the line they
/// were on, by that train's own times. The planner re-routes from there.
struct OffPlanAlighting: Equatable {
    var leg: Int
    var key: String
    var stopIdx: Int
    var ts: Double
}

/// The rider stayed on past the stop where the route had them change (or get off): the train the phone believes
/// they are on has gone on beyond it, by the feed, and no walk-off was felt. The planner re-routes along that line.
struct StayedOn: Equatable {
    var leg: Int
    var key: String
    var trainId: String
    var pastIdx: Int          // the stop they were to leave the train at, on `key`
    var ts: Double
}

/// The rider says they changed at a station short of the route's own change (`EarlyChange`): the ride closed there
/// at `alightTs`; the planner adopts the route that changes there and boards the rider on its connection.
struct ChangedEarly: Equatable {
    var change: EarlyChange
    var alightTs: Double
    var ts: Double
    /// Read from "not on the train": the rider is on the platform at the change, so no train that left before is theirs.
    var waiting = false
}

struct BoardingPrompt: Equatable {
    enum Reason: String { case unsure, switched, assumed }
    var leg: Int
    var reason: Reason
    var candidates: [BoardingCandidate]   // the trains that were at the platform, by time
    var bestTrainId: String?
    var bestKey: String?
    var chosenKey: String?
}

/// The decisions of a route in progress, apart from the phone: the motion seconds, the location fixes, the feed's boards
/// and the clock go into the trip tracker and the departure logs, and out come the legs ridden, whether the rider is on a
/// train, which train each leg was, and the hand-offs between them (a change felt, unfelt, named, or read from "not on
/// the train"). `TripRecorder` is its thin caller on the phone (the sensors, the disk, the Live Activity); the package
/// tests drive it from the tracker's events to the leg in hand, scenario by scenario (CLAUDE.md, transfers rule 2).
struct RideSession {
    /// Per leg, what the phone believes about the train the rider boarded, as far as the evidence has got.
    private(set) var beliefs: [LineBelief] = []
    /// Set when the rider walked off at a stop the route did not plan to leave the train at.
    private(set) var offPlanAlighting: OffPlanAlighting?
    /// Set when the rider rode on past the stop the route had them leave the train at.
    private(set) var stayedOn: StayedOn?
    private var stayedOnChecked: Set<Int> = []
    /// The walk-off at the change told from the route's timing alone (the train left it, nothing pushed the phone): kept
    /// until the train in hand reaches the stops beyond, so a stay-on felt by then can undo it (`checkOffByTiming`).
    private var offByTiming: (leg: Int, trainId: String, key: String, pastIdx: Int, atStopTs: Double)?
    /// A walk-off told after the fact (at `offTs`, told at `toldTs`): the detector stood down only then, so a pull-away it
    /// feels soon after may be a connection the rider was already on (`handleEvents`).
    private var lateOff: (leg: Int, offTs: Double, toldTs: Double)?
    /// Legs whose departure was moved back to a connection that had already left (`lateOff`), with that moment: the first
    /// push felt after it still has to fit that train, not another one leaving the platform (`checkMovedBack`).
    private var movedBack: [Int: Double] = [:]
    /// The change short of the route's own on offer right now (the planner sets it from the train in hand), with when
    /// the rider would have stepped off there: the trip bar and the Live Activity show it as one tap.
    private(set) var earlyChange: (change: EarlyChange, alightTs: Double)?
    /// Set when the rider took the offer: the planner follows (`ChangedEarly`).
    private(set) var changedEarly: ChangedEarly?
    private(set) var tracker: TripTracker?
    private(set) var legs: [LegPlan] = []
    private var log = DepartureLog()
    private var transferLog = DepartureLog()     // the next leg's lines at the transfer platform, followed during this leg
    private var prevLog = DepartureLog()         // the leg before's lines at its platform, still followed: a ride found not to be one is read again there
    private var logLeg = -1
    private var candidates: [Int: [BoardingCandidate]] = [:]
    private var departedTs: [Int: Double] = [:]
    /// Legs whose felt pull-away the motion has not confirmed yet (pushes after it, `RideContinuity.pendingRide`): read
    /// against it at every poll, whatever the feed said, until it does or the ride is taken back.
    private var motionUnconfirmed: Set<Int> = []
    private var departureBeliefs: [Int: LineBelief] = [:]   // per leg, the belief at the departure, before the ride's evidence
    private var lastAlight: (leg: Int, ts: Double)?
    private var locationApplied: Set<Int> = []
    var inference = LineInference()
    var continuity = RideContinuity()
    private var seenEvents = 0
    private var handSet: Set<Int> = []
    private var dismissed: Set<Int> = []
    private var departureChecked: Set<Int> = []
    private var locationRides: Set<Int> = []      // legs whose ride began from the phone's movement, not a felt pull-away
    /// Legs whose ride the session presumed: the plan's train left the rider's platform by the feed and no pull-away was
    /// felt (`presumeBoarding`). Kept with `locationRides` out of the felt pull-away's checks.
    private var presumedRides: Set<Int> = []
    /// Trains the rider said they were not on after the session presumed them boarded: never presumed again.
    private var presumeDeclined: Set<String> = []
    /// The plan's train is presumed boarded only when it left the platform no longer ago than this (a look-back over
    /// the polls since, not a ride begun for a train long gone).
    var presumeLookBackSec = 600.0
    /// The latest moment the session has been told of (a tick, a poll): "now" for the rider's taps.
    private(set) var lastNow: Double?

    init(stopCoordinate: ((String, Int) -> (lat: Double, lon: Double)?)? = nil,
         linePrior: ((_ plan: LegPlan, _ leg: Int, _ chosenKey: String, _ timeline: TripTimeline, _ ts: Double) -> Double?)? = nil) {
        self.stopCoordinate = stopCoordinate
        self.linePrior = linePrior
    }
    /// A felt pull-away is checked against the feed this long after: time for a train that left then to show as gone.
    var departureCheckSec = 100.0
    /// The feed is polled about this often: a train it had standing at a stop stood there up to this long either side.
    var pollGapSec = 30.0
    /// A ride this short with no station stop felt is the first one taken back when the phone has counted a ride too many.
    var phantomRideMaxSec = 180.0
    /// Standing this long at a station, with the believed train gone past it, on a same-platform change: off the train.
    var samePlatformStandSec = 90.0
    /// Walking this long, with the steps begun while the believed train stood at a station by the feed: off the train.
    var quickChangeWalkSec = 8
    /// How far from the train's moment at the platform the steps may begin and still be the rider stepping off: a
    /// little before (the feed's time is an estimate), and up to the doors closing after.
    var quickChangeBeforeSec = 45.0
    var quickChangeAfterSec = 75.0
    /// A walk-off told this long after the moment it is put at was told late (`lateOff`).
    var lateOffSec = 20.0
    /// A pull-away felt this soon after a late walk-off was the phone already moving with a train when it was told.
    var lateOffDepartureSec = 45.0
    /// The least time from stepping off to a connection pulling away with the rider on it (a step onto a train standing there).
    var stepOnSec = 5.0
    // The closures below are the only ways the session reaches outside itself, and it calls them in the middle of its
    // own updates, while the app holds the session for writing. So each is a lookup that gets everything it needs in
    // its arguments and never reads the app's session (the TripRecorder, the planner's trip state) back: a closure
    // that did crashed the app on every "Not on train" tap during a ride (Nov 12-13, builds 202611092323 on, the
    // planner's `changesOnTheWay` read `trip.currentLeg` from inside `notOnTrain`; Swift traps on the overlapping
    // access). What the session needs from the planner comes in as a value with the call (`notOnTrain(changes:)`).
    // `SessionReentryTests` lists these closures and fails when a new one is added.
    /// Position of a stop on a line (line key, stop index), from the published geometry; set by the planner.
    var stopCoordinate: ((String, Int) -> (lat: Double, lon: Double)?)?
    /// The rider's own share for the plan's line on a leg (what they rode on this trip before, else the line they usually
    /// board at that platform at that hour): the phone's history, handed in by the caller. Nil: no history.
    var linePrior: ((_ plan: LegPlan, _ leg: Int, _ chosenKey: String, _ timeline: TripTimeline, _ ts: Double) -> Double?)?

    /// The belief about the ride in progress, or the last one.
    /// Between trains at the change, none: the train just left is not the one in hand (Oct 21 at W 4 St, "not on the
    /// train" there read as back on the F).
    var currentBelief: LineBelief? {
        guard let t = tracker, t.phase == .riding else { return beliefs.last }
        return t.onTrain ? belief(leg: t.timeline.legsRidden) : nil
    }
    func belief(leg: Int) -> LineBelief? { beliefs.first { $0.leg == leg } }
    /// The question for the rider, if there is one: the phone is unsure which train they boarded, believes they
    /// boarded one off the plan, or has only assumed the ride. Gone once they answer or wave it away.
    var prompt: BoardingPrompt? {
        guard let t = tracker, t.phase == .riding else { return nil }
        let leg = t.timeline.legsRidden
        guard leg < legs.count, !handSet.contains(leg), !dismissed.contains(leg), let b = belief(leg: leg) else { return nil }
        let reason: BoardingPrompt.Reason
        if b.assumed { reason = .assumed }
        else if !b.settled { reason = .unsure }
        else if b.verdict == .switched { reason = .switched }
        else { return nil }
        let cands = candidates[leg] ?? []
        return BoardingPrompt(leg: leg, reason: reason, candidates: cands, bestTrainId: b.bestTrain, bestKey: b.bestKey, chosenKey: legs[leg].chosenKey)
    }

    /// Riding with no idea which train (the tracker put the rider on a train from their movement, with no
    /// departure the feeds could match): the rider should be asked, once.
    var needsTrainPick: Bool {
        guard let t = tracker, t.phase == .riding else { return false }
        let leg = t.timeline.legsRidden
        return belief(leg: leg) == nil && (candidates[leg] ?? []).isEmpty && !dismissed.contains(leg) && !handSet.contains(leg)
    }

    /// On a train right now (not on the way, at the platform, or between trains at the change).
    var onTrain: Bool { tracker?.onTrain ?? false }
    /// On a train as the rider is shown it: a felt pull-away the feed has not backed yet shows as boarding, not riding.
    var onTrainShown: Bool { tracker?.onTrainShown ?? false }
    /// The line the route should switch to on the leg in hand, if the train the rider is on is not one of the route's
    /// lines there (`routeKeys`): the rider's own word at once; the phone's own guess only once it is sure (settled and
    /// at least `confidence`), once the ride is backed (a pull-away still waiting on the feed or the motion is a claim:
    /// Nov 5 at 4 Av-9 St switched to the G, then to the F via W 4 St, on a train the rider never boarded), and at most
    /// once every `minGapSec`. Nil leaves the route as it is.
    func lineToFollow(routeKeys: [String], now: Double, lastSwitchTs: Double, confidence: Double = 0.75, minGapSec: Double = 60) -> String? {
        guard let t = tracker, t.phase == .riding, let b = belief(leg: currentLeg), let key = b.bestKey, !routeKeys.contains(key) else { return nil }
        if b.byHand { return key }
        guard t.onTrainShown, b.settled, b.confidence >= confidence, now - lastSwitchTs >= minGapSec else { return nil }
        return key
    }
    /// Ten-metre fixes wanted now (`TripTracker.needsPreciseFixes`); with no route in progress, the app's own default.
    func needsPreciseFixes(now: Double) -> Bool { tracker?.needsPreciseFixes(now: now) ?? true }

    /// A faster route on offer, for the trip's record.
    mutating func noteReroute(_ n: RerouteNote) { tracker?.noteReroute(n) }

    /// When the ride on leg `leg` began: the felt (or named) pull-away, nil for one assumed from the timetable.
    func rideDepartedTs(leg: Int) -> Double? { tracker?.ride(leg)?.departedTs }

    /// The leg in hand (legs ridden so far) and the lines the route allows on it, for the rider's own say.
    var currentLeg: Int { tracker?.timeline.legsRidden ?? 0 }
    var currentLegKeys: [String] { currentLeg < legs.count ? legs[currentLeg].keys : [] }
    var currentLegChosenKey: String? { currentLeg < legs.count ? legs[currentLeg].chosenKey : nil }

    mutating func begin(_ start: TripTimeline, distanceToOriginM: Double?, legs: [LegPlan] = [], now: Double, firstRunSec: Double? = nil) {
        tracker = TripTracker(start, distanceToOriginM: distanceToOriginM)
        // steps sooner after a felt pull-away than most of the scheduled run to the first stop are not a ride
        if let r = firstRunSec { tracker?.minRideSec = max(45, 0.6 * r) }
        self.legs = legs
        log.reset(); transferLog.reset(); prevLog.reset(); logLeg = -1; candidates = [:]; beliefs = []; seenEvents = 0; handSet = []; dismissed = []
        departureBeliefs = [:]; departedTs = [:]; lastAlight = nil; locationApplied = []; departureChecked = []; offPlanAlighting = nil
        stayedOn = nil; stayedOnChecked = []; locationRides = []; presumedRides = []; presumeDeclined = []; earlyChange = nil; changedEarly = nil; lastNow = now
        offByTiming = nil; lateOff = nil; movedBack = [:]
    }

    /// One summarised second of motion.
    mutating func motion(_ m: MotionSecond) {
        tracker?.motion(m)
        checkQuickChange()
        handleEvents()
        if let k = tracker?.takeAmendedRide() { departureMoved(ride: k) }
    }

    /// The departure of ride `k` moved to the train's own pull-away: the trains are read again against it (the rider's
    /// word stands; only its train is looked up again).
    private mutating func departureMoved(ride k: Int) {
        guard let t = tracker, let r = t.ride(k), k < legs.count else { return }
        departureChecked.remove(k)
        departedTs[k] = r.departedTs
        reread(k)
    }

    /// The trains in `lg` that could have made the pull-away felt on leg `leg`, less the one the rider walked off at the
    /// change before it (`excludingTrainLeft`): the train the phone settled on for the leg before, once that ride ended.
    private mutating func legCandidates(_ lg: DepartureLog, leg: Int, departedTs: Double) -> [BoardingCandidate] {
        let cands = lg.candidates(departedTs: departedTs, windowSec: inference.departureWindowSec, chosenTrainId: legs[leg].chosenTrainId)
        guard leg >= 1, tracker?.ride(leg - 1)?.alightedTs != nil, let prev = belief(leg: leg - 1), prev.settled || prev.byHand else { return cands }
        return excludingTrainLeft(cands, leftTrainId: prev.bestTrain)
    }

    /// A departure that matched no train in the feed (the route started a few seconds before it, before any poll; Oct 13
    /// at 14 St, 14 s), or a line named by hand with no train to it: read again once the polls bring trains in.
    private mutating func rereadUnmatched() {
        guard let t = tracker, t.phase == .riding else { return }
        let leg = t.timeline.legsRidden
        // a ride presumed from the plan's train leaving stays the plan's train, shown as presumed, until the rider says
        guard leg < legs.count, !presumedRides.contains(leg), let dep = departedTs[leg] ?? t.ride(leg)?.departedTs, let b = belief(leg: leg),
              (b.evidence == ["plan"]) || (b.byHand && b.bestTrain == nil) else { return }
        let cands = legCandidates(log, leg: leg, departedTs: dep)
        guard !cands.isEmpty else { return }
        departedTs[leg] = dep
        reread(leg)
    }

    /// A walk that began while the train the phone believes the rider is on stood at a station, by the feed's
    /// times for its stops: the rider stepping off, even though the detector did not see the train come to rest
    /// first (people boarding keep a standing train shaking; a rider heading for the doors keeps the phone moving).
    /// Oct 8: both changes across the platform at Jay St were 11 to 12 s walks the detector let pass.
    private mutating func checkQuickChange() {
        guard let t = tracker, t.phase == .riding, let dep = t.timeline.events.last, dep.kind == .departed, let c = trainInHand else { return }
        let lag = PlatformTiming.recordedLag(route: c.route)
        func standing(_ idx: Int, at ts: Double) -> Bool {
            if let feedTs = c.stopTs[idx], ts >= feedTs - lag - quickChangeBeforeSec, ts <= feedTs - lag + quickChangeAfterSec { return true }
            // or the feed had it standing at the stop then, between polls (a held train's time at the stop is when it leaves)
            return c.stoodAt[idx].map { ts >= $0.from - pollGapSec && ts <= $0.to + pollGapSec } ?? false
        }
        // steps this soon after the pull-away are boarding or the platform, not a ride over (Oct 21 at W 4 St: a pull-away
        // at 9:42:16 and steps at 9:42:28 ended the trip there, read as the E already at 14 St)
        if let walk = t.walking, walk.seconds >= quickChangeWalkSec, walk.startTs - dep.ts >= t.minRideSec,
           c.stopTs.keys.contains(where: { $0 > c.boardIdx && standing($0, at: walk.startTs) }) || c.stoodAt.keys.contains(where: { standing($0, at: walk.startTs) }) {
            tracker?.alightWalking(at: walk.startTs)
            return
        }
        // at the stop the route leaves the train at, steps in bursts count too: getting off there is the plan, and off a
        // crowded train the walk stops and starts (Nov 10 at Jay St, off the F held there)
        if let walk = t.brokenWalk, walk.seconds >= quickChangeWalkSec, walk.startTs - dep.ts >= t.minRideSec, let past = c.alightIdx,
           standing(past, at: walk.startTs) {
            tracker?.alightWalking(at: walk.startTs)
        }
    }

    /// The believed train has gone on past the stop the route had the rider leave it at, and no walk-off was felt.
    /// The route is the prior there: the rider got off as planned (a step across the platform, a train standing
    /// there: nothing the sensors feel) unless the phone felt the train run on to the stop beyond (`RideContinuity`).
    /// Run on: the rider stayed on, told once per leg, and the planner re-routes along the line (the A on to Jay St
    /// for the F rather than the F from W 4 St). Not: the ride closes at the planned stop, at the train's moment
    /// there, and the route goes on from the change; where the pushes began with the route's own connection pulling
    /// away, the rider is on it. Platform shaking no longer counts as riding on (Nov 9 at Jay St: three minutes on
    /// the platform, read as still on the F, and the route moved to W 4 St under the rider).
    ///
    /// The route's timing decides it as soon as it can: once the feed has the train leaving the stop and nothing has
    /// pushed the phone since it got there, the rider is off now, not when the train reaches the stop beyond (Nov 10 at
    /// Jay St: the countdown ran out and the phone kept the rider on the F for minutes, then dated the A from then).
    private mutating func checkStayedOn(now: Double) {
        guard let t = tracker, t.phase == .riding, t.sensing else { return }
        let leg = t.timeline.legsRidden
        guard !stayedOnChecked.contains(leg), t.timeline.events.last?.kind == .departed, let c = trainInHand, let past = c.alightIdx,
              let progress = c.progressIdx else { return }
        let lag = PlatformTiming.recordedLag(route: c.route)
        // when it reached the stop: the feed's time there, or the first poll that had it standing there when that is sooner
        // (a held train keeps republishing its time at the stop as the moment it will leave)
        guard let atStop = [(c.stopTs[past] ?? c.alightTs).map({ $0 - lag }), c.stoodAt[past]?.from].compactMap({ $0 }).min(),
              let dep = departedTs[leg] ?? t.ride(leg)?.departedTs, atStop > dep else { return }
        let hasNext = leg + 1 < legs.count
        guard progress > past else {
            if hasNext { checkLeftStandingTrain(c, past: past, atStop: atStop, now: now) }
            return
        }
        let later = c.stopTs.filter { $0.key > past }.sorted { $0.key < $1.key }.map { $0.value - lag }
        let connections = hasNext ? transferLog.pullAways() : []
        let left = hasNext ? transferLog.pullAwaySpans() : []
        // when it left the stop, by the feed: after the last poll that had it standing there, else its moment there and a dwell
        let leaves = c.stoodAt[past].map { $0.to + pollGapSec } ?? atStop + PlatformTiming.dwellSec
        // the rider's own moving about on the platform pushes the phone too: only pushes clear of steps are a train's
        switch continuity.pastStop(atStopTs: atStop, laterStopTs: later, pushTimes: t.pushRunsClear, connectionPullAways: connections, connectionLeft: left,
                                   connectionWindows: hasNext ? transferLog.departureWindows() : [], trainWindow: leaveWindow(c, past: past, atStop: atStop),
                                   trainLeavesTs: leaves, now: now) {
        case .waiting:
            return
        case .stayedOn:
            stayedOnChecked.insert(leg)
            stayedOn = StayedOn(leg: leg, key: c.key, trainId: c.trainId, pastIdx: past, ts: now)
        case let .steppedOff(at):
            // told before the train reached the stop beyond: the timing's call, which a stay-on felt by then can still undo
            let byTiming = !later.contains { $0 > atStop && $0 + continuity.settleSec <= now }
            alightLate(at: at, now: now)
            if byTiming, hasNext { offByTiming = (leg, c.trainId, c.key, past, atStop) }
        case let .tookConnection(offAt, pullAwayTs):
            tracker?.alightStanding(at: offAt)
            handleEvents()
            tracker?.beginRiding(now: now, departedTs: pullAwayTs)
            handleEvents()
        }
    }

    /// When the train in hand could have pulled away from the stop the route leaves it at: not before a short stand there,
    /// and by a poll after the last that had it standing there (else a long dwell past its moment there).
    private func leaveWindow(_ c: BoardingCandidate, past: Int, atStop: Double) -> PollSpan {
        let last = c.stoodAt[past].map { $0.to + pollGapSec } ?? -.infinity
        return PollSpan(from: atStop + continuity.afterArrivalSec, to: max(last + 15, atStop + PlatformTiming.dwellSec + 60))
    }

    /// The train in hand stands at the stop the route leaves it at, by the feed (held there: Nov 2 and Nov 10 at Jay St),
    /// and the phone has felt a train's push since: not that train's, which has not moved. The rider is on the connection.
    /// A push the feed shows as a connection pulling away from the platform is that one; two pushes or more (a ride
    /// running) with none to match make it the first connection that left after the rider got off, by the route's timing.
    /// Pushes that begin among the rider's own steps (boarding, finding a seat) are not a train's (`pushRunsClear`).
    private mutating func checkLeftStandingTrain(_ c: BoardingCandidate, past: Int, atStop: Double, now: Double) {
        guard let t = tracker, let span = c.stoodAt[past], now >= atStop + continuity.afterArrivalSec else { return }
        let pushes = t.pushRunsClear.filter { $0 >= atStop + continuity.afterArrivalSec && $0 + 10 <= span.to }
        guard let p = pushes.first else { return }
        let pulls = transferLog.pullAways(), left = transferLog.pullAwaySpans()
        let pullAway: Double
        if continuity.isConnection(p, pullAways: pulls, left: left) {
            pullAway = p
        } else if pushes.count >= continuity.pushesForRide,
                  let first = continuity.firstConnection(after: atStop + stepOnSec, by: p + continuity.connectionWindowSec, pullAways: pulls) {
            pullAway = first
        } else {
            return
        }
        tracker?.alightStanding(at: min(atStop, pullAway))
        handleEvents()
        tracker?.beginRiding(now: now, departedTs: pullAway)
        handleEvents()
    }

    /// The ride closes at `at`, a walk-off no sensor felt, told now (`checkStayedOn`, `checkSamePlatformChange`). Told
    /// well after the moment it is put at, the next pull-away the detector feels may be the train the rider is already on.
    private mutating func alightLate(at: Double, now: Double) {
        let leg = currentLeg
        tracker?.alightStanding(at: at)
        handleEvents()
        if now - at >= lateOffSec { lateOff = (leg, at, now) }
    }

    /// After a walk-off told from the timing alone: while the rider is between trains (or on a connection nothing has
    /// backed yet), the train in hand is still followed, and if it is felt running on to the stops beyond, the rider
    /// stayed on: the walk-off is struck, the ride resumes, and the planner hears of the stay-on as before. A connection
    /// the feed backs, or one the rider named, settles it the other way.
    private mutating func checkOffByTiming(now: Double) {
        guard let u = offByTiming else { return }
        guard let t = tracker, t.phase == .riding, t.timeline.legsRidden == u.leg + 1, !handSet.contains(u.leg + 1) else { offByTiming = nil; return }
        let next = u.leg + 1
        // a connection the feed saw leave as the ride began is the plan's change made: the route's prior, when the pushes
        // since could be either train's (the F running on to York St, the A to High St, side by side). The ride's own pushes
        // back nothing here, and a ride claimed only after pushes no connection explains came from the train in hand
        // running on (the detector, stood down, takes its shaking for a pull-away, and an A may be at Jay St just then).
        let firstPush = t.pushRunsClear.first { $0 >= u.atStopTs + continuity.afterArrivalSec }
        if t.onTrain, let dep = t.ride(next)?.departedTs, firstPush.map({ dep <= $0 + continuity.connectionWindowSec }) ?? true,
           movedBack[next] != nil || platformLog(next)?.judgePullAway(at: dep, now: now) == .backed {
            offByTiming = nil; return
        }
        guard let lg = platformLog(u.leg), let c = lg.entry(u.trainId) else { return }
        let lag = PlatformTiming.recordedLag(route: c.route)
        let later = c.stopTs.filter { $0.key > u.pastIdx }.sorted { $0.key < $1.key }.map { $0.value - lag }
        let conn = platformLog(next)
        let vv = continuity.pastStop(atStopTs: u.atStopTs, laterStopTs: later, pushTimes: t.pushRunsClear, connectionPullAways: conn?.pullAways() ?? [],
                                   connectionLeft: conn?.pullAwaySpans() ?? [], connectionWindows: conn?.departureWindows() ?? [],
                                   trainWindow: leaveWindow(c, past: u.pastIdx, atStop: u.atStopTs), now: now)
        switch vv {
        case .waiting:
            return
        case .steppedOff, .tookConnection:
            offByTiming = nil
        case .stayedOn:
            offByTiming = nil
            resumeRide(leg: u.leg)
            stayedOnChecked.insert(u.leg)
            stayedOn = StayedOn(leg: u.leg, key: u.key, trainId: u.trainId, pastIdx: u.pastIdx, ts: now)
        }
    }

    /// The ride on leg `leg` goes on (`TripTracker.resumeRide`): the next leg's start is taken back, and the logs follow
    /// the leg in hand again.
    private mutating func resumeRide(leg: Int) {
        tracker?.resumeRide()
        let next = leg + 1
        beliefs.removeAll { $0.leg == next }
        departureBeliefs[next] = nil; candidates[next] = nil; departedTs[next] = nil
        departureChecked.remove(next); motionUnconfirmed.remove(next); dismissed.remove(next); locationRides.remove(next); presumedRides.remove(next)
        if logLeg == next { transferLog = log; log = prevLog; prevLog = DepartureLog(); logLeg = leg }
        lastAlight = nil; lateOff = nil; movedBack[next] = nil
        seenEvents = tracker?.timeline.events.count ?? 0
    }

    /// A departure moved back to a connection that had left before the late walk-off was told (`handleEvents`) is a guess
    /// the next push tests: on that train, the push is its braking into the next stop; still on the platform, it is the
    /// rider's own train pulling away from there, which the feed shows as a train of the leg leaving then. That one is the
    /// ride, from that push.
    private mutating func checkMovedBack(now: Double) {
        guard let t = tracker, t.phase == .riding, t.onTrain else { movedBack = [:]; return }
        let leg = t.timeline.legsRidden
        guard let moved = movedBack[leg] else { movedBack = [:]; return }
        guard !handSet.contains(leg), let dep = t.ride(leg)?.departedTs, dep == moved else { movedBack[leg] = nil; return }
        guard let p = t.pushRuns.first(where: { $0 > moved + continuity.afterArrivalSec && $0 <= now }), let lg = platformLog(leg) else { return }
        let pulls = lg.pullAways(), left = lg.pullAwaySpans()
        // the feed may not show the train gone yet: wait a poll or two after the push before ruling
        if !continuity.isConnection(p, pullAways: pulls, left: left) {
            if now - p < 2 * pollGapSec { return }
            movedBack[leg] = nil
            return
        }
        movedBack[leg] = nil
        guard abs(p - moved) > continuity.connectionWindowSec else { return }
        tracker?.moveDeparture(to: p)
        departureMoved(ride: leg)
    }

    /// A location fix. Soon after a walk-off, the fix says which station the rider is at: its distance to each
    /// candidate train's alighting stop is weighed into the leg's belief, once.
    mutating func location(ts: Double, toOriginM: Double?, toDestM: Double?, now: Double, coordinate: (lat: Double, lon: Double)? = nil, accuracyM: Double? = nil) {
        tracker?.location(ts: ts, toOriginM: toOriginM, toDestM: toDestM, now: now, accuracyM: accuracyM)
        if (accuracyM ?? 0) > 100 { return }        // too unsure to say which stop the rider walked off at
        if let c = coordinate, let la = lastAlight, ts >= la.ts, now - la.ts <= 300, !locationApplied.contains(la.leg), !handSet.contains(la.leg),
           let b = belief(leg: la.leg), !b.assumed, let cands = candidates[la.leg], let sc = stopCoordinate {
            var dist: [String: Double] = [:]
            for cd in cands {
                // each train against the stop a rider on it would have walked off at (its own nearest stop, off the plan)
                if let ai = inference.alightingStop(cd, at: la.ts), let p = sc(cd.key, ai) { dist[cd.trainId] = haversineM((c.lat, c.lon), p) }
            }
            if !dist.isEmpty {
                locationApplied.insert(la.leg)
                store(inference.withLocation(b, candidates: cands, distanceM: dist))
            }
        }
    }

    mutating func updateForecast(boardTs: Double?, arriveTs: Double?, now: Double) {
        tracker?.updateForecast(boardTs: boardTs, arriveTs: arriveTs, now: now)
    }

    /// The rider said they were not on this train after the session presumed them boarded: the plan lets it go.
    func declinedTrain(_ trainId: String) -> Bool { presumeDeclined.contains(trainId) }

    /// The forecast's train left without the rider: the forecast follows the next one (`TripTracker.letForecastGo`).
    mutating func letForecastGo() { tracker?.letForecastGo() }

    /// The boarding time of the forecast the rider acted on, as the tracker holds it (frozen once that train left).
    var forecastBoardTs: Double? { tracker?.timeline.forecastBoardTs }

    /// The train the forecast named has gone from the feed just before its predicted platform moment while the rider
    /// stood at the station: it left. Returns whether the forecast froze on it (see `TripTracker.forecastTrainDeparted`).
    @discardableResult
    mutating func forecastTrainDeparted(now: Double) -> Bool {
        let before = tracker?.timeline.forecastBoardTs
        tracker?.forecastTrainDeparted(now: now)
        return tracker?.timeline.forecastBoardTs != before
    }

    /// Every feed poll while the route is on: the boards of the leg in hand (the feed's own times, not the
    /// engine's) go into the departure log, which keeps each train's time at the platform after the feed has
    /// moved the train on.
    mutating func observeBoards(_ boards: [String: LineBoard], now: Double) {
        lastNow = max(lastNow ?? now, now)
        guard let t = tracker, t.phase != .arrived else { return }
        let leg = t.timeline.legsRidden
        guard leg < legs.count else { return }
        if leg != logLeg { advanceLogs(to: leg) }
        Self.observe(legs[leg], boards: boards, into: &log, now: now)
        if leg + 1 < legs.count { Self.observe(legs[leg + 1], boards: boards, into: &transferLog, now: now) }
        if leg >= 1 { Self.observe(legs[leg - 1], boards: boards, into: &prevLog, now: now) }
        rereadUnmatched()
        rideEvidence(now: now)
        judgePendingBoarding(now: now)        // the ride's own motion first: a ride felt running on is not the feed's to take back
        checkMovedBack(now: now)
        checkDepartureMade(now: now)
        presumeBoarding(now: now)
        checkSamePlatformChange(now: now)
        checkStayedOn(now: now)
        checkOffByTiming(now: now)
    }

    /// On to leg `leg`: the log that followed its lines at the transfer platform during the last leg takes over, and the
    /// last leg's own log is kept as the one before.
    private mutating func advanceLogs(to leg: Int) {
        if logLeg >= 0, leg == logLeg + 1 {
            prevLog = log; log = transferLog
        } else {
            prevLog = DepartureLog(); log = DepartureLog()
        }
        transferLog = DepartureLog()
        logLeg = leg
    }

    /// The log that follows leg `leg`'s lines at its boarding platform, when one does.
    private mutating func platformLog(_ leg: Int) -> DepartureLog? {
        if leg == logLeg { return log }
        if leg == logLeg + 1 { return transferLog }
        if leg == logLeg - 1, leg >= 0 { return prevLog }
        return nil
    }

    /// The train the plan has the rider on for each leg still to board, as the planner's itinerary stands now:
    /// kept up until the leg's boarding time passes (the planner then moves on to the next train, but the rider
    /// presumably took this one), so a ride assumed from the schedule, the candidates' `chosen` mark and the
    /// plan's fallback all name the train actually in question.
    mutating func updatePlannedTrains(_ trains: [Int: (key: String, trainId: String)], now: Double) {
        guard let t = tracker, t.phase != .arrived else { return }
        let riding = t.phase == .riding ? t.timeline.legsRidden : -1
        for (leg, tr) in trains where leg < legs.count && leg >= t.timeline.legsRidden && leg != riding && departedTs[leg] == nil {
            guard legs[leg].keys.contains(tr.key) else { continue }
            legs[leg].chosenKey = tr.key
            legs[leg].chosenTrainId = tr.trainId
        }
    }

    /// A felt pull-away that no train made. About a minute and a half on, the feed has had time to show a train that
    /// left then as gone past the platform. If none did, while other trains the log follows are still to come (the
    /// feed is alive here), it was the platform shaking (a train on the next track, the stairs), not the rider's
    /// train: withdrawn once per leg, and the next pull-away counts afresh. Seen twice on Oct 7: at 4 Av-9 St three
    /// minutes before the G the rider took, and at Hoyt as the G they had just left pulled out. Not for a ride the
    /// rider named or the phone's movement began.
    ///
    /// The ride just behind is checked too: a few steps on the platform can close a "ride" before the feed has had time
    /// to say no train left (Oct 12 at 4 Av-9 St: the pull-away at 11:47:51, the shuffle at 11:49:39, the check due at
    /// 11:49:31 and the next poll after the walk-off). Such a ride is withdrawn whole, and the rides after it move up a leg.
    private mutating func checkDepartureMade(now: Double) {
        guard let t = tracker, t.phase == .riding else { return }
        let leg = t.timeline.legsRidden
        for k in [leg, leg - 1] where k >= 0 && k < legs.count {
            guard !handSet.contains(k), !locationRides.contains(k), !departureChecked.contains(k), let dep = departedTs[k], now - dep >= departureCheckSec,
                  let lg = platformLog(k) else { continue }
            if k == leg, t.timeline.events.last?.kind != .departed { continue }
            guard now - dep <= departureCheckSec + 240 else { departureChecked.insert(k); continue }   // too long ago to say
            guard lg.lastPollTs >= dep + 75 else { continue }                                           // the feed has not been read since
            departureChecked.insert(k)
            let check = lg.departureCheck(at: dep)
            guard !check.left, check.waiting else { continue }
            if k == leg {
                withdrawPullAway(leg: leg)
            } else {
                withdrawRide(k)
            }
            return
        }
    }

    /// The rider stood at the leg's platform (the origin's, within the station's radius; or the change's, off the train
    /// before) when the plan's train left it, by the feed, and the sensors felt no pull-away: the rider is presumed on
    /// that train (Nov 10 evening: the F boarded at the origin unfelt, a little later than its predicted time, and the
    /// planner moved on to the next F as if the rider were still waiting). The chosen route is the assumption; the
    /// boarding and the train's time need not line up, only the train must have left after the rider got there and
    /// within `presumeLookBackSec`. A train the feed still lists at the platform has not left, however late (Oct 21 at 14
    /// St), so nothing is presumed while it stands. The ride is shown as presumed (the plan's train, "presumably") and the
    /// prompt asks; "Not on train" takes it back to the platform and that train is never presumed again.
    private mutating func presumeBoarding(now: Double) {
        guard var t = tracker, t.sensing, !t.onTrain, t.phase != .arrived else { return }
        let leg = t.timeline.legsRidden
        guard leg < legs.count, !handSet.contains(leg), let id = legs[leg].chosenTrainId, !presumeDeclined.contains(id),
              let lg = platformLog(leg), let left = lg.leftPlatformTs(id) else { return }
        let since: Double?
        if leg == 0 {
            guard t.phase == .atStation else { return }
            since = t.timeline.arrivedStationTs
        } else {
            guard t.phase == .riding, let off = t.timeline.events.last, off.kind == .alighted else { return }
            since = off.ts
        }
        guard let at = since, at <= left, now - left <= presumeLookBackSec else { return }
        t.beginRiding(now: now, departedTs: left)
        tracker = t
        seenEvents = t.timeline.events.count
        if logLeg != leg { advanceLogs(to: leg) }
        let dep = t.ride(leg)?.departedTs ?? left
        departedTs[leg] = dep
        candidates[leg] = lg.entry(id, chosenTrainId: id).map { [$0] } ?? []
        departureChecked.insert(leg)
        presumedRides.insert(leg); locationRides.insert(leg)
        if let b = LineBelief.fromPlan(leg: leg, chosenKey: legs[leg].chosenKey, chosenTrainId: id, evidence: "plan") { store(b) }
    }

    /// The rider says they are on the train while a felt pull-away waits on the feed ("On it" on the Live Activity or in
    /// the app): the ride is shown, and the feed's departure check no longer takes it back.
    mutating func confirmBoarding() {
        guard let t = tracker, t.boardingPending else { return }
        tracker?.backBoarding()
        departureChecked.insert(t.timeline.legsRidden)
        motionUnconfirmed.remove(t.timeline.legsRidden)
    }

    /// The pull-away on the leg in hand was no train's: the rider is back at the platform and the next one counts afresh.
    private mutating func withdrawPullAway(leg: Int) {
        tracker?.withdrawDeparture()
        beliefs.removeAll { $0.leg == leg }
        departureBeliefs[leg] = nil; candidates[leg] = nil; departedTs[leg] = nil
        departureChecked.remove(leg)
        seenEvents = tracker?.timeline.events.count ?? 0
    }

    /// A felt pull-away still waiting on the feed (`DepartureLog.judgePullAway`), read again at every poll: backed as soon
    /// as a train at the platform is seen to leave then, withdrawn as soon as the feed shows none could have. The
    /// departure check above still has the last word after `departureCheckSec`.
    private mutating func judgePendingBoarding(now: Double) {
        guard let t = tracker, t.onTrain else { return }
        let leg = t.timeline.legsRidden
        guard leg < legs.count, let dep = departedTs[leg] ?? t.ride(leg)?.departedTs, !handSet.contains(leg) else { return }
        guard t.boardingPending || motionUnconfirmed.contains(leg) else { return }
        guard t.timeline.events.last.map({ $0.kind == .departed && abs($0.ts - dep) <= 90 }) ?? false else { return }
        // The motion has its say whatever the feed: a train that pulls away with the phone on it is felt running on, and
        // one that leaves without it is not, even when it is a train of the leg's lines (the rider let it go).
        let motion = RideContinuity().pendingRide(departedTs: dep, pushTimes: t.pushRuns, now: now)
        if motion == .notARide, motionUnconfirmed.contains(leg) || t.boardingPending { motionUnconfirmed.remove(leg); withdrawPullAway(leg: leg); return }
        if motion == .rides { motionUnconfirmed.remove(leg); departureChecked.insert(leg) }   // a ride felt running on is one
        guard t.boardingPending, let lg = platformLog(leg) else { return }
        let v = lg.judgePullAway(at: dep, now: now)
        if v == .noTrain { withdrawPullAway(leg: leg); return }
        // Backed by the feed (a train of the leg's lines left then), by the ride itself (pushes after the pull-away), or
        // by the walk-off or a fix matching the train. Another line's train leaving the platform is not enough (Nov 5 at
        // 4 Av-9 St: the G left three minutes before the rider's F), nor the feed falling quiet, nor stops "felt" on a
        // ride that has not been shown to move (they were the platform's shaking: Nov 5 evening called the B).
        let placed = belief(leg: leg)?.evidence.contains { ["alighting", "location"].contains($0) } ?? false
        if v == .backed || motion == .rides || placed { tracker?.backBoarding() }
    }

    /// Ride `k` was not one (see `TripTracker.withdrawRide`): what the phone made of it goes, every leg after it moves
    /// up one, the platform logs follow the leg in hand back, and the rides that moved are read again against the
    /// trains at their own platform (the F at 4 Av-9 St, not the trains that happened to leave Jay St then).
    private mutating func withdrawRide(_ k: Int) {
        guard var t = tracker else { return }
        let before = t.timeline.legsRidden
        t.withdrawRide(k)
        guard t.timeline.legsRidden == before - 1 else { return }
        tracker = t
        func up<V>(_ d: [Int: V]) -> [Int: V] {
            var out: [Int: V] = [:]
            for (l, v) in d where l != k { out[l > k ? l - 1 : l] = v }
            return out
        }
        func up(_ s: Set<Int>) -> Set<Int> { Set(s.filter { $0 != k }.map { $0 > k ? $0 - 1 : $0 }) }
        candidates = up(candidates); departedTs = up(departedTs); departureBeliefs = up(departureBeliefs)
        beliefs = beliefs.filter { $0.leg != k }.map { var b = $0; if b.leg > k { b.leg -= 1 }; return b }
        handSet = up(handSet); dismissed = up(dismissed); departureChecked = up(departureChecked); locationApplied = up(locationApplied)
        stayedOnChecked = up(stayedOnChecked); locationRides = up(locationRides); presumedRides = up(presumedRides)
        if let la = lastAlight { lastAlight = la.leg == k ? nil : (la.leg > k ? (la.leg - 1, la.ts) : la) }
        offPlanAlighting = nil; stayedOn = nil; offByTiming = nil; lateOff = nil; movedBack = [:]
        let leg = t.timeline.legsRidden
        if logLeg == leg + 1 {
            transferLog = log; log = prevLog; prevLog = DepartureLog(); logLeg = leg
        }
        seenEvents = t.timeline.events.count
        for l in max(k, leg - 1)...leg where l < legs.count { reread(l) }
    }

    /// Ride `l` read afresh against the trains its own platform's log followed: the pull-away, then the stops felt and
    /// the walk-off if it is over. The rider's word on the line stands; only the train is looked up again.
    private mutating func reread(_ l: Int) {
        guard let t = tracker, let r = t.ride(l), let lg = platformLog(l) else { return }
        let plan = legs[l]
        let cands = legCandidates(lg, leg: l, departedTs: r.departedTs)
        candidates[l] = cands
        departedTs[l] = r.departedTs
        if handSet.contains(l) {
            if let key = belief(leg: l)?.bestKey { store(LineBelief.byHand(leg: l, key: key, chosenKey: plan.chosenKey, candidates: cands, departedTs: r.departedTs)) }
            return
        }
        var b = inference.fromDeparture(cands, departedTs: r.departedTs, leg: l, chosenKey: plan.chosenKey, lineFit: plan.lineFit)
        guard !b.byTrain.isEmpty else {
            departureBeliefs[l] = nil
            beliefs.removeAll { $0.leg == l }
            if let f = LineBelief.fromPlan(leg: l, chosenKey: plan.chosenKey, chosenTrainId: plan.chosenTrainId, evidence: "plan") { store(f) }
            return
        }
        departureBeliefs[l] = b
        if let a = r.alightedTs {
            if t.timeline.rideStops.indices.contains(l) {
                b = inference.withStops(b, candidates: cands, stopsFelt: t.timeline.rideStops[l], departedTs: r.departedTs, alightedTs: a)
            }
            b = inference.withAlighting(b, candidates: cands, alightedTs: a)
        }
        store(b)
    }

    /// A pull-away with every leg already ridden: one of the rides was not one. The likeliest is a short ride with no
    /// station stop felt (the shortest of them), not one the rider named; withdrawn, the new pull-away is the last
    /// leg's and is read against that platform's trains. True when a ride was withdrawn.
    private mutating func reconcileExtraDeparture() -> Bool {
        guard let t = tracker else { return false }
        var best: (k: Int, sec: Double)?
        for k in 0..<legs.count where !handSet.contains(k) && !locationRides.contains(k) {
            guard let r = t.ride(k), let a = r.alightedTs, t.timeline.rideStops.indices.contains(k), t.timeline.rideStops[k] == 0 else { continue }
            let sec = a - r.departedTs
            if sec <= phantomRideMaxSec, sec < (best?.sec ?? .infinity) { best = (k, sec) }
        }
        guard let p = best?.k else { return false }
        withdrawRide(p)
        return true
    }

    /// The rider names, for the ride in hand, a line of the leg before that this leg does not have, while the phone
    /// had that earlier ride on another line with no station stop felt: the earlier "ride" was not one, and this is
    /// the earlier leg's train (Oct 12: the F picked while the phone had the rider on the C leg, the R below the F
    /// platform having been taken for the first leg). The Go tab asks before switching the route to that line.
    func namesEarlierLeg(_ key: String) -> Bool {
        guard let t = tracker, t.onTrain else { return false }
        let leg = t.timeline.legsRidden, k = leg - 1
        guard k >= 0, leg < legs.count, legs[k].keys.contains(key), !legs[leg].keys.contains(key), !handSet.contains(k) else { return false }
        let stops = t.timeline.rideStops.indices.contains(k) ? t.timeline.rideStops[k] : 0
        return stops == 0 && belief(leg: k)?.bestKey != key
    }

    /// The ride in hand is the earlier leg's, by the rider's word on `key`: the ride before it is withdrawn and this one
    /// takes its place, on that line.
    private mutating func refileAsEarlierLeg(_ key: String) {
        guard let t = tracker else { return }
        withdrawRide(t.timeline.legsRidden - 1)
        let leg = currentLeg
        guard leg < legs.count else { return }
        handSet.insert(leg); dismissed.remove(leg)
        store(LineBelief.byHand(leg: leg, key: key, chosenKey: legs[leg].chosenKey, candidates: candidates[leg] ?? [], departedTs: departedTs[leg]))
    }

    private static func observe(_ plan: LegPlan, boards: [String: LineBoard], into log: inout DepartureLog, now: Double) {
        for k in plan.keys {
            guard let b = boards[k], let span = plan.idx[k] else { continue }
            log.observe(trains: b.trains, key: k, boardIdx: span.from, span: span, onLeg: true, now: now)
        }
        for (k, bi) in plan.platformKeys where !plan.keys.contains(k) {
            guard let b = boards[k] else { continue }
            log.observe(trains: b.trains, key: k, boardIdx: bi, span: nil, onLeg: false, now: now, samePlatform: !plan.otherPlatformKeys.contains(k))
        }
    }

    /// Every poll while riding: the stops felt so far, and when, against each candidate train's actual progress
    /// and stop times from the feed, recomputed from the departure belief.
    private mutating func rideEvidence(now: Double) {
        guard let t = tracker, t.phase == .riding else { return }
        let leg = t.timeline.legsRidden
        guard let cands = candidates[leg], !cands.isEmpty else { return }
        let fresh = log.refreshed(cands)
        candidates[leg] = fresh
        guard !handSet.contains(leg), let base = departureBeliefs[leg] else { return }
        let b = inference.withRide(base, candidates: fresh, stopTimes: t.stopTimes, now: now)
        if b != belief(leg: leg) { store(b) }
    }

    /// A same-platform change the sensors cannot see (no walk): the phone has stood still at a station for a
    /// while and the feed has moved the believed train on past the transfer stop, so the rider is on the platform.
    private mutating func checkSamePlatformChange(now: Double) {
        guard let t = tracker, t.phase == .riding else { return }
        let leg = t.timeline.legsRidden
        guard leg + 1 < legs.count, legs[leg + 1].walkSec <= 0, let since = t.standingSince, now - since >= samePlatformStandSec,
              let b = belief(leg: leg), let best = b.bestTrain, let cand = candidates[leg]?.first(where: { $0.trainId == best }),
              let alightIdx = cand.alightIdx, let progress = log.progressIdx(of: best), progress > alightIdx else { return }
        alightLate(at: since, now: now)
    }

    /// The tracker's new events: a departure starts a belief for the leg from the trains that were at the
    /// platform; an alighting corroborates it with the stops felt and the arrival time.
    private mutating func handleEvents() {
        guard let t = tracker else { return }
        let events = t.timeline.events
        while seenEvents < events.count {
            let e = events[seenEvents]
            seenEvents += 1
            switch e.kind {
            case .departed:
                var leg = t.timeline.legsRidden
                if leg >= legs.count {
                    // every leg ridden and a pull-away again: take back the ride that was not one, and read this one as the last leg's
                    guard reconcileExtraDeparture(), let nt = tracker else { continue }
                    leg = nt.timeline.legsRidden
                    guard leg < legs.count, nt.timeline.events.last == e else { return }
                    if nt.departedByLocation { locationRides.insert(leg) }
                    reread(leg)
                    return
                }
                // a pull-away at the change before the rider could have reached the next platform: the stairs, not a train
                if leg >= 1, !handSet.contains(leg), !t.departedByLocation, let la = lastAlight, la.leg == leg - 1,
                   departureTooSoonAfterChange(departedTs: e.ts, alightedTs: la.ts, walkSec: legs[leg].walkSec) {
                    tracker?.withdrawDeparture()
                    seenEvents = tracker?.timeline.events.count ?? 0
                    return
                }
                // the walk-off was told late (the train in hand had to leave the change first) and the detector, standing down
                // only then, feels the phone moving at once: the rider stepped onto a connection in between, and the first
                // that left after they got off is theirs, not one leaving about now (Nov 10 at Jay St: the A a minute behind
                // the F, boarded, and the phone's A was the one after it)
                var depTs = e.ts
                if let lo = lateOff, lo.leg == leg - 1, !handSet.contains(leg), !t.departedByLocation {
                    lateOff = nil
                    if e.ts - lo.toldTs <= lateOffDepartureSec, let lg = platformLog(leg),
                       let first = continuity.firstConnection(after: lo.offTs + stepOnSec, by: e.ts, pullAways: lg.pullAways()), first < e.ts {
                        tracker?.moveDeparture(to: first)
                        depTs = tracker?.timeline.events.last?.ts ?? e.ts
                        movedBack[leg] = depTs
                    }
                }
                if t.departedByLocation { locationRides.insert(leg) } else if !handSet.contains(leg) { motionUnconfirmed.insert(leg) }
                // no felt pull-away puts the rider on a train by itself: the feed's trains at the platform back it, show
                // that none could have made it (withdrawn now, not 100 s on), or leave it waiting, shown as boarding
                if !handSet.contains(leg), !t.departedByLocation, let lg = platformLog(leg),
                   tracker?.applyPullAwayVerdict(lg.judgePullAway(at: depTs, now: lastNow ?? depTs)) == true {
                    seenEvents = tracker?.timeline.events.count ?? 0
                                return
                }
                let plan = legs[leg]
                // the leg's own platform log, even before the next poll moves the logs on: a step across the platform is a
                // pull-away seconds after the walk-off (Oct 28 at Jay St: the A, read against the F platform's log at 4 Av-9 St,
                // where a G had just passed, and the A leg called the G)
                if leg != logLeg { advanceLogs(to: leg) }
                let cands = legCandidates(log, leg: leg, departedTs: depTs)
                candidates[leg] = cands
                departedTs[leg] = depTs
                guard !handSet.contains(leg) else { continue }
                // what this rider has ridden on this very trip, else the line they usually board at this platform
                // (after the line just ridden, at a change) at about this hour
                let share = plan.chosenKey.flatMap { k in linePrior?(plan, leg, k, t.timeline, depTs) }
                let b = inference.fromDeparture(cands, departedTs: depTs, leg: leg, chosenKey: plan.chosenKey, learnedShare: share, lineFit: plan.lineFit)
                // a departure felt with no train in the feed to match it: the plan stands, as a guess
                if b.byTrain.isEmpty, let fallback = LineBelief.fromPlan(leg: leg, chosenKey: plan.chosenKey, chosenTrainId: plan.chosenTrainId, evidence: "plan") {
                    store(fallback)
                } else {
                    departureBeliefs[leg] = b
                    store(b)
                }
            case .alighted:
                let leg = t.timeline.legsRidden - 1
                lastAlight = (leg, e.ts)
                if leg >= 0, handSet.contains(leg) { checkAlightingStop(leg: leg, ts: e.ts) }
                guard leg >= 0, !handSet.contains(leg), let current = belief(leg: leg), !current.assumed, let known = candidates[leg] else { continue }
                let cands = log.refreshed(known)
                candidates[leg] = cands
                // the ride's evidence first (from the departure belief), then the stop count and the arrival time
                var b = departureBeliefs[leg].map { inference.withRide($0, candidates: cands, stopTimes: t.lastRideStopTimes, now: e.ts) } ?? current
                if let stops = t.timeline.rideStops.last { b = inference.withStops(b, candidates: cands, stopsFelt: stops, departedTs: departedTs[leg], alightedTs: e.ts) }
                store(inference.withAlighting(b, candidates: cands, alightedTs: e.ts))
                checkAlightingStop(leg: leg, ts: e.ts)
            }
        }
    }

    /// Where the rider walked off, by the train the phone settled on (or the rider named): the stop whose time, put
    /// back to the platform moment, is nearest the walk-off. Off the plan's own stop, the planner hears of it.
    private mutating func checkAlightingStop(leg: Int, ts: Double) {
        guard let b = belief(leg: leg), b.settled || b.byHand, let id = b.bestTrain,
              let c = log.refreshed((candidates[leg] ?? []).filter { $0.trainId == id }).first else { return }
        let lagSec = inference.alightLagSec
        let walkOff = { (feedTs: Double) in PlatformTiming.atPlatform(feedTs, route: c.route) + lagSec }
        guard let near = c.stopTs.filter({ $0.key > c.boardIdx }).min(by: { abs(walkOff($0.value) - ts) < abs(walkOff($1.value) - ts) }),
              abs(walkOff(near.value) - ts) <= 150 else { return }
        if let planned = legs[leg].idx[c.key]?.to, planned == near.key { return }
        offPlanAlighting = OffPlanAlighting(leg: leg, key: c.key, stopIdx: near.key, ts: ts)
    }

    private mutating func store(_ b: LineBelief) {
        if let i = beliefs.firstIndex(where: { $0.leg == b.leg }) { beliefs[i] = b } else { beliefs.append(b) }
        if let bl = b.boarded { tracker?.setBoarded(bl, now: lastNow) }
    }

    /// The ride the tracker assumed from the schedule (boarding time past, no departure felt) is the plan's
    /// train until the sensors or the rider say otherwise.
    private mutating func checkAssumed() {
        guard let t = tracker, t.phase == .riding, t.timeline.rideAssumed else { return }
        let leg = t.timeline.legsRidden
        guard leg < legs.count, belief(leg: leg) == nil,
              let b = LineBelief.fromPlan(leg: leg, chosenKey: legs[leg].chosenKey, chosenTrainId: legs[leg].chosenTrainId, evidence: "schedule") else { return }
        store(b)
    }

    /// The rider's own word on the line they boarded for the leg in hand; nothing measured later overrides it.
    mutating func setBoardedByHand(key: String) {
        if namesEarlierLeg(key) { refileAsEarlierLeg(key); return }
        let leg = currentLeg
        guard leg < legs.count else { return }
        handSet.insert(leg)
        store(LineBelief.byHand(leg: leg, key: key, chosenKey: legs[leg].chosenKey, candidates: candidates[leg] ?? [], departedTs: departedTs[leg]))
    }

    /// The rider confirms one particular train (from the prompt's candidates).
    mutating func confirm(trainId: String) {
        let leg = currentLeg
        guard leg < legs.count, let c = (candidates[leg] ?? []).first(where: { $0.trainId == trainId }) else { return }
        handSet.insert(leg)
        store(LineBelief(leg: leg, byTrain: [c.trainId: 1.0], byLine: [c.key: 1.0], chosenKey: legs[leg].chosenKey, evidence: ["hand"]))
    }

    /// The rider waves the question away; the phone's own estimate stands.
    mutating func dismissPrompt() { dismissed.insert(currentLeg) }

    /// The rider says which train they are on, from the trains that have left the platform (a route started from
    /// the train, or one whose pull-away went unfelt, or a wrong guess put right): the ride is on from that train's
    /// departure if it was not already, the train is the leg's belief, by hand, and the departure log follows it
    /// from here on, so the arrival clock and the alighting read its progress.
    mutating func setOnTrain(_ c: BoardingCandidate, now: Double) {
        if namesEarlierLeg(c.key) { refileAsEarlierLeg(c.key); return }
        guard var t = tracker, t.phase != .arrived else { return }
        let leg = t.timeline.legsRidden
        guard leg < legs.count else { return }
        if !t.onTrain {
            t.beginRiding(now: now, departedTs: PlatformTiming.pullsAway(c.boardTs, route: c.route))
            tracker = t
            seenEvents = t.timeline.events.count          // the departure on the record is this one, not one to infer from
        }
        if logLeg != leg { advanceLogs(to: leg) }
        log.seed(c, now: now)
        var cands = (candidates[leg] ?? []).filter { $0.trainId != c.trainId }
        cands.append(c)
        candidates[leg] = cands.sorted { $0.boardTs != $1.boardTs ? $0.boardTs < $1.boardTs : $0.trainId < $1.trainId }
        departedTs[leg] = PlatformTiming.pullsAway(c.boardTs, route: c.route)
        handSet.insert(leg); dismissed.remove(leg)
        store(LineBelief(leg: leg, byTrain: [c.trainId: 1.0], byLine: [c.key: 1.0], chosenKey: legs[leg].chosenKey, evidence: ["hand"]))
    }

    /// The rider says they are not on a train: the felt departure is withdrawn and the leg starts over at the platform.
    ///
    /// Said while the train the phone has them on has already reached the stop the route had them leave it at, they got
    /// off there unfelt: the ride closes at that stop and the route goes on from the change, with its arrival from the
    /// connection, rather than starting over at the platform they boarded at. Said once it has reached a station where
    /// another route changes toward the destination, they changed there (`readNotOnTrain`).
    ///
    /// `changes`: every change the rider could have made off the train in hand toward the destination (the planner's
    /// `changesOnTheWay`), worked out by the caller before the call.
    mutating func notOnTrain(now: Double? = nil, changes: [EarlyChange] = []) {
        let now = now ?? lastNow ?? Date().timeIntervalSince1970
        tracker?.noteNotOnTrain(at: now)
        // a ride the session presumed from the plan's train leaving, with no train felt since: the rider let it go and is
        // still at the platform, whatever that train has done since
        if let t = tracker, t.onTrain, presumedRides.contains(currentLeg), let dep = departedTs[currentLeg],
           !t.pushRuns.contains(where: { $0 > dep }) {
            let leg = currentLeg
            if let id = legs[leg].chosenTrainId { presumeDeclined.insert(id) }
            presumedRides.remove(leg); locationRides.remove(leg); departureChecked.remove(leg)
            tracker?.notOnTrain()
            tracker?.letForecastGo()
            if let i = beliefs.firstIndex(where: { $0.leg == leg }) { beliefs.remove(at: i) }
            departureBeliefs[leg] = nil; candidates[leg] = nil; departedTs[leg] = nil
            seenEvents = tracker?.timeline.events.count ?? 0
            return
        }
        if let t = tracker, t.phase == .riding, t.timeline.events.last?.kind == .departed {
            let dep = departedTs[currentLeg] ?? t.ride(currentLeg)?.departedTs
            switch readNotOnTrain(train: trainInHand, departedTs: dep, changes: changes, now: now) {
            case let .alighted(at):
                tracker?.alightStanding(at: at)
                handleEvents()
                        return
            case let .changed(change, at):
                takeChange(change, alightTs: at, now: now, waiting: true)
                return
            case .backToPlatform:
                break
            }
        }
        // the phone rode the train on from the platform it was boarded at: the rider is off at a stop along its way, not
        // back at that platform (Nov 9: put back at 4 Av-9 St from Jay St, and the next pull-away read as a G leaving there)
        if let t = tracker, t.phase == .riding, t.timeline.events.last?.kind == .departed, let c = trainInHand,
           let dep = departedTs[currentLeg] ?? t.ride(currentLeg)?.departedTs,
           let off = continuity.stopLeftAt(c, departedTs: dep, pushTimes: t.pushRuns, now: now) {
            let leg = currentLeg
            tracker?.alightStanding(at: off.ts)
            handleEvents()
            if legs.indices.contains(leg), legs[leg].idx[c.key]?.to != off.idx {
                offPlanAlighting = OffPlanAlighting(leg: leg, key: c.key, stopIdx: off.idx, ts: off.ts)
            }
                return
        }
        let leg = currentLeg
        tracker?.notOnTrain()
        if let i = beliefs.firstIndex(where: { $0.leg == leg }) { beliefs.remove(at: i) }
        departureBeliefs[leg] = nil; candidates[leg] = nil; departedTs[leg] = nil
        handSet.remove(leg); dismissed.remove(leg)
        seenEvents = tracker?.timeline.events.count ?? 0
    }

    /// The route changed under the rider (they boarded a line off the plan and the planner found the route that
    /// rides it): the legs from here on follow the new plan; the belief about the leg in hand is kept and now
    /// counts as on-plan.
    mutating func replan(legs newLegs: [LegPlan], transferStation: String? = nil, transferStops: String? = nil) {
        let leg = currentLeg
        let old = legs
        legs = newLegs
        transferLog = DepartureLog()
        // the leg in hand now boards somewhere else (the rider changed at another station): its trains are followed
        // afresh there, and a pull-away already felt on it is read again against them
        if leg < newLegs.count, leg < old.count, boardingStops(old[leg]) != boardingStops(newLegs[leg]) {
            log = DepartureLog(); logLeg = leg
            candidates[leg] = nil; departureBeliefs[leg] = nil; departureChecked.remove(leg)
            if !handSet.contains(leg) { beliefs.removeAll { $0.leg == leg } }
        }
        if leg < legs.count, let b = belief(leg: leg) {
            var nb = b; nb.chosenKey = legs[leg].chosenKey
            store(nb)
            if let d = departureBeliefs[leg] { var nd = d; nd.chosenKey = legs[leg].chosenKey; departureBeliefs[leg] = nd }
        }
        dismissed.remove(leg)
        stayedOn = nil
        tracker?.replan(legs: max(1, newLegs.count), transferStation: transferStation, transferStops: transferStops)
    }

    private mutating func boardingStops(_ p: LegPlan) -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in p.idx { out[k] = v.from }
        return out
    }

    /// Trains that already left the leg's (new) boarding platform, taken up by the log as if it had seen them there:
    /// the rider may have stepped straight onto one. A pull-away already felt on the leg is read against them.
    mutating func seedCurrentLeg(_ cands: [BoardingCandidate], now: Double) {
        guard let t = tracker else { return }
        let leg = t.timeline.legsRidden
        guard leg < legs.count else { return }
        if logLeg != leg { advanceLogs(to: leg); log = DepartureLog() }
        for c in cands { log.seed(c, now: now) }
        guard !handSet.contains(leg), let dep = departedTs[leg], t.phase == .riding else { return }
        let plan = legs[leg]
        let cs = legCandidates(log, leg: leg, departedTs: dep)
        candidates[leg] = cs
        let b = inference.fromDeparture(cs, departedTs: dep, leg: leg, chosenKey: plan.chosenKey, lineFit: plan.lineFit)
        if !b.byTrain.isEmpty { departureBeliefs[leg] = b; store(b) }
    }

    /// The arrival as the train the rider is on makes it, from the planner: the clock the trip ends by.
    mutating func setLiveArrival(_ ts: Double) { tracker?.setLiveArrival(ts) }

    /// The train the phone believes the rider is on for the leg in hand (a settled belief or the rider's word),
    /// with the feed's times the departure log has kept for it; nil at the platform or while the phone is unsure.
    var boardedCandidate: BoardingCandidate? {
        guard let t = tracker, t.phase == .riding else { return nil }
        let leg = t.timeline.legsRidden
        guard let b = belief(leg: leg), b.settled || b.byHand, let id = b.bestTrain else { return nil }
        return (candidates[leg] ?? []).first { $0.trainId == id } ?? log.entry(id, chosenTrainId: legs[leg].chosenTrainId)
    }

    /// The train the rider is on as far as the phone can say: the one it settled on or the rider named, else the
    /// plan's train for the leg as the log has followed it (the ride felt but no train matched, or none settled).
    private var trainInHand: BoardingCandidate? {
        if let c = boardedCandidate { return c }
        guard let t = tracker, t.phase == .riding else { return nil }
        let leg = t.timeline.legsRidden
        guard leg < legs.count, let id = legs[leg].chosenTrainId else { return nil }
        return log.entry(id, chosenTrainId: id)
    }

    /// The train in hand as the phone can best say, for the planner's offer of an earlier change.
    var rideTrain: BoardingCandidate? { tracker?.onTrain == true ? trainInHand : nil }

    /// The planner's offer of a change short of the route's own, or nil when there is none to make here and now.
    mutating func offerEarlyChange(_ ch: EarlyChange?, alightTs: Double?) {
        let new = ch.flatMap { c in alightTs.map { (c, $0) } }
        if new?.0 == earlyChange?.change, new?.1 == earlyChange?.alightTs { return }
        earlyChange = new
    }

    /// The rider says they took the change on offer (the trip bar, the sheet, the Live Activity): the ride in hand closes
    /// at the change, as an alighting the sensors could not feel (two steps across the platform onto a train standing
    /// there), and the planner moves the route there and onto the connection. Oct 22 and 27 at Jay St: the A taken
    /// across the platform, the route left counting stops to W 4 St on the F until the rider walked off at 14 St.
    mutating func takeEarlyChange(now: Double? = nil) {
        guard let offer = earlyChange else { return }
        takeChange(offer.change, alightTs: offer.alightTs, now: now)
    }

    /// The rider names a change they made (any from the "On a train?" sheet, offered or not): on the train, the ride in
    /// hand closes there as an alighting no sensor felt; already off it (the phone felt the walk-off), the leg stands.
    /// Either way the planner moves the route to that change and onto its connection. `waiting`: the rider said they are not
    /// on a train, so the connection is the next pull-away felt, not one that already left.
    mutating func takeChange(_ change: EarlyChange, alightTs: Double, now: Double? = nil, waiting: Bool = false) {
        let now = now ?? lastNow ?? Date().timeIntervalSince1970
        guard let t = tracker, t.phase == .riding else { return }
        let at = min(alightTs, now)
        tracker?.riderChanged(at: at, legs: change.option.legs.count, transferStation: change.stationName)
        tracker?.noteChangedEarly(at: now)
        handleEvents()
        offPlanAlighting = nil          // the planner follows the change named, not a stop read off the train's times
        earlyChange = nil
        changedEarly = ChangedEarly(change: change, alightTs: at, ts: now, waiting: waiting)
    }

    // MARK: - the clock and the end

    /// Every few seconds: the tracker's clock (an arrival confirmed, a ride assumed with the sensors off, the trip over).
    mutating func tick(now: Double) {
        lastNow = now
        tracker?.tick(now: now)
        checkAssumed()
    }

    /// The rider ends the route by hand ("End route", "End" on the Live Activity), whatever the phone believes.
    mutating func endByHand(now: Double) { tracker?.endByHand(now: now) }

    /// A note on the record of the route in progress (`TripTracker.noteDev`), with the belief in hand.
    @discardableResult
    mutating func noteDev(_ text: String, preset: String? = nil, via: String, at ts: Double) -> DevNote? {
        let b = currentBelief
        return tracker?.noteDev(text, preset: preset, via: via, at: ts, belief: b)
    }

    @discardableResult
    mutating func writeDevMark(at ts: Double, text: String, preset: String? = nil, now: Double) -> Bool {
        tracker?.writeDevMark(at: ts, text: text, preset: preset, now: now) ?? false
    }

    @discardableResult
    mutating func dropDevMark(at ts: Double) -> Bool { tracker?.dropDevMark(at: ts) ?? false }

    /// The trip over: its record, and the session cleared for the next route.
    mutating func end(by: String, now: Double) -> TripTimeline? {
        guard var t = tracker else { return nil }
        let tl = t.end(now: now, by: by)
        self = RideSession(stopCoordinate: stopCoordinate, linePrior: linePrior)
        return tl
    }
}
