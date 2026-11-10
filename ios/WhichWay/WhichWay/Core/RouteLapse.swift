import Foundation

// The route in hand counts on one train for the leg the rider boards next: the first leg's train on the way to the
// station and at its platform, the connection between trains at the change. When that train goes without the rider,
// the route as chosen is no longer the way they are going, and the routes are weighed again from where the rider is
// (Nov 10: the countdown reached zero with the rider nowhere near the station and nothing boarded, and the app sat on
// the chosen route's next train while another route was the better way now).
//
// The class, every way the train counted on stops being the rider's:
// - its time comes and goes with the rider still on the way (no station proximity, no pull-away felt);
// - the rider can no longer reach it from where they are (the planner's reach puts them on the platform after it);
// - it leaves the feed well before its time (cancelled, withdrawn, rerouted): it never came;
// - all of the above with no route started yet: the countdown on the home reached zero.
// Never lapsed: the rider is on a train or a pull-away is waiting for the feed (the chosen route is the prior for the
// ride, `RideContinuity`); and at the platform (the origin's within the station's radius, or the change) when the train
// merely left: the rider was there for it, so the chosen route is the assumption and the session presumes them on it
// once the feed shows it leaving, however late (`RideSession.presumeBoarding`; Nov 10 evening, the F boarded unfelt a
// little after its time and the planner moved on to the next F). With the sensors off the tracker assumes the ride.
//
// A lapse re-weighs and re-ranks; it never hides a route. The whole list stays and the rider can take any route again,
// the lapsed one included.

/// The train the route in hand counts on for the leg the rider boards next, as last shown.
struct CountedTrain: Equatable {
    var routeId: String
    var leg: Int
    var trainId: String
    var boardTs: Double
}

/// What the phone knows of the rider against the train counted on.
struct BoardingWatch: Equatable {
    enum Place: Equatable {
        /// No route under way: the home's countdown only.
        case noRoute
        /// On the way to the first platform: no station proximity yet.
        case approaching
        /// At the origin's platform (within the station's radius), or between trains at the change.
        case atPlatform
    }
    var place: Place
    /// On a train, or a pull-away felt and waiting for the feed: a boarding the route must not jump away from.
    var boarding: Bool
    /// The motion sensors are on: a pull-away would have been felt.
    var sensing: Bool
}

/// How the train counted on went without the rider.
enum RouteLapse: String, Equatable {
    /// Its time came and went with no boarding.
    case departed
    /// It is no longer the route's train from here: out of reach from where the rider is, or gone from the feed early.
    case movedOn
}

enum Lapse {
    /// On the way with no fix near the station: the train may be late, or boarded from a platform the GPS never saw, so
    /// the pull-away has this long past the boarding time to be felt before the routes are weighed again.
    static let approachGraceSec = 120.0
    /// At the platform, a train gone from the route's itinerary more than this ahead of its time was withdrawn, not
    /// taken (`TripTracker.forecastTrainDeparted` reads a drop inside this as the train leaving).
    static let droppedEarlySec = 90.0
}

/// Follows the train the route in hand counts on, poll by poll, and says when it went without the rider.
struct RouteLapseWatch: Equatable {
    private(set) var counted: CountedTrain?

    mutating func reset() { counted = nil }

    /// Every refresh: `routeId` the route in hand, `leg` the leg boarded next, `first` that leg's train on the route's
    /// itinerary from here now (its id and boarding time; nil when the route has none). Returns the lapse when the train
    /// counted on went without the rider, and starts counting afresh on the next call (after the caller has re-weighed
    /// the routes); nil otherwise.
    mutating func check(routeId: String?, leg: Int, first: (trainId: String, boardTs: Double)?, watch: BoardingWatch, now: Double) -> RouteLapse? {
        guard let routeId, !watch.boarding else { counted = nil; return nil }
        guard var c = counted, c.routeId == routeId, c.leg == leg else {
            counted = first.map { CountedTrain(routeId: routeId, leg: leg, trainId: $0.trainId, boardTs: $0.boardTs) }
            return nil
        }
        var moved = true
        if let f = first {
            if f.trainId == c.trainId {
                c.boardTs = f.boardTs             // the same train, its time moved in the feed
                moved = false
            } else if f.boardTs <= c.boardTs {
                // an earlier train now leads the itinerary (one the feed just listed): a better train, not a lapse
                counted = CountedTrain(routeId: routeId, leg: leg, trainId: f.trainId, boardTs: f.boardTs)
                return nil
            }
        }
        counted = c
        let lapse: RouteLapse?
        switch watch.place {
        case .noRoute:
            lapse = now >= c.boardTs ? .departed : (moved ? .movedOn : nil)
        case .approaching:
            if moved && now < c.boardTs { lapse = .movedOn }
            else if now >= c.boardTs + Lapse.approachGraceSec { lapse = .departed }
            else { lapse = nil }
        case .atPlatform:
            // the train leaving is presumed boarded (`RideSession.presumeBoarding`), never a lapse; one gone from the
            // feed well ahead of its time never came
            lapse = moved && c.boardTs - now > Lapse.droppedEarlySec ? .movedOn : nil
        }
        if lapse != nil { counted = nil }
        return lapse
    }
}

/// Between trains at the change, once the connection counted on has gone: the way on from here that gets the rider in
/// first, the route in hand on its next train included (and kept on a tie). Only a way whose next boarding is still
/// ahead counts; the others, timed on the trains in the feeds (or the forecast kept offline), as `itineraryFromHere`
/// has them. Nil when no way on from here has a train to name.
func bestWayOn(current: PathOption, options: [PathOption], at pos: RiderPosition, boards: [String: LineBoard], schedule: ClientSchedule,
               station: (String) -> String, now: Double) -> PathOption? {
    var best: (option: PathOption, arriveTs: Double)? = nil
    if let mine = currentItinerary(boards: boards, schedule: schedule, option: current, at: pos, now: now), mine.boardTs >= now {
        best = (current, mine.arriveTs)
    }
    for p in options where p.id != current.id && continuesFrom(p, current: current, at: pos, station: station) {
        guard let it = itineraryFromHere(boards: boards, schedule: schedule, option: p, at: pos, current: current, now: now),
              it.boardTs >= now else { continue }
        if best == nil || it.arriveTs < best!.arriveTs { best = (p, it.arriveTs) }
    }
    return best?.option
}

/// The words for the trip record and the rider when the routes are weighed again.
func lapseNote(_ lapse: RouteLapse, from: String, to: String?) -> String {
    let why = lapse == .departed ? "train left without you" : "train out of reach"
    guard let to, to != from else { return "\(why): next train on \(from)" }
    return "\(why): now \(to)"
}
