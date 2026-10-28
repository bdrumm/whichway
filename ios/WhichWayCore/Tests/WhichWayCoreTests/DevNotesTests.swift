import XCTest
@testable import WhichWayCore

/// The rider's notes on how the app behaved: kept on the trip at the moment they are about, with what the phone had in
/// hand then, and nothing else about the trip changed by them.
final class DevNotesTests: XCTestCase {
    private func start(_ ts: Double = 1000) -> TripTimeline {
        TripTimeline(startTs: ts, startedBy: "hand", startDistanceM: 40, placeId: nil, originStation: "S1", destStation: "S9", transferStation: nil, legs: 1)
    }
    private func sec(_ ts: Double, walking: Bool, push: Double = 0.005, shake: Double = 0.005) -> MotionSecond {
        MotionSecond(ts: ts, stepEnergy: walking ? 0.05 : 0.002, pushG: push, shakeG: shake)
    }
    private let theF = LineBelief(leg: 0, byTrain: ["F_N|f1": 0.83, "G_N|g1": 0.17], byLine: ["F_N": 0.83, "G_N": 0.17], chosenKey: "F_N", evidence: ["departure"])

    /// A ride with a note on the platform, one on the train and a mark from the Live Activity: each keeps its moment
    /// and the phase, motion, leg and train in hand then; the ride itself is the same as without them.
    func testNotesKeepTheirMomentAndWhatThePhoneHadThen() throws {
        func ride(notes: Bool) -> TripTimeline {
            var t = TripTracker(start(), distanceToOriginM: 40)
            t.updateForecast(boardTs: 1100, arriveTs: 1700, now: 1000)
            var ts = 1000.0
            for _ in 0..<60 { t.motion(sec(ts, walking: false)); ts += 1 }
            if notes { XCTAssertNotNil(t.noteDev("  the countdown says 2 min, the board says 5  ", via: "app", at: ts)) }
            for _ in 0..<6 { t.motion(sec(ts, walking: false, push: 0.08, shake: 0.03)); ts += 1 }     // pulls away at 1060
            for _ in 0..<120 { t.motion(sec(ts, walking: false, shake: 0.04)); ts += 1 }
            if notes {
                XCTAssertNotNil(t.noteDev("", via: "activity", at: ts, belief: theF))
                XCTAssertNil(t.noteDev("   ", via: "app", at: ts))                 // an empty note from the app is none
            }
            for _ in 0..<400 { t.motion(sec(ts, walking: false, shake: 0.04)); ts += 1 }
            for _ in 0..<20 { t.motion(sec(ts, walking: false)); ts += 1 }
            for _ in 0..<20 { t.motion(sec(ts, walking: true)); ts += 1 }
            return t.end(now: ts, by: "alighted")
        }
        let plain = ride(notes: false), noted = ride(notes: true)
        var stripped = noted
        stripped.devNotes = nil
        XCTAssertEqual(stripped, plain)

        let notes = try XCTUnwrap(noted.devNotes)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].ts, 1060)
        XCTAssertEqual(notes[0].text, "the countdown says 2 min, the board says 5")
        XCTAssertEqual(notes[0].phase, "atStation")
        XCTAssertEqual(notes[0].onTrain, false)
        XCTAssertEqual(notes[0].leg, 0)
        XCTAssertNil(notes[0].line)
        XCTAssertEqual(notes[1].ts, 1186)
        XCTAssertTrue(notes[1].pending)
        XCTAssertEqual(notes[1].via, "activity")
        XCTAssertEqual(notes[1].phase, "riding")
        XCTAssertEqual(notes[1].onTrain, true)
        XCTAssertEqual(notes[1].line, "F_N")
        XCTAssertEqual(notes[1].train, "F_N|f1")
        XCTAssertEqual(notes[1].confidence, 0.83)
        // and on the record as it is sent
        let back = try JSONDecoder().decode(TripTimeline.self, from: JSONEncoder().encode(noted))
        XCTAssertEqual(back.devNotes, notes)
    }

    /// A moment marked from the Live Activity gets its words later in the app: the moment stays the tap's; a mark
    /// tapped by mistake can go.
    func testAMarkGetsItsWordsLaterAndKeepsItsMoment() throws {
        var t = TripTracker(start(), distanceToOriginM: 40)
        t.noteDev("", via: "activity", at: 1200)
        t.noteDev("", via: "activity", at: 1210)
        XCTAssertEqual(t.timeline.devNotes?.pendingMarks.count, 2)
        XCTAssertFalse(t.writeDevMark(at: 1200, text: "  ", now: 1500))
        XCTAssertFalse(t.writeDevMark(at: 1199, text: "no such mark", now: 1500))
        XCTAssertTrue(t.writeDevMark(at: 1200, text: "felt a stop the train never made", now: 1500))
        XCTAssertFalse(t.writeDevMark(at: 1200, text: "again", now: 1600))             // written once
        XCTAssertTrue(t.dropDevMark(at: 1210))
        let n = try XCTUnwrap(t.timeline.devNotes)
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].ts, 1200)
        XCTAssertEqual(n[0].writtenTs, 1500)
        XCTAssertEqual(n[0].text, "felt a stop the train never made")
        XCTAssertTrue(n.pendingMarks.isEmpty)
    }

    /// After the trip: notes onto a record's list, cut to length and in number.
    func testNotesAreCutToLengthAndInNumber() {
        var notes: [DevNote] = []
        XCTAssertTrue(notes.addNote(DevNote(ts: 1, text: String(repeating: "x", count: 5000), via: "app")))
        XCTAssertEqual(notes[0].text.count, DevNote.maxLength)
        for i in 1..<DevNote.maxPerTrip { XCTAssertTrue(notes.addNote(DevNote(ts: Double(i + 1), text: "n\(i)", via: "app"))) }
        XCTAssertFalse(notes.addNote(DevNote(ts: 999, text: "one too many", via: "app")))
        XCTAssertEqual(notes.count, DevNote.maxPerTrip)
    }

    /// A record from a build before notes reads as one without them.
    func testATimelineWithoutNotesStillReads() throws {
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(start())) as! [String: Any]
        old.removeValue(forKey: "devNotes")
        let t = try JSONDecoder().decode(TripTimeline.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(t.devNotes)
    }
}

/// The one-tap notes: a preset is a note on its own, words optional; a mark from the Live Activity takes one later.
final class DevNotePresetTests: XCTestCase {
    func testAPresetIsANoteWithOrWithoutWords() throws {
        var notes: [DevNote] = []
        XCTAssertTrue(notes.addNote(DevNote(ts: 10, text: "", preset: "missedChange", via: "app")))
        XCTAssertTrue(notes.addNote(DevNote(ts: 20, text: "picked the G", preset: "wrongTrain", via: "app")))
        XCTAssertFalse(notes.addNote(DevNote(ts: 30, text: "", preset: "noSuchPreset", via: "app")))   // unknown: no note at all
        XCTAssertEqual(notes.map(\.summary), ["Missed my change", "Wrong train picked: picked the G"])
        XCTAssertTrue(notes.pendingMarks.isEmpty)
    }

    func testAMarkTakesAPresetLaterAndKeepsItsMoment() throws {
        var t = TripTracker(TripTimeline(startTs: 1000, startedBy: "hand", startDistanceM: 40, placeId: nil, originStation: "S1", destStation: "S9",
                                         transferStation: nil, legs: 1), distanceToOriginM: 40)
        t.noteDev("", via: "activity", at: 1200)
        XCTAssertTrue(t.writeDevMark(at: 1200, text: "", preset: "endedEarly", now: 1500))
        let n = try XCTUnwrap(t.timeline.devNotes?.first)
        XCTAssertEqual(n.ts, 1200)
        XCTAssertEqual(n.preset, "endedEarly")
        XCTAssertFalse(n.pending)
        XCTAssertEqual(n.summary, "Trip ended too soon")
    }

    func testPresetIdsAreUnique() {
        XCTAssertEqual(Set(DevNotePreset.all.map(\.id)).count, DevNotePreset.all.count)
    }
}
