import XCTest
@testable import WhichWayCore

final class RiderReportTests: XCTestCase {
    func testOnTrainContextCarriesTheTrainAndDirection() {
        let c = ReportContext.onTrain(key: "A_S", tripId: "112450_A..S", route: "A", stop: "A41S", stopName: "Jay St-MetroTech", confidence: 0.8612)
        let r = RiderReport(kind: .held, sub: nil, context: c, ts: 1_792_000_000, id: "R-test-0001")
        XCTAssertEqual(r.kind, "held")
        XCTAssertEqual(r.dir, "S")
        XCTAssertEqual(r.trip, "112450_A..S")
        XCTAssertEqual(r.source, "trip")
        XCTAssertEqual(r.confidence, 0.86)
        XCTAssertEqual(r.summary(stopName: "Jay St-MetroTech"), "Held · A at Jay St-MetroTech")
    }

    func testStationContextAndSubs() {
        let c = ReportContext.atStation(key: "F_N", stop: "F20N", stopName: "Bergen St")
        XCTAssertEqual(c.route, "F")
        XCTAssertEqual(c.dir, "N")
        let r = RiderReport(kind: .crowded, sub: "packed", context: c, ts: 1)
        XCTAssertEqual(r.sub, "packed")
        XCTAssertEqual(r.summary(stopName: "Bergen St"), "Packed · F at Bergen St")
        // a sub the kind does not have is dropped, not sent for the relay to refuse
        XCTAssertNil(RiderReport(kind: .held, sub: "packed", context: c, ts: 1).sub)
        XCTAssertNil(r.trip)
        XCTAssertEqual(r.source, "station")
    }

    func testKeysAndTrainIds() {
        XCTAssertNil(ReportContext.direction(ofKey: "GS"))
        XCTAssertEqual(ReportContext.direction(ofKey: "6X_N"), "N")
        XCTAssertEqual(ReportContext.tripId(ofTrain: "F_N|067250_F..N"), "067250_F..N")
        XCTAssertNil(ReportContext.tripId(ofTrain: "F_N|"))
        XCTAssertNil(ReportContext.tripId(ofTrain: nil))
        XCTAssertFalse(RiderReport.tripOK("a b"))
        XCTAssertTrue(RiderReport.tripOK("A20251020WKD_067250_F..N03R"))
    }

    func testTheRelayFieldNames() throws {
        let c = ReportContext.atStation(key: "L_S", stop: "L08S", stopName: "Bedford Av")
        let r = RiderReport(kind: .longWait, sub: nil, context: c, ts: 1_792_000_000.4, id: "R-test-0002", appBuild: "41")
        let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any]
        XCTAssertEqual(o?["kind"] as? String, "long_wait")
        XCTAssertEqual(o?["stop"] as? String, "L08S")
        XCTAssertEqual(o?["appBuild"] as? String, "41")
        XCTAssertEqual(ReportKind.offered(onTrain: false), [.longWait, .crowded, .incident, .allGood])
    }
}
