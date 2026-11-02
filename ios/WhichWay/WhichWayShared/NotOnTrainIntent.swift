import AppIntents
import Foundation

/// "Not on the train" from the Live Activity: the rider says the ride the phone detected is not one. Runs in the
/// app's process (the extension only draws the button); the app hands it to the trip recorder at launch.
struct NotOnTrainIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Not on the train"
    static var description = IntentDescription("Withdraws the train ride the phone detected; the route goes back to waiting for the train.")

    /// Set by the app: what saying so does there (the extension leaves it nil).
    @MainActor static var handler: (() -> Void)?

    func perform() async throws -> some IntentResult {
        await MainActor.run { NotOnTrainIntent.handler?() }
        return .result()
    }
}

/// "Changed to the A/C at Jay St" from the Live Activity: the rider took the change short of the route's own that the
/// activity offers. Runs in the app's process, like `NotOnTrainIntent`.
struct ChangedTrainIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Changed trains"
    static var description = IntentDescription("Hands the route over to the train the rider changed to at the station the activity names.")

    /// Set by the app (the extension leaves it nil).
    @MainActor static var handler: (() -> Void)?

    func perform() async throws -> some IntentResult {
        await MainActor.run { ChangedTrainIntent.handler?() }
        return .result()
    }
}

/// "Note" from the Live Activity: marks this moment on the trip for a note on how the app behaved. No words can be typed
/// there, so the mark keeps the moment and the words follow in the app. Runs in the app's process, like `NotOnTrainIntent`.
struct MarkMomentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark this moment"
    static var description = IntentDescription("Marks the moment on the trip in progress, for a note on how the app behaved.")

    /// Set by the app (the extension leaves it nil).
    @MainActor static var handler: (() -> Void)?

    func perform() async throws -> some IntentResult {
        await MainActor.run { MarkMomentIntent.handler?() }
        return .result()
    }
}
