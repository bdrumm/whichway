import Foundation

/// The moments the app asks the rider for a report rather than waiting for them to tap the button: the train they
/// are on has been held at a stop for two minutes or more (the feed says so: "Held at Jay St?" confirms or disputes
/// it), or they have waited on the platform well past the train's headway ("Long wait?"). Each hold and each platform
/// visit is asked about once, prompts are at least ten minutes apart, and one goes away by itself after three.
struct ReportPrompt: Equatable {
    enum Kind: String, Equatable { case held, longWait }
    var kind: Kind
    /// Identifies the moment: the train and stop of a hold, the platform and arrival of a wait.
    var key: String
    var context: ReportContext
    var shownTs: Double

    var question: String {
        switch kind {
        case .held: return "Held at \(context.stopName)?"
        case .longWait: return "Long wait at \(context.stopName)?"
        }
    }
    /// The answer that backs the prompt up, and the one that disputes it.
    var yes: (kind: ReportKind, label: String) { kind == .held ? (.held, "Yes, held") : (.longWait, "Yes, long wait") }
    var no: (kind: ReportKind, label: String) { kind == .held ? (.moving, "We're moving") : (.allGood, "Trains are fine") }

    static let holdSec = 120.0
    static let minWaitSec = 600.0
    static let gapSec = 600.0
    static let showSec = 180.0

    /// What to ask now, if anything. `asked` holds the keys already asked about; `lastTs` when the last prompt showed.
    /// On a train: the feed's position for the train the phone is fairly sure of (`confidence` 0.6+). On the platform:
    /// the wait since the rider got there, against twice the line's headway (ten minutes at least).
    static func decide(now: Double, onTrain: Bool, trainContext: ReportContext?, holding: Bool, heldSec: Double?,
                       platformContext: ReportContext?, platformSinceTs: Double?, headwaySec: Double?,
                       asked: Set<String>, lastTs: Double?) -> ReportPrompt? {
        if let l = lastTs, now - l < gapSec { return nil }
        if onTrain, let c = trainContext, holding, let h = heldSec, h >= holdSec, (c.confidence ?? 0) >= 0.6 {
            let key = "held|\(c.tripId ?? c.route)|\(c.stop)"
            if !asked.contains(key) { return ReportPrompt(kind: .held, key: key, context: c, shownTs: now) }
        }
        if !onTrain, let c = platformContext, let since = platformSinceTs {
            let need = max(minWaitSec, 2 * (headwaySec ?? 0))
            let key = "wait|\(c.stop)|\(Int(since))"
            if now - since >= need, !asked.contains(key) { return ReportPrompt(kind: .longWait, key: key, context: c, shownTs: now) }
        }
        return nil
    }

    func expired(now: Double) -> Bool { now - shownTs > ReportPrompt.showSec }
}
