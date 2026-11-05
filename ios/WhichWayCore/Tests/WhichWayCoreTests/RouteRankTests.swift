import XCTest
@testable import WhichWayCore

/// The routes' order, shared by the routes page and the home's lanes: the rider's usual way first unless another
/// gets in a real margin sooner; the rest by arrival, a train in the feeds ahead of a timetable guess.
final class RouteRankTests: XCTestCase {
    private func r(_ id: String, _ arrive: Double?, expected: Double = 1800, share: Double? = nil) -> RankedRoute {
        RankedRoute(id: id, arriveTs: arrive, expectedSec: expected, affinity: share)
    }
    private func ids(_ rs: [RankedRoute]) -> [String] { RouteRank.order(rs).map(\.id) }

    func testWithoutHabitsTheRoutesGoByArrivalTrainsInTheFeedsFirst() {
        XCTAssertEqual(ids([r("late", 3000), r("guess", nil, expected: 600), r("soon", 2000)]), ["soon", "late", "guess"])
        XCTAssertNil(RouteRank.typical([r("a", 1000), r("b", 1100)]))
    }

    func testTheUsualWayWinsUnlessAnotherIsAMarginSooner() {
        // W 4 St is the usual; Jay St 3 min sooner is not worth breaking the habit for, the G 5 min sooner is
        let routes = [r("W4", 2000, share: 0.6), r("Jay", 1820, share: 0.25), r("G", 1700, share: 0.15)]
        XCTAssertEqual(RouteRank.typical(routes), "W4")
        XCTAssertEqual(ids(routes), ["G", "W4", "Jay"])
        // on a day the G is no quicker the usual way is first
        XCTAssertEqual(ids([r("W4", 2000, share: 0.6), r("Jay", 1820, share: 0.25), r("G", 1900, share: 0.15)]), ["W4", "Jay", "G"])
    }

    func testTheMarginIsInclusiveAndCountsFromTheUsualWaysArrival() {
        XCTAssertTrue(RouteRank.beats(r("a", 1000), r("u", 1000 + RouteRank.significantSec)))
        XCTAssertFalse(RouteRank.beats(r("a", 1001), r("u", 1000 + RouteRank.significantSec)))
    }

    func testAUsualWayWithNoTrainInTheFeedsStaysBehindTheOnesWithOne() {
        let routes = [r("usual", nil, expected: 1200, share: 0.9), r("a", 3000), r("guess", nil, expected: 1000)]
        XCTAssertEqual(ids(routes), ["a", "usual", "guess"], "first of the timetable guesses, behind the train on its way")
    }

    func testNoUsualWayWhenTheSharesAreLowOrTied() {
        XCTAssertNil(RouteRank.typical([r("a", 1000, share: 0.3), r("b", 1100, share: 0.2)]), "below the minimum share")
        XCTAssertNil(RouteRank.typical([r("a", 1000, share: 0.45), r("b", 1100, share: 0.45)]), "a tie singles out none")
        XCTAssertEqual(ids([r("a", 1000, share: 0.45), r("b", 1100, share: 0.45)]), ["a", "b"])
    }

    func testTheUsualWayNeverMovesDown() {
        // already first by arrival: it stays first even with a later route that would "beat" nothing
        XCTAssertEqual(ids([r("u", 1000, share: 0.8), r("b", 1500)]), ["u", "b"])
    }
}

/// The routes held in one order once ranked with the trains in (Nov 4: "keep ranking static").
final class SteadyOrderTests: XCTestCase {
    func testBeforeTheTrainsAreInTheOrderFollowsTheRanking() {
        var o = SteadyOrder()
        XCTAssertEqual(o.update(ranked: ["a", "b"], hasTrains: false), ["a", "b"])
        XCTAssertEqual(o.update(ranked: ["b", "a"], hasTrains: false), ["b", "a"])
        XCTAssertFalse(o.settled)
    }

    func testOnceRankedWithTrainsTheOrderHoldsAsTimesChange() {
        var o = SteadyOrder()
        o.update(ranked: ["usual", "g", "jay"], hasTrains: true)
        XCTAssertTrue(o.settled)
        XCTAssertEqual(o.update(ranked: ["jay", "g", "usual"], hasTrains: true), ["usual", "g", "jay"])
        // a route gone drops out, the rest keep their places; one new goes at the end
        XCTAssertEqual(o.update(ranked: ["jay", "usual"], hasTrains: true), ["usual", "jay"])
        XCTAssertEqual(o.update(ranked: ["new", "jay", "usual"], hasTrains: true), ["usual", "jay", "new"])
        o.reset()
        XCTAssertEqual(o.update(ranked: ["jay", "usual"], hasTrains: true), ["jay", "usual"], "ranked afresh after a reset")
    }

    func testArrangePutsUnknownItemsAfterInTheirOwnOrder() {
        var o = SteadyOrder()
        o.update(ranked: ["b", "a"], hasTrains: true)
        XCTAssertEqual(o.arrange(["x", "a", "y", "b"], id: { $0 }), ["b", "a", "x", "y"])
    }
}
