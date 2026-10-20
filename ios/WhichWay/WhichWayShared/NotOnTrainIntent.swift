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
