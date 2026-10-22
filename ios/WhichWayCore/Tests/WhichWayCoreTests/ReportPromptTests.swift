import XCTest
@testable import WhichWayCore

final class ReportPromptTests: XCTestCase {
    let train = ReportContext.onTrain(key: "A_S", tripId: "112450_A..S", route: "A", stop: "A41S", stopName: "Jay St-MetroTech", confidence: 0.8)
    let platform = ReportContext.atStation(key: "F_N", stop: "F20N", stopName: "Bergen St")

    func decide(now: Double = 10_000, onTrain: Bool = true, holding: Bool = true, heldSec: Double? = 150, conf: Double = 0.8,
                since: Double? = nil, hw: Double? = 480, asked: Set<String> = [], last: Double? = nil) -> ReportPrompt? {
        var t = train; t.confidence = conf
        return ReportPrompt.decide(now: now, onTrain: onTrain, trainContext: t, holding: holding, heldSec: heldSec,
                                   platformContext: platform, platformSinceTs: since, headwaySec: hw, asked: asked, lastTs: last)
    }

    func testAHoldOfTwoMinutesOnTheTrainIsAskedAboutOnce() {
        let p = decide()
        XCTAssertEqual(p?.kind, .held)
        XCTAssertEqual(p?.question, "Held at Jay St-MetroTech?")
        XCTAssertEqual(p?.no.kind, .moving)
        XCTAssertNil(decide(asked: [p!.key]))
        XCTAssertNil(decide(heldSec: 90))
        XCTAssertNil(decide(holding: false))
        XCTAssertNil(decide(conf: 0.4), "not sure enough which train the rider is on")
    }

    func testPromptsAreTenMinutesApart() {
        XCTAssertNil(decide(last: 10_000 - 300))
        XCTAssertNotNil(decide(last: 10_000 - 700))
    }

    func testALongWaitIsTwiceTheHeadwayAndTenMinutesAtLeast() {
        XCTAssertNil(decide(onTrain: false, since: 10_000 - 900, hw: 480))           // 15 min < 16
        XCTAssertEqual(decide(onTrain: false, since: 10_000 - 1000, hw: 480)?.kind, .longWait)
        XCTAssertEqual(decide(onTrain: false, since: 10_000 - 620, hw: 120)?.kind, .longWait)
        XCTAssertNil(decide(onTrain: false, since: 10_000 - 500, hw: 120))
        XCTAssertNil(decide(onTrain: false, since: nil))
        let p = decide(onTrain: false, since: 10_000 - 1000)!
        XCTAssertFalse(p.expired(now: 10_100)); XCTAssertTrue(p.expired(now: 10_200))
    }
}
