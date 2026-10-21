import XCTest
@testable import WhichWayCore

/// The walk a change is planned on, per pair of platforms: at 14 St-8 Av the step from the A to the E across the
/// platform and the long walk to the L are not the same change.
final class TransferWalkTests: XCTestCase {
    private func change(_ stops: String, _ sec: Double) -> TripTimeline {
        var t = TripTimeline(startTs: 0, startedBy: "gps", originStation: "S", destStation: "D", transferStation: "14 St", legs: 2)
        t.transferStops = stops
        t.events = [MotionEvent(kind: .departed, ts: 1), MotionEvent(kind: .alighted, ts: 2), MotionEvent(kind: .departed, ts: 3)]
        t.walkingSecondsBetweenTrains = sec
        return t
    }

    func testAQuickChangeAcrossThePlatformDoesNotShortenTheWalkToTheFarPlatform() {
        var m = PersonalModel()
        // twice the A to the E across the platform at 14 St, a quarter of a minute each
        m.learn(change("A31>A31", 14)); m.learn(change("A31>A31", 16))
        XCTAssertEqual(m.plannedTransferSec(station: "14 St", stops: "A31>A31", scheduled: 0, acrossPlatform: true), 15)
        // the L, never changed to yet: the station's quick figure must not stand in for the long walk
        XCTAssertEqual(m.plannedTransferSec(station: "14 St", stops: "A31>L01", scheduled: 240, acrossPlatform: false), 240)
        // once the rider has walked to the L twice, theirs is the figure
        m.learn(change("A31>L01", 290)); m.learn(change("A31>L01", 310))
        XCTAssertEqual(m.plannedTransferSec(station: "14 St", stops: "A31>L01", scheduled: 240, acrossPlatform: false), 300)
        // and the long walk does not slow the step across
        XCTAssertEqual(m.plannedTransferSec(station: "14 St", stops: "A31>A31", scheduled: 0, acrossPlatform: true), 15)
        // another pair at the station, between platforms: the station's mixed figure only ever raises the MTA's
        XCTAssertGreaterThan(m.plannedTransferSec(station: "14 St", stops: "L01>A31", scheduled: 60, acrossPlatform: false), 60)
    }

    func testPlatformsFarApartTakeLongerThanTheComplexWideAllowance() {
        // the A/C/E and the L at 14 St-8 Av: about 145 m apart in a straight line
        let far = TransferTiming.platformWalkSec(meters: 145, speedMPerMin: 80)
        XCTAssertGreaterThan(far, 180, "longer than the MTA's 3:00 for the whole complex")
        // two platforms stacked under one another: the stairs, well inside the allowance
        XCTAssertLessThan(TransferTiming.platformWalkSec(meters: 10, speedMPerMin: 80), 180)
        // a quicker walker gets there sooner
        XCTAssertLessThan(TransferTiming.platformWalkSec(meters: 145, speedMPerMin: 100), far)
        XCTAssertEqual(PathTransfer(stop: "A31N", stop2: "L01N", station: "14 St", walkSec: 180).stopsKey, "A31>L01")
    }
}
