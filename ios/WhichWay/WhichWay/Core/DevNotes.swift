import Foundation

/// A note the rider writes about how the app behaved, kept on the trip at the moment it is about, with what the phone
/// had in hand then (the phase, the motion, the leg, the train it believed), so the trip review can set it beside the
/// sensors' events and the feed's train at that second. From the Live Activity, where no words can be typed, one tap
/// marks the moment (`text` empty) and the words follow in the app; the moment stays the tap's.
struct DevNote: Codable, Equatable {
    var ts: Double                        // the moment the note is about: when the rider tapped
    var text: String                      // empty with no preset: marked from the Live Activity, the words still to come
    var preset: String? = nil             // a one-tap note (`DevNotePreset`), the words then optional
    var writtenTs: Double? = nil          // when the words were written, when that was after the moment
    var via: String                       // "app" | "activity"
    // what the phone had in hand at the moment
    var phase: String? = nil              // the trip's phase; nil after the trip had ended
    var motion: String? = nil
    var leg: Int? = nil                   // legs ridden so far
    var onTrain: Bool? = nil
    var line: String? = nil               // the line key the phone believed the rider on ("F_N")
    var train: String? = nil              // and the train ("F_N|0815_F..N")
    var confidence: Double? = nil

    /// Marked, with no words yet.
    var pending: Bool { text.isEmpty && preset == nil }

    /// The note as the review reads it: the preset's label, then the rider's words.
    var summary: String {
        let label = preset.flatMap { DevNotePreset.byId[$0]?.label }
        return [label, text.isEmpty ? nil : text].compactMap { $0 }.joined(separator: ": ")
    }

    /// Longest note kept; the rest is cut.
    static let maxLength = 1000
    /// Most notes kept on one trip.
    static let maxPerTrip = 60

    static func clean(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    /// The note with what the phone believed about the leg's train.
    func believing(_ b: LineBelief?) -> DevNote {
        var n = self
        guard let b = b, let k = b.bestKey else { return n }
        n.line = k
        n.train = b.bestTrain
        n.confidence = (b.confidence * 100).rounded() / 100
        return n
    }
}

/// The one-tap notes: the ways the app has let the rider down on past trips (the post mortems in docs/postmortems and
/// the trip reviews), so the commonest is said in one tap, at the moment, with words to add if there is time.
struct DevNotePreset: Equatable, Identifiable {
    var id: String
    var label: String
    var symbol: String

    static let all: [DevNotePreset] = [
        DevNotePreset(id: "missedChange", label: "Missed my change", symbol: "arrow.left.arrow.right"),     // Jay St, Oct 22 and 27: across the platform
        DevNotePreset(id: "wrongTrain", label: "Wrong train picked", symbol: "tram"),
        DevNotePreset(id: "departureMissed", label: "Didn't see the train leave", symbol: "figure.wave"),  // W 4 St, Oct 27: train held past its time
        DevNotePreset(id: "boardingLate", label: "Boarding caught late", symbol: "clock.badge.exclamationmark"),
        DevNotePreset(id: "stayedOn", label: "Thinks I stayed on", symbol: "arrow.forward.circle"),
        DevNotePreset(id: "endedEarly", label: "Trip ended too soon", symbol: "stop.circle"),             // Oct 27: ended a minute before 7 Av
        DevNotePreset(id: "etaWrong", label: "Arrival time wrong", symbol: "clock"),
        DevNotePreset(id: "activityStale", label: "Live Activity stale", symbol: "lock.rectangle"),
    ]
    static let byId: [String: DevNotePreset] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

extension Array where Element == DevNote {
    /// A note, or a mark, onto the record. A note with neither words nor a preset is a mark only from the Live
    /// Activity: in the app, nothing.
    @discardableResult
    mutating func addNote(_ n: DevNote) -> Bool {
        var n = n
        n.text = DevNote.clean(n.text)
        if let p = n.preset, DevNotePreset.byId[p] == nil { n.preset = nil }
        guard !n.pending || n.via == "activity", count < DevNote.maxPerTrip else { return false }
        append(n)
        return true
    }

    /// The words (or a preset) for the mark made at `ts`: the mark keeps its moment, and says when the words came.
    @discardableResult
    mutating func writeMark(at ts: Double, text: String, preset: String? = nil, now: Double) -> Bool {
        let t = DevNote.clean(text)
        let p = preset.flatMap { DevNotePreset.byId[$0]?.id }
        guard !t.isEmpty || p != nil, let i = firstIndex(where: { $0.pending && $0.ts == ts }) else { return false }
        self[i].text = t
        self[i].preset = p
        self[i].writtenTs = now
        return true
    }

    /// A mark the rider wants gone (tapped by mistake).
    @discardableResult
    mutating func dropMark(at ts: Double) -> Bool {
        guard let i = firstIndex(where: { $0.pending && $0.ts == ts }) else { return false }
        remove(at: i)
        return true
    }

    var pendingMarks: [DevNote] { filter { $0.pending } }
}
