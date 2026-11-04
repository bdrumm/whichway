import Foundation

// The change on the route in hand, said outright at the top of the home (Nov 4): how long the rider has to make the
// connecting train once off the first one and over to its platform, which train that is and when its doors open, and
// the one after it, so a missed connection is a known cost rather than a surprise.

struct TransferHeadroom: Equatable {
    /// The change, by name.
    var station: String
    /// The doors of the train in hand opening at the change; nil without a train in the feeds.
    var offTs: Double?
    /// The planned walk or step across, as `PathTransfer.kindText` says it.
    var changeText: String
    /// The connecting train's line and the moment its doors open; nil while it is not in the feeds.
    var route: String?
    var boardTs: Double?
    /// The time to spare once over at its platform: until its doors open, or for a train already standing across the
    /// platform, until they close (`Itinerary.catchesStanding`).
    var marginSec: Double?
    var standing = false
    /// Under the change's own tight margin (`PathTransfer.tightSec`).
    var tight = false
    /// The train after the connection, if it is missed.
    var nextRoute: String?
    var nextTs: Double?

    /// The change ahead on `option` for `itinerary` (the ride in hand, else the planner's next); nil for a direct
    /// route, or once the rider is past the change (`rideLeg` > 0).
    static func of(option: PathOption, itinerary: Itinerary?, rideLeg: Int) -> TransferHeadroom? {
        guard option.legs.count > 1, rideLeg == 0, let tr = option.transfer else { return nil }
        var h = TransferHeadroom(station: tr.station, offTs: itinerary?.legs.first?.arriveTs, changeText: tr.kindText)
        guard let it = itinerary, it.legs.count > 1, let m = it.connectionMarginSec else { return h }
        let b = it.legs[1]
        h.route = b.train.route
        h.boardTs = b.boardTs
        h.marginSec = m
        h.standing = it.catchesStanding
        h.tight = m < tr.tightSec
        if let n = it.nextIfMissedSec {
            h.nextTs = b.boardTs + n
            h.nextRoute = it.nextIfMissedRoute ?? b.train.route
        }
        return h
    }

    /// The headline: "2:10 to make the A at Jay St"; a train standing there, "0:40 to board the A across the platform".
    var headline: String {
        guard let r = route, let m = marginSec else { return "Change at \(station)" }
        if standing { return "\(Fmt.mmss(m)) to board the \(r) across the platform at \(station)" }
        return "\(Fmt.mmss(m)) to make the \(r) at \(station)"
    }

    /// The times under it: "off 9:42 · 1:30 walk · A 9:45 · next A 9:51, +6:00".
    var detail: String {
        var bits: [String] = []
        if let o = offTs { bits.append("off \(Fmt.hhmm(o))") }
        bits.append(changeText)
        if let r = route, let b = boardTs {
            bits.append("\(r) \(Fmt.hhmm(b))")
        } else {
            bits.append("connection not in the feeds yet")
        }
        if let n = nextTs, let nr = nextRoute, let b = boardTs { bits.append("next \(nr) \(Fmt.hhmm(n)), +\(Fmt.mmss(n - b))") }
        return bits.joined(separator: " · ")
    }
}
