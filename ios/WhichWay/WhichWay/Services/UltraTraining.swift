import Foundation

/// Ultra training mode, for TestFlight testers who want their rides to train the models: on top of the shared
/// trips, the phone keeps each route's summarised motion (one line a second) and every station stop it feels (when
/// the train came to rest and moved again), and sends both with the trip. The Mac names the station of each stop
/// from the train's own times (`make corpus`), which gives the corpus true platform arrivals, departures and dwells
/// to set the feed's lag and the dwell and arrival models against. Off unless the rider turns it on; needs trip
/// sharing; turning sharing off turns this off too.
@MainActor
enum UltraTraining {
    static let key = "ultraTrainingMode"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) && Telemetry.shared.optIn }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static let explanation = "For testers who want their rides to train WhichWay. On top of your shared trips, the phone keeps a summary of its motion for each route, once a second (how hard it is pushed and shaken, and whether you are walking: no raw sensor data, no location), and the moments it feels your train stop at each station and move off again. Both are sent with the trip. They are matched to the stations from the train's own times, to learn how long trains really stand at each station and how far the feed's times run behind the platform. Uses a little more battery during a route. Turn it off at any time; what was already sent stays with the trips."
}
