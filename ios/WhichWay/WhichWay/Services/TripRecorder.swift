import Foundation
import Observation

/// Runs a route in progress on the phone: the motion sensors (when either opt-in allows them), the location fixes, the
/// feed's boards and the clock go into the `RideSession` (Core), which makes every decision; this class keeps the
/// sensors, the disk, the trace and the Live Activity, and mirrors what the views read. When the trip ends, what it
/// measured goes to the rider's own pace model and, if shared, to the anonymous telemetry.
@MainActor
@Observable
final class TripRecorder {
    static let shared = TripRecorder()

    private(set) var phase: TripPhase?
    private(set) var endReason: String?
    private(set) var motionState: MotionState = .unknown
    private(set) var motionSeconds = 0
    private(set) var walkMeters = 0.0
    private(set) var rideAssumed = false
    /// A felt pull-away waiting on the feed ("Boarding?"): the tracker's own word, kept here so the views follow it.
    private(set) var boardingPending = false
    /// Per leg, what the phone believes about the train the rider boarded, as far as the evidence has got.
    private(set) var beliefs: [LineBelief] = []
    /// Set when the rider walked off at a stop the route did not plan to leave the train at.
    private(set) var offPlanAlighting: OffPlanAlighting?
    /// Set when the rider rode on past the stop the route had them leave the train at.
    private(set) var stayedOn: StayedOn?
    /// The change short of the route's own on offer right now (the planner sets it from the train in hand), with when
    /// the rider would have stepped off there: the trip bar and the Live Activity show it as one tap.
    private(set) var earlyChange: (change: EarlyChange, alightTs: Double)?
    /// Set when the rider took the offer: the planner follows (`ChangedEarly`).
    private(set) var changedEarly: ChangedEarly?
    /// The rider's notes on the route in progress (`DevNote`), as on its record.
    private(set) var devNotes: [DevNote] = []

    @ObservationIgnored private var session = RideSession()
    @ObservationIgnored private let sampler = MotionSampler()
    /// Position of a stop on a line (line key, stop index), from the published geometry; set by the planner.
    var stopCoordinate: ((String, Int) -> (lat: Double, lon: Double)?)? {
        get { session.stopCoordinate }
        set { session.stopCoordinate = newValue }
    }
    /// The changes the rider could have made off the train in hand toward the destination (the planner's
    /// `changesOnTheWay`), for reading "not on the train" from the Live Activity as well as the app.
    var changesOnTheWay: (() -> [EarlyChange])? {
        get { session.changesOnTheWay }
        set { session.changesOnTheWay = newValue }
    }

    init() {
        // what this rider has ridden on this very trip, else the line they usually board at this platform (after the
        // line just ridden, at a change) at about this hour
        session.linePrior = { plan, leg, k, timeline, ts in
            PersonalModelStore.shared.model.chosenLineShare(origin: plan.origin, dest: plan.dest, leg: leg, chosenKey: k)
                ?? HabitStore.shared.linePrior(boardingAt: leg == 0 ? plan.origin : (timeline.transferStation ?? ""), leg: leg, toward: plan.dest,
                                               after: timeline.boarded.first { $0.leg == leg - 1 }?.key, now: ts)?.share(k)
        }
    }

    var sensing: Bool { sampler.isRunning }
    private var tracker: TripTracker? { session.tracker }

    var currentBelief: LineBelief? { session.currentBelief }
    func belief(leg: Int) -> LineBelief? { session.belief(leg: leg) }
    var prompt: BoardingPrompt? { session.prompt }
    var needsTrainPick: Bool { session.needsTrainPick }
    var onTrain: Bool { session.onTrain }
    var onTrainShown: Bool { session.onTrainShown }
    func needsPreciseFixes(now: Double) -> Bool { session.needsPreciseFixes(now: now) }
    func noteReroute(_ n: RerouteNote) { session.noteReroute(n) }
    func rideDepartedTs(leg: Int) -> Double? { session.rideDepartedTs(leg: leg) }
    var currentLeg: Int { session.currentLeg }
    var currentLegKeys: [String] { session.currentLegKeys }
    var currentLegChosenKey: String? { session.currentLegChosenKey }
    var forecastBoardTs: Double? { session.forecastBoardTs }
    var boardedCandidate: BoardingCandidate? { session.boardedCandidate }
    var rideTrain: BoardingCandidate? { session.rideTrain }
    func namesEarlierLeg(_ key: String) -> Bool { session.namesEarlierLeg(key) }

    func begin(_ start: TripTimeline, distanceToOriginM: Double?, observation: TripObservation?, legs: [LegPlan] = [], now: Double,
               firstRunSec: Double? = nil) {
        if tracker != nil { end(by: "changed", api: nil, now: now) }
        session.begin(start, distanceToOriginM: distanceToOriginM, legs: legs, now: now, firstRunSec: firstRunSec)
        endReason = nil
        devNotes = []
        publish()
        if let o = observation { Telemetry.shared.beginTrip(o) }
        MotionTrace.shared.begin(ts: start.startTs)
        if PersonalModelStore.shared.optIn || Telemetry.shared.optIn {
            sampler.start { [weak self] second in
                Task { @MainActor in self?.motion(second) }
            }
        }
    }

    private func motion(_ m: MotionSecond) {
        MotionTrace.shared.add(m)
        session.motion(m)
        publish()
    }

    func location(ts: Double, toOriginM: Double?, toDestM: Double?, now: Double, coordinate: (lat: Double, lon: Double)? = nil, accuracyM: Double? = nil) {
        session.location(ts: ts, toOriginM: toOriginM, toDestM: toDestM, now: now, coordinate: coordinate, accuracyM: accuracyM)
        publish()
    }

    func updateForecast(boardTs: Double?, arriveTs: Double?, now: Double) {
        session.updateForecast(boardTs: boardTs, arriveTs: arriveTs, now: now)
    }

    @discardableResult
    func forecastTrainDeparted(now: Double) -> Bool { session.forecastTrainDeparted(now: now) }

    func observeBoards(_ boards: [String: LineBoard], now: Double) {
        session.observeBoards(boards, now: now)
        publish()
    }

    func updatePlannedTrains(_ trains: [Int: (key: String, trainId: String)], now: Double) {
        session.updatePlannedTrains(trains, now: now)
    }

    func confirmBoarding() { session.confirmBoarding(); publish() }
    func setBoardedByHand(key: String) { session.setBoardedByHand(key: key); publish() }
    func confirm(trainId: String) { session.confirm(trainId: trainId); publish() }
    func dismissPrompt() { session.dismissPrompt(); publish() }
    func setOnTrain(_ c: BoardingCandidate, now: Double) { session.setOnTrain(c, now: now); publish() }
    func notOnTrain() { session.notOnTrain(now: Date().timeIntervalSince1970); publish() }
    func replan(legs newLegs: [LegPlan], transferStation: String? = nil, transferStops: String? = nil) {
        session.replan(legs: newLegs, transferStation: transferStation, transferStops: transferStops)
        publish()
    }
    func seedCurrentLeg(_ cands: [BoardingCandidate], now: Double) { session.seedCurrentLeg(cands, now: now); publish() }
    func setLiveArrival(_ ts: Double) { session.setLiveArrival(ts) }
    func offerEarlyChange(_ ch: EarlyChange?, alightTs: Double?) { session.offerEarlyChange(ch, alightTs: alightTs); publish() }
    func takeEarlyChange(now: Double? = nil) { session.takeEarlyChange(now: now ?? Date().timeIntervalSince1970); publish() }
    func takeChange(_ change: EarlyChange, alightTs: Double, now: Double? = nil, waiting: Bool = false) {
        session.takeChange(change, alightTs: alightTs, now: now ?? Date().timeIntervalSince1970, waiting: waiting)
        publish()
    }

    // MARK: - the rider's notes on how the app behaved

    /// A note on how the app is behaving right now (the trip bar's note sheet), or a mark of the moment from the Live
    /// Activity (`text` empty): on the route in progress, with what the phone believes then, and written to disk at
    /// once; with no route in progress, onto the trip just taken. False when there is no trip to put it on.
    @discardableResult
    func addNote(_ text: String, preset: String? = nil, via: String, at ts: Double? = nil) -> Bool {
        let at = ts ?? session.lastNow ?? Date().timeIntervalSince1970
        if tracker != nil {
            guard session.noteDev(text, preset: preset, via: via, at: at) != nil else { return false }
            notesChanged()
            return true
        }
        let n = DevNote(ts: at, text: text, preset: preset, via: via).believing(beliefs.last)
        return Telemetry.shared.noteRecentTrip(now: at) { $0.addNote(n) }
    }

    /// The Live Activity's note button: the moment marked, the words to follow in the app.
    func markMoment() { addNote("", via: "activity", at: Date().timeIntervalSince1970) }

    /// The words for a mark, on the route in progress or the trip just taken.
    @discardableResult
    func writeMark(at ts: Double, text: String, preset: String? = nil) -> Bool {
        let now = Date().timeIntervalSince1970
        if tracker != nil {
            guard session.writeDevMark(at: ts, text: text, preset: preset, now: now) else { return false }
            notesChanged()
            return true
        }
        return Telemetry.shared.noteRecentTrip(now: now) { $0.writeMark(at: ts, text: text, preset: preset, now: now) }
    }

    @discardableResult
    func dropMark(at ts: Double) -> Bool {
        if tracker != nil {
            guard session.dropDevMark(at: ts) else { return false }
            notesChanged()
            return true
        }
        return Telemetry.shared.noteRecentTrip(now: Date().timeIntervalSince1970) { $0.dropMark(at: ts) }
    }

    /// The notes there are to show: the route in progress's, else the trip just taken's.
    func notesInHand(now: Double) -> [DevNote] {
        tracker != nil ? devNotes : (Telemetry.shared.recentTrip(now: now)?.devNotes ?? [])
    }

    /// Whether a note has a trip to go on now.
    func canNote(now: Double) -> Bool { tracker != nil ? Telemetry.shared.optIn : Telemetry.shared.recentTrip(now: now) != nil }

    private func notesChanged() {
        guard let t = tracker else { return }
        devNotes = t.timeline.devNotes ?? []
        Telemetry.shared.checkpoint(timeline: t.timeline, now: session.lastNow ?? Date().timeIntervalSince1970)
    }

    /// "End" on the Live Activity: the route is over by hand, through the same path as an ending the tracker calls itself
    /// (the phase goes to arrived and the planner closes the route), and the lock screen clears at once rather than on the
    /// planner's next turn. Works in every phase, whatever the phone believes about the train.
    func endByHand(now: Double? = nil) {
        guard tracker != nil else { TripActivityService.shared.endAll(); return }
        session.endByHand(now: now ?? session.lastNow ?? Date().timeIntervalSince1970)
        TripActivityService.shared.end()
        publish()
    }

    func tick(now: Double) {
        session.tick(now: now)
        publish()
        // the trip in hand to disk every half minute: an app killed mid-route (a reinstall, a crash, the system
        // reclaiming memory) loses nothing; the next launch closes it as interrupted and sends it (Oct 13)
        if let t = tracker, now - lastCheckpoint >= checkpointSec {
            lastCheckpoint = now
            Telemetry.shared.checkpoint(timeline: t.timeline, now: now)
            MotionTrace.shared.checkpoint(t.timeline)
        }
    }
    @ObservationIgnored private var lastCheckpoint = 0.0
    /// How often a route in progress is written to disk.
    var checkpointSec = 30.0

    /// The session's state, mirrored for the views (only what changed, so a motion second does not redraw them all).
    private func publish() {
        if beliefs != session.beliefs { beliefs = session.beliefs }
        if offPlanAlighting != session.offPlanAlighting { offPlanAlighting = session.offPlanAlighting }
        if stayedOn != session.stayedOn { stayedOn = session.stayedOn }
        if changedEarly != session.changedEarly { changedEarly = session.changedEarly }
        let ec = session.earlyChange
        if ec?.change != earlyChange?.change || ec?.alightTs != earlyChange?.alightTs { earlyChange = ec }
        guard let t = tracker else { return }
        if phase != t.phase { phase = t.phase }
        if motionState != t.motionState { motionState = t.motionState }
        motionSeconds = t.timeline.motionSeconds
        walkMeters = t.timeline.walkMeters
        rideAssumed = t.timeline.rideAssumed
        if boardingPending != t.boardingPending { boardingPending = t.boardingPending }
        endReason = t.timeline.endedBy
    }

    /// Ends the trip and hands what it measured on: to the pace model when learning is on, to the telemetry
    /// when sharing is on.
    @discardableResult
    func end(by: String, api: URL?, now: Double) -> TripTimeline? {
        sampler.stop()
        guard let tl = session.end(by: by, now: now) else { return nil }
        publish()
        phase = nil
        motionState = .unknown
        boardingPending = false
        devNotes = []
        endReason = tl.endedBy
        PersonalModelStore.shared.learn(tl)
        if PersonalModelStore.shared.optIn { HabitStore.shared.learnRide(tl) }
        Telemetry.shared.endTrip(timeline: tl, api: api)
        MotionTrace.shared.end(tl)
        return tl
    }
}
