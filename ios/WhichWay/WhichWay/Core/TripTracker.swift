import Foundation

/// Where a route in progress stands: heading to the origin station, at it, on the train, or done.
enum TripPhase: String, Codable { case approaching, atStation, riding, arrived }

/// What one trip looked like, as the phone saw it: when the rider reached the station, stopped walking (the
/// platform), the train left and the rider walked off; how far and how long they walked on the street; the
/// forecast they acted on. Feeds the personal model and, if shared, the anonymous telemetry.
struct TripTimeline: Codable, Equatable {
    var startTs: Double
    var startedBy: String                 // "gps" | "hand"
    var startDistanceM: Double?           // to the origin station when the route started
    var placeId: String?                  // a pinned place the rider started from, if any
    var originStation: String
    var destStation: String
    var transferStation: String?
    var legs: Int
    var arrivedStationTs: Double?         // within the station radius, or the first departure the sensors saw
    var platformTs: Double?               // walking stopped after arriving: on the platform
    var platformObserved = false          // platformTs came from the sensors (else from the departure itself)
    var walkMeters = 0.0                  // on the street, toward the station
    var walkSeconds = 0.0
    var events: [MotionEvent] = []
    var motionSeconds = 0
    var walkingSecondsBetweenTrains = 0.0
    var rideAssumed = false               // no sensors: riding assumed once the boarding time had passed
    var forecastBoardTs: Double?          // frozen when the sensors see the train leave
    var forecastArriveTs: Double?
    var liveArriveTs: Double?             // keeps following the planner, for ending the trip
    var endedTs: Double?
    var endedBy: String?                  // arrived | alighted | walked | timeout | hand | changed | off
    var rideStops: [Int] = []             // station stops felt on each ride, the alighting stop included
    var boarded: [BoardedLeg] = []        // the train and line each leg was ridden on, as far as the phone could tell
    var withdrawnDepartures: [Double]? = nil   // pull-aways felt that no train made (the platform shaking), withdrawn
    var stopSpans: [FeltStop] = []        // every station stop felt on each ride: the train at rest, then moving again
    var beliefLog: [BeliefNote] = []      // each change in the train the phone believes the rider is on, as it happened

    /// Legs ridden so far: the number of alightings the sensors saw.
    var legsRidden: Int { events.filter { $0.kind == .alighted }.count }

    /// Seconds from the station radius to standing on the platform, when the sensors saw both.
    var accessSec: Double? {
        guard platformObserved, let a = arrivedStationTs, let p = platformTs, p >= a else { return nil }
        return p - a
    }

    /// Seconds walking between leaving the first train and the second one leaving, on a two-leg trip.
    var transferWalkSec: Double? {
        guard legs > 1, let off = events.firstIndex(where: { $0.kind == .alighted }),
              events[(off + 1)...].contains(where: { $0.kind == .departed }) else { return nil }
        return walkingSecondsBetweenTrains
    }

    /// The first departure within five minutes of the forecast boarding time.
    var corroboratedDepartureTs: Double? {
        guard let b = forecastBoardTs else { return nil }
        return events.first { $0.kind == .departed && abs($0.ts - b) <= 300 }?.ts
    }

    var walkSpeedMPerMin: Double? { walkMeters >= 150 && walkSeconds >= 60 ? walkMeters / walkSeconds * 60 : nil }
}

/// A change in what the phone believes about one leg's train: when, the line and train it now names, how sure, and on
/// what evidence. Kept so a trip can be read back afterwards (Oct 13: the right F named, then a later train asked about,
/// and nothing on the record to say when or why).
struct BeliefNote: Codable, Equatable {
    var ts: Double
    var leg: Int
    var key: String
    var trainId: String?
    var confidence: Double
    var verdict: String
    var evidence: [String]
}

/// One station stop the sensors felt on a ride: the train came to rest at `start` (quiet: no push, no shake, no
/// steps, for the tracker's `stopQuietSec`) and moved again at `end` (nil while it stands, or when the rider walked
/// off there: the alighting stop, `alighting`). `ride` counts the rides on the record, 0 the first. The training
/// corpus names the station of each from the train's own times (`make corpus`).
struct FeltStop: Codable, Equatable {
    var ride: Int
    var start: Double
    var end: Double?
    var alighting: Bool = false
}

/// Follows a route in progress from location fixes, summarised motion and the clock, and decides when it is
/// over so the rider need not say so. A route may start anywhere: the rider walks up to the station
/// (approaching), reaches it (at the station), the train leaves (riding), and they walk off at the end.
struct TripTracker {
    var stationRadiusM = 150.0
    var destRadiusM = 250.0
    var platformStillSec = 20             // standing still this long after arriving: on the platform
    var walkOffSec = 180                  // walking this long near the end of the ride: off the train
    var lateGraceSec = 600.0              // this long past the expected arrival with no sign: over
    var assumeRideAfterSec = 120.0        // riding once the boarding time is this far past with no departure felt
    var stopQuietSec = 12                 // riding, no push and no shake this long: the train is standing at a station
    var startGraceSec = 15.0              // a "departure" this soon after sensing began is the phone being put away
    var destFarRadiusM = 800.0            // this close to the destination once the expected arrival is well past: over
    var awaySpeedMps = 4.0                // on the way to the station yet moving away from it this fast, for this long: on a train already
    var awaySeconds = 30.0
    var usableAccuracyM = 100.0           // a fix less sure than this says nothing about where the rider is
    var preciseAccuracyM = 65.0           // speeds (the walk, a train pulling away) only from fixes this sure
    var minRideSec = 45.0                 // steps sooner than this after a felt pull-away: it was the stairs or the platform, not a ride
                                          // (the recorder sets it from the schedule: 0.6 of the run to the first stop, 45 s at least)

    private(set) var phase: TripPhase
    private(set) var timeline: TripTimeline
    private(set) var motionState: MotionState = .unknown
    private var detector = BoardingDetector()
    private var stillRun = 0
    private var walkRun = 0
    private var afterAlight = false
    private var alightedAll = false
    private var lastFix: (ts: Double, toOrigin: Double, acc: Double)?
    private var awayRun = 0.0
    private var lastDest: (ts: Double, toDest: Double)?
    private var hasMotion = false
    private var firstMotionTs: Double?
    private var quietRun = 0
    /// Station stops felt on the ride in progress (the train standing still, then moving again).
    private(set) var stopsFelt = 0
    /// When each station stop of the ride in progress began (the stop in hand included), for the line inference.
    private(set) var stopTimes: [Double] = []
    /// The stop times of the ride that just ended, kept until the next departure.
    private(set) var lastRideStopTimes: [Double] = []
    private var quietStartTs: Double?
    private var walkStartTs: Double?
    /// The last few seconds, to tell whether a departure was the train's own push or only shaking.
    private var recent: [MotionSecond] = []
    /// A departure called from shaking alone (people boarding a standing train jostle the phone): until this moment
    /// the train's own pull-away, a sustained push, may still come, and the departure moves to it.
    private var refineUntil: Double?
    private var refinePush = 0
    /// How long after a departure called from shaking the train's own push is looked for, and how long it must last.
    var refineWindowSec = 45.0
    var refinePushSec = 3
    /// Steps after such a departure say the rider was still boarding: the window runs on from them, to this long after it.
    var refineMaxSec = 120.0
    /// The pull-away starts from rest: the 10 s before the push hold a median push under this (Oct 13: 0.011 and 0.004 g
    /// before the F's pull-aways at W 4 St and 4 Av-9 St; 0.019 g cruising before the F braked into Smith-9 Sts, Oct 12).
    var restPushG = 0.015
    private var refineFrom: Double?
    /// A departure moved to the train's own push: the ride (0 the first) whose pull-away changed, for the recorder to
    /// read the trains again. Cleared by `takeAmendedRide`.
    private(set) var amendedRide: Int?
    mutating func takeAmendedRide() -> Int? { defer { amendedRide = nil }; return amendedRide }
    /// The walking between trains counted so far, as it stood at each departure on the record (in order): what a
    /// withdrawn first ride's shuffle added to it can be taken back out.
    private var walkAtDeparture: [Double] = []

    /// The ride in hand began from the phone's movement (moving away from the station at a train's pace), not
    /// from a felt pull-away at the platform.
    private(set) var departedByLocation = false

    /// Riding and standing at a station since this moment (nil while moving).
    var standingSince: Double? { phase == .riding && quietRun >= stopQuietSec ? quietStartTs : nil }

    /// On a train right now: the ride's pull-away was felt (or named, or assumed from the timetable) and no walk-off
    /// since. False between trains at the change, where the phase is still `.riding`.
    var onTrain: Bool { phase == .riding && (timeline.rideAssumed || timeline.events.last?.kind == .departed) }

    /// Riding and walking right now: when the steps began and for how many seconds they have gone on. The
    /// recorder reads it against the feed: steps that begin while the believed train stands at a station are
    /// the rider getting off, even when the detector could not see the train come to rest first.
    var walking: (startTs: Double, seconds: Int)? {
        guard phase == .riding, walkRun > 0, let s = walkStartTs else { return nil }
        return (s, walkRun)
    }

    /// The last second the phone felt the train moving (a push or vibration) on the ride in hand.
    private(set) var lastMovingTs: Double?

    init(_ start: TripTimeline, distanceToOriginM: Double?) {
        timeline = start
        if let d = distanceToOriginM, d <= stationRadiusM {
            phase = .atStation
            timeline.arrivedStationTs = start.startTs
        } else {
            phase = .approaching
        }
    }

    /// A location fix: on the way, the distance closed toward the station at a walking pace is the rider's
    /// street speed; within the radius the rider is at the station; near the destination the trip is over.
    /// `accuracyM` is the fix's own uncertainty: one worse than `usableAccuracyM` (a fix from cell towers, or
    /// one under a station roof) changes nothing, and speeds come only from `preciseAccuracyM` fixes. Unknown
    /// accuracy counts as precise (the package tests, a simulator).
    mutating func location(ts: Double, toOriginM: Double?, toDestM: Double?, now: Double, accuracyM: Double? = nil) {
        guard phase != .arrived else { return }
        let acc = accuracyM.map { $0 < 0 ? Double.infinity : $0 } ?? 0
        guard acc <= usableAccuracyM else { checkDestination(now: now); return }
        if phase == .approaching, let d = toOriginM {
            if let last = lastFix, ts > last.ts, max(acc, last.acc) <= preciseAccuracyM {
                let dt = ts - last.ts, gained = last.toOrigin - d
                if dt >= 5, dt <= 120, gained > 0, gained / dt >= 0.4, gained / dt <= 2.5 {
                    timeline.walkMeters += gained
                    timeline.walkSeconds += dt
                }
                // past the station and pulling away from it at a train's pace: the rider is on a train already (a route
                // started on the way); which train is for the rider or the feeds to say
                if dt >= 5, dt <= 180, d > stationRadiusM * 2, -gained / dt >= awaySpeedMps {
                    awayRun += dt
                    if awayRun >= awaySeconds {
                        lastFix = (ts, d, acc)
                        beginRiding(now: now, departedTs: ts - awayRun)
                        departedByLocation = true
                        checkDestination(now: now)
                        return
                    }
                } else {
                    awayRun = 0
                }
            }
            lastFix = (ts, d, acc)
            // within the radius, give or take half the fix's own uncertainty
            if d <= stationRadiusM + acc / 2 {
                phase = .atStation
                timeline.arrivedStationTs = ts
                stillRun = 0
            }
        }
        if let dd = toDestM { lastDest = (ts, max(0, dd - acc / 2)) }
        checkDestination(now: now)
    }

    /// Within 250 m of the destination station, on a fix no older than ten minutes, once the expected arrival is
    /// within five minutes (or, riding with no forecast at all, at once): the trip is over. The phone sitting
    /// still at the destination sends no new fix, so the clock asks too.
    private mutating func checkDestination(now: Double) {
        guard phase != .arrived, let d = lastDest, now - d.ts <= 600 else { return }
        if d.toDest <= destRadiusM {
            if let pa = timeline.liveArriveTs {
                if now >= pa - 300 { finish(now, by: "arrived") }
            } else if phase == .riding {
                finish(now, by: "arrived")
            }
        } else if d.toDest <= destFarRadiusM, let pa = timeline.liveArriveTs, now >= pa + 120, phase == .riding || phase == .atStation {
            // well past the expected arrival and within a short walk of the destination: the rider has come and gone
            finish(now, by: "arrived")
        }
    }

    /// One summarised second of motion.
    mutating func motion(_ m: MotionSecond) {
        guard phase != .arrived else { return }
        hasMotion = true
        if firstMotionTs == nil { firstMotionTs = m.ts }
        recent.append(m)
        if recent.count > 16 { recent.removeFirst(recent.count - 16) }
        refineDeparture(m)
        timeline.motionSeconds += 1
        let walking = m.stepEnergy > detector.stepThreshold
        if walking {
            if walkRun == 0 { walkStartTs = m.ts }
            walkRun += 1; stillRun = 0
        } else {
            stillRun += 1; walkRun = 0; walkStartTs = nil
        }
        if afterAlight, walking { timeline.walkingSecondsBetweenTrains += 1 }
        if phase == .riding, !walking, m.pushG >= detector.pushThreshold || m.shakeG >= detector.shakeThreshold { lastMovingTs = m.ts }
        if phase == .atStation, timeline.platformTs == nil, stillRun >= platformStillSec {
            timeline.platformTs = m.ts - Double(platformStillSec - 1)
            timeline.platformObserved = true
        }
        let riding = detector.state == .riding
        if let e = detector.feed(m) {
            // the first seconds after sensing starts are the rider tapping Start and pocketing the phone, not a train
            if e.kind == .departed, let f = firstMotionTs, m.ts - f < startGraceSec {
                detector.standDown()
                motionState = detector.state
                return
            }
            // still on the way to the station by a fresh fix: a push on the street (a bus, a car, a jog) is not a train
            if e.kind == .departed, phase == .approaching, let f = lastFix, m.ts - f.ts < 120, f.toOrigin - f.acc > 300 {
                detector.standDown()
                motionState = detector.state
                return
            }
            // a walk-off sooner after the pull-away than the train could have reached its first stop: the pull-away was the
            // stairs or the platform, not a ride (Oct 10 at 7 Av: "departed" 16:50:29 on the way down, steps 39 s later closed
            // the route as the real F pulled in, and a second route started under the rider). The departure is withdrawn:
            // the rider is at the station and the next sustained push or vibration counts afresh.
            if e.kind == .alighted, !departedByLocation, let dep = timeline.events.last, dep.kind == .departed, e.ts - dep.ts < minRideSec {
                timeline.withdrawnDepartures = (timeline.withdrawnDepartures ?? []) + [dep.ts]
                notOnTrain()
                return
            }
            timeline.events.append(e)
            switch e.kind {
            case .departed:
                walkAtDeparture.append(timeline.walkingSecondsBetweenTrains)
                // called from shaking, not the train's push: watch for the push (Oct 13 at W 4 St: the jostle of boarding
                // at 17:50:23, the F's own pull-away at 17:50:52, its feed time 17:50:53)
                let pushed = recent.filter { $0.ts >= e.ts && $0.ts < e.ts + Double(refinePushSec) }
                refineUntil = pushed.count >= refinePushSec && pushed.allSatisfy({ $0.pushG >= detector.pushThreshold }) ? nil : e.ts + refineWindowSec
                refineFrom = e.ts
                refinePush = 0
                // every leg was ridden and the rider is on a train again: the count was off (a ride that was not one, or a
                // change the plan did not have), so the trip is not over at the clock; the next walk-off says so again
                alightedAll = false
                afterAlight = false
                departedByLocation = false
                stopsFelt = 0; quietRun = 0; stopTimes = []; quietStartTs = nil
                timeline.rideAssumed = false          // a ride assumed from the schedule is now a ride felt
                if phase != .riding {
                    if timeline.arrivedStationTs == nil { timeline.arrivedStationTs = e.ts }
                    if timeline.platformTs == nil { timeline.platformTs = e.ts }
                    phase = .riding
                }
            case .alighted:
                afterAlight = true
                if quietRun >= stopQuietSec { stopsFelt += 1 }    // the stop the rider got off at
                markAlighting(at: e.ts)
                timeline.rideStops.append(stopsFelt)
                lastRideStopTimes = stopTimes
                stopsFelt = 0; quietRun = 0; stopTimes = []; quietStartTs = nil
                timeline.walkingSecondsBetweenTrains += Double(walkRun)   // the steps that confirmed the alighting
                if timeline.events.filter({ $0.kind == .alighted }).count >= timeline.legs { alightedAll = true }
            }
        } else if riding {
            // a station stop: a quiet spell (no push, no shake, no steps) long enough to be a dwell, then motion again
            let quiet = !walking && m.pushG < detector.pushThreshold && m.shakeG < detector.shakeThreshold
            if quiet {
                quietRun += 1
                if quietRun == stopQuietSec {
                    let start = m.ts - Double(stopQuietSec - 1)
                    quietStartTs = start
                    stopTimes.append(start)
                    timeline.stopSpans.append(FeltStop(ride: max(0, rideCount - 1), start: start))
                }
            } else {
                if quietRun >= stopQuietSec { stopsFelt += 1; closeSpan(at: m.ts) }
                quietRun = 0; quietStartTs = nil
            }
        }
        motionState = detector.state
        if phase == .riding, walkRun >= walkOffSec, let pa = timeline.liveArriveTs, m.ts >= pa - 180 {
            finish(m.ts, by: "walked")
        }
    }

    /// The clock: confirms an arrival the sensors saw, assumes the ride from the schedule when no departure was
    /// felt, and gives up well past the expected arrival.
    ///
    /// The assumption: a chosen route is taken as planned. At the station, once the boarding time of the train
    /// the rider was waiting for is two minutes past, they are on it, whether the sensors are off or just missed
    /// the pull-away (a phone deep in a bag). With sensors the rider must have reached the platform (stood still
    /// after arriving) first, so someone still on the stairs is not put on a train. A departure felt later turns
    /// the assumed ride into a measured one, and the line inference re-reads which train it was.
    mutating func tick(now: Double) {
        guard phase != .arrived else { return }
        let pa = timeline.liveArriveTs
        if alightedAll, pa == nil || now >= pa! - 120 { finish(now, by: "alighted"); return }
        if phase == .atStation, let pb = timeline.forecastBoardTs, now >= pb + assumeRideAfterSec, !hasMotion || timeline.platformTs != nil {
            phase = .riding
            timeline.rideAssumed = true
            if timeline.platformTs == nil { timeline.platformTs = pb }
        }
        checkDestination(now: now)
        if phase != .arrived, let pa = pa, now >= pa + lateGraceSec { finish(now, by: "timeout") }
    }

    /// The planner's latest forecast. It stops following once the rider is on the train, or is at the
    /// station when the boarding time passes (the planner then moves on to the next train, but the rider
    /// presumably took this one); on the way to the station it keeps following.
    mutating func updateForecast(boardTs: Double?, arriveTs: Double?, now: Double) {
        guard phase != .riding, phase != .arrived else { return }
        if phase == .atStation, let b = timeline.forecastBoardTs, now >= b { return }
        timeline.liveArriveTs = arriveTs ?? timeline.liveArriveTs
        timeline.forecastBoardTs = boardTs
        timeline.forecastArriveTs = arriveTs
    }

    /// The train the forecast named has gone from the feed a little before its predicted platform moment (the feed
    /// moves a train on as it leaves, and its ETA for the stop ran a few seconds optimistic: Oct 9, gone at 3:00:49
    /// against 3:01:05). At the station, that is the train leaving now: the forecast freezes here and the assumed
    /// ride is counted from this moment. Without this, `updateForecast` follows the planner on to the next train,
    /// the predicted time never having passed, and with no felt departure the ride is never assumed. `graceSec`
    /// bounds how early a drop may come and still be that train leaving; a train gone five minutes ahead of its
    /// time was withdrawn, not taken.
    mutating func forecastTrainDeparted(now: Double, graceSec: Double = 90) {
        guard phase == .atStation, let b = timeline.forecastBoardTs, b > now, b - now <= graceSec else { return }
        timeline.forecastBoardTs = now
    }

    /// The rider got off without walking: a same-platform change, told by the feed (the train they were on has
    /// moved past the transfer stop while the phone has stood still there since `ts`). Closes the ride as an
    /// alighting at `ts`; the next push or vibration the sensors feel is the next train leaving.
    mutating func alightStanding(at ts: Double) {
        guard phase == .riding else { return }
        if quietRun >= stopQuietSec { stopsFelt += 1; closeSpan(at: nil) }
        markAlighting(at: ts)
        timeline.rideStops.append(stopsFelt)
        lastRideStopTimes = stopTimes
        stopsFelt = 0; quietRun = 0; stopTimes = []; quietStartTs = nil
        afterAlight = true
        timeline.events.append(MotionEvent(kind: .alighted, ts: ts))
        detector.standDown()
        motionState = detector.state
        if timeline.events.filter({ $0.kind == .alighted }).count >= timeline.legs { alightedAll = true }
    }

    /// The rider walked off at a station the feed vouches for: the steps that began at `ts` started while the train
    /// the phone believes they were on stood at a stop, so they are the rider getting off even though the detector
    /// never saw the train come to rest (a quick change across the platform, Oct 8 at Jay St twice). Closes the ride
    /// as an alighting at `ts`; the walk goes on as the change, and the next pull-away is the next train.
    mutating func alightWalking(at ts: Double) {
        guard phase == .riding else { return }
        if quietRun >= stopQuietSec { stopsFelt += 1; closeSpan(at: ts) }
        markAlighting(at: ts)
        timeline.rideStops.append(stopsFelt)
        lastRideStopTimes = stopTimes
        stopsFelt = 0; quietRun = 0; stopTimes = []; quietStartTs = nil
        afterAlight = true
        timeline.events.append(MotionEvent(kind: .alighted, ts: ts))
        timeline.walkingSecondsBetweenTrains += Double(walkRun)
        detector.standDown()
        motionState = .walking
        if timeline.events.filter({ $0.kind == .alighted }).count >= timeline.legs { alightedAll = true }
    }

    /// The rider says they are not on a train: the departure the sensors felt is withdrawn, they are back at the
    /// station waiting, and the next pull-away counts afresh.
    mutating func notOnTrain() {
        guard phase == .riding, let last = timeline.events.last, last.kind == .departed else { return }
        let ride = rideCount - 1
        timeline.events.removeLast()
        timeline.stopSpans.removeAll { $0.ride == ride }
        if !walkAtDeparture.isEmpty { walkAtDeparture.removeLast() }
        alightedAll = timeline.legsRidden >= timeline.legs     // as it stood before the pull-away that was not one
        refineUntil = nil
        if timeline.events.last?.kind == .alighted {
            // after a change: back between trains at the transfer platform, not at the origin (Oct 13 at W 4 St the phone
            // then assumed a ride on a later F from the timetable while the rider was on the earlier one)
            afterAlight = true
        } else {
            phase = .atStation
        }
        if timeline.arrivedStationTs == nil { timeline.arrivedStationTs = last.ts }
        stopsFelt = 0; quietRun = 0; stopTimes = []; quietStartTs = nil
        timeline.rideAssumed = false
        detector.standDown()
        motionState = detector.state
        firstMotionTs = nil                  // the grace period runs again from here
    }

    /// The rider says they are on a train already, having left the station at `departedTs` (a route started from
    /// the train, or one that never saw the pull-away): the ride is on from here, with that departure on the
    /// record, and the sensors watch for the stops and the alighting as after a felt departure.
    mutating func beginRiding(now: Double, departedTs: Double) {
        guard phase != .arrived, phase != .riding else { return }
        let dep = min(departedTs, now)
        if timeline.arrivedStationTs == nil { timeline.arrivedStationTs = dep }
        if timeline.platformTs == nil { timeline.platformTs = dep }
        timeline.events.append(MotionEvent(kind: .departed, ts: dep))
        walkAtDeparture.append(timeline.walkingSecondsBetweenTrains)
        alightedAll = false
        timeline.rideAssumed = false
        phase = .riding
        afterAlight = false
        stopsFelt = 0; quietRun = 0; stopTimes = []; quietStartTs = nil
        detector.assumeRiding(since: dep)
        motionState = detector.state
        if firstMotionTs == nil { firstMotionTs = now - startGraceSec }
    }

    /// The route changed under the rider (they boarded a line off the plan and the planner found the route that
    /// rides it): the legs still to ride and the change follow the new route, so the trip ends at the right
    /// alighting and not at a change the old route had, or never.
    mutating func replan(legs: Int, transferStation: String?) {
        guard phase != .arrived else { return }
        timeline.legs = max(1, legs)
        timeline.transferStation = transferStation
        alightedAll = timeline.legsRidden >= timeline.legs
    }

    /// The arrival as the train the rider is actually on makes it (its own progress in the feed, and the connection
    /// it makes): the clock the trip ends by. The forecast the rider acted on is kept as it was.
    mutating func setLiveArrival(_ ts: Double) {
        guard phase != .arrived else { return }
        timeline.liveArriveTs = ts
    }

    /// A pull-away the feed says no train made (none left the platform then while others are still to come): the
    /// rider is still at the station, the next sustained push or vibration counts afresh, and the record keeps it.
    mutating func withdrawDeparture() {
        guard phase == .riding, let last = timeline.events.last, last.kind == .departed else { return }
        notOnTrain()
        timeline.withdrawnDepartures = (timeline.withdrawnDepartures ?? []) + [last.ts]
    }

    /// Rides on the record so far (felt, named or assumed pull-aways).
    private var rideCount: Int { timeline.events.filter { $0.kind == .departed }.count }

    /// The station stop in hand is over: the train moved again at `ts`, or the rider got off there.
    private mutating func closeSpan(at ts: Double?) {
        guard let i = timeline.stopSpans.indices.last, timeline.stopSpans[i].end == nil, timeline.stopSpans[i].ride == max(0, rideCount - 1) else { return }
        timeline.stopSpans[i].end = ts
    }

    /// The walk-off at `ts` was at the ride's last felt stop when that stop ended (the steps began) about then; the
    /// stop the rider left the train at. The walk that ends the quiet spell closes it before the alighting is told.
    private mutating func markAlighting(at ts: Double) {
        guard let i = timeline.stopSpans.indices.last, timeline.stopSpans[i].ride == max(0, rideCount - 1) else { return }
        // an open span is a change on the same platform: the rider stood on as the train left, so its end is unknown
        if timeline.stopSpans[i].end.map({ abs(ts - $0) <= 20 }) ?? true { timeline.stopSpans[i].alighting = true }
    }

    /// A departure called from shaking moves to the train's own pull-away when that comes within `refineWindowSec`: a
    /// push held for `refinePushSec` seconds with no steps. The stop spans, stop times and walking marks of the ride
    /// start from the departure, so nothing else moves.
    private mutating func refineDeparture(_ m: MotionSecond) {
        guard let until = refineUntil, let from = refineFrom else { return }
        guard m.ts <= until, phase == .riding, let i = timeline.events.indices.last, timeline.events[i].kind == .departed else { refineUntil = nil; return }
        if m.stepEnergy > detector.stepThreshold {
            // still walking: boarding, so the train has not left yet; the window runs on from here
            refinePush = 0
            refineUntil = min(from + refineMaxSec, max(until, m.ts + refineWindowSec))
            return
        }
        if m.pushG >= detector.pushThreshold { refinePush += 1 } else { refinePush = 0 }
        guard refinePush >= refinePushSec else { return }
        let start = m.ts - Double(refinePushSec - 1)
        // from rest, not from cruising: a push that follows a run is the train braking for the next station
        let before = recent.filter { $0.ts >= start - 10 && $0.ts < start }.map(\.pushG).sorted()
        guard before.count >= 5, before[before.count / 2] <= restPushG else { refinePush = 0; return }
        refineUntil = nil
        guard start - timeline.events[i].ts >= 5 else { return }
        timeline.events[i].ts = start
        let ride = rideCount - 1
        stopTimes = stopTimes.filter { $0 >= start }
        timeline.stopSpans.removeAll { $0.ride == ride && $0.start < start }
        amendedRide = ride
    }

    /// The departure and walk-off of ride `k` (0 the first), as the record holds them.
    func ride(_ k: Int) -> (departedTs: Double, alightedTs: Double?)? {
        let deps = timeline.events.filter { $0.kind == .departed }, alis = timeline.events.filter { $0.kind == .alighted }
        guard deps.indices.contains(k) else { return nil }
        return (deps[k].ts, alis.indices.contains(k) ? alis[k].ts : nil)
    }

    /// Ride `k` was not one: its pull-away was another platform's train shaking this one and its walk-off a few steps
    /// on the platform (Oct 12 at 4 Av-9 St). Both are struck from the record, the rides after it move up a leg (the
    /// F the rider then took is the first leg, not the change), and the trip stands where that leaves it: on the train
    /// of a later ride, between trains, or still at the origin station. The pull-away is kept as withdrawn.
    mutating func withdrawRide(_ k: Int) {
        guard phase != .arrived else { return }
        let deps = timeline.events.indices.filter { timeline.events[$0].kind == .departed }
        let alis = timeline.events.indices.filter { timeline.events[$0].kind == .alighted }
        guard deps.indices.contains(k), alis.indices.contains(k), alis[k] > deps[k] else { return }
        let depTs = timeline.events[deps[k]].ts
        if k == 0 {
            // before the first real ride, steps are the way to the platform, not a change between trains
            let upTo = walkAtDeparture.indices.contains(1) ? walkAtDeparture[1] : timeline.walkingSecondsBetweenTrains
            let from = walkAtDeparture.first ?? 0
            timeline.walkingSecondsBetweenTrains = max(0, timeline.walkingSecondsBetweenTrains - (upTo - from))
            for i in walkAtDeparture.indices.dropFirst(2) { walkAtDeparture[i] = max(0, walkAtDeparture[i] - (upTo - from)) }
            if !timeline.platformObserved, timeline.platformTs == depTs { timeline.platformTs = deps.indices.contains(1) ? timeline.events[deps[1]].ts : nil }
        }
        timeline.events.remove(at: alis[k])
        timeline.events.remove(at: deps[k])
        if walkAtDeparture.indices.contains(k) { walkAtDeparture.remove(at: k) }
        if timeline.rideStops.indices.contains(k) { timeline.rideStops.remove(at: k) }
        timeline.stopSpans = timeline.stopSpans.filter { $0.ride != k }.map { var sp = $0; if sp.ride > k { sp.ride -= 1 }; return sp }
        timeline.boarded = timeline.boarded.filter { $0.leg != k }.map { var b = $0; if b.leg > k { b.leg -= 1 }; return b }
        timeline.withdrawnDepartures = (timeline.withdrawnDepartures ?? []) + [depTs]
        alightedAll = timeline.legsRidden >= timeline.legs && timeline.events.last?.kind == .alighted
        switch timeline.events.last?.kind {
        case .departed?:
            phase = .riding; afterAlight = false              // on the train of a later ride; the sensors carry on with it
        case .alighted?:
            phase = .riding; afterAlight = true               // between trains at the change
        case nil:
            phase = .atStation; afterAlight = false
            if !timeline.platformObserved { timeline.platformTs = nil }
            stopsFelt = 0; quietRun = 0; stopTimes = []; quietStartTs = nil
            if detector.state == .riding { detector.standDown(); motionState = detector.state }
        }
    }

    /// What the line inference concluded about a leg, kept with the trip (the latest word per leg).
    mutating func setBoarded(_ b: BoardedLeg, now: Double? = nil) {
        let before = timeline.boarded.first { $0.leg == b.leg }
        if let i = timeline.boarded.firstIndex(where: { $0.leg == b.leg }) { timeline.boarded[i] = b } else { timeline.boarded.append(b) }
        // the log keeps the changes of mind (another train or line, a verdict turning, new evidence), not every poll
        if before?.trainId != b.trainId || before?.key != b.key || before?.verdict != b.verdict || before?.evidence != b.evidence, timeline.beliefLog.count < 200 {
            timeline.beliefLog.append(BeliefNote(ts: now ?? timeline.events.last?.ts ?? timeline.startTs, leg: b.leg, key: b.key, trainId: b.trainId,
                                                 confidence: (b.confidence * 100).rounded() / 100, verdict: b.verdict.rawValue, evidence: b.evidence))
        }
    }

    mutating func end(now: Double, by: String) -> TripTimeline {
        if phase != .arrived { finish(now, by: by) }
        return timeline
    }

    private mutating func finish(_ ts: Double, by: String) {
        phase = .arrived
        timeline.endedTs = ts
        timeline.endedBy = by
    }
}
