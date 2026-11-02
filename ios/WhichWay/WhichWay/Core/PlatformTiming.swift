import Foundation

/// How the feed's times relate to what a rider lives at the platform, by line.
///
/// The time the feed last gives for a stop (what the collector records as the arrival, what the client model is
/// calibrated against, what the departure log keeps) is not when the doors open. Measured on Oct 7 2026 from the
/// vehicle feed (the moment each train was first reported standing at a platform, 7,671 platform stops on every
/// line over 45 minutes of the evening rush, polled every 10 s) and corroborated by the phone's own felt
/// departures and walk-offs on the E and F that day: numbered lines and the L record about 30 s after the train
/// pulls in, the G about 60 s, the lettered lines 70 to 95 s. The feed's own ETA a few minutes out lands 25 to
/// 45 s after the real arrival too. The doors stood about 47 s at 14 St and W 4 St by the phone's pull-aways.
///
/// The vehicle feed's "standing at the platform" is set as the train enters the station, not as it stops: the train
/// still has the platform to run, to stop, and then its doors to open (Nov 2 2026: the countdown read zero with the
/// train just coming in). `atPlatform` stays that entry, the reference every sensing rule is calibrated on (the
/// pull-away, the walk-off, the step across); what the rider is told, the countdown to boarding, the time off the
/// train, the arrival, is `doorsOpen`, `doorsOpenSec` later. The shift is the same at both ends of a change, so which
/// connection is made, and by what margin, does not move.
enum PlatformTiming {
    /// Seconds from the train reaching the platform to the feed's last time for that stop.
    static var recordedLagByRoute: [String: Double] = [
        "1": 30, "2": 30, "3": 30, "4": 30, "5": 30, "6": 30, "6X": 30, "7": 30, "7X": 35, "GS": 30,
        "L": 30, "G": 60,
        "A": 75, "C": 70, "E": 80, "B": 70, "D": 80, "F": 80, "FX": 80, "M": 85,
        "N": 85, "Q": 95, "R": 90, "W": 95, "J": 75, "Z": 75, "FS": 30, "H": 50, "SI": 30,
    ]
    static var defaultRecordedLag = 60.0
    /// The doors stay open about this long (the felt pull-away comes this long after the train pulled in).
    static var dwellSec = 40.0
    /// From the train entering the station (the feed's moment at the platform) to its doors opening: the run down a
    /// 510 to 600 ft platform from about 15 mph, braking at the usual 2 to 3 mph/s, and the doors released. About 20 s;
    /// the "Doors opened" note on the trip bar records the real moment to calibrate it by line.
    static var doorsOpenSec = 20.0

    static func recordedLag(route: String) -> Double { recordedLagByRoute[route] ?? defaultRecordedLag }
    /// When the train actually reaches the platform, from a feed or recorded time for that stop.
    static func atPlatform(_ feedTs: Double, route: String) -> Double { feedTs - recordedLag(route: route) }
    /// When its doors open: what the countdown aims at, to board, to get off, to arrive.
    static func doorsOpen(_ feedTs: Double, route: String) -> Double { atPlatform(feedTs, route: route) + doorsOpenSec }
    /// The feed's time for a stop back from the doors-open moment a rider is shown.
    static func feedTs(doorsOpen ts: Double, route: String) -> Double { ts - doorsOpenSec + recordedLag(route: route) }
    /// When it actually pulls away again.
    static func pullsAway(_ feedTs: Double, route: String) -> Double { atPlatform(feedTs, route: route) + dwellSec }
}
