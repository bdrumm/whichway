import SwiftUI

@main
struct WhichWayApp: App {
    @State private var data = DataService()
    @State private var presets = PresetStore()
    @State private var location = LocationService()
    @State private var places = PlaceStore()

    init() {
        // the Live Activity's "Not on the train" (it may launch the app in the background to run it)
        NotOnTrainIntent.handler = { TripRecorder.shared.notOnTrain() }
        // and its "Changed to the …" at a station short of the route's change
        ChangedTrainIntent.handler = { TripRecorder.shared.takeEarlyChange() }
        // and its note button: the moment marked on the trip, the words to follow in the app
        MarkMomentIntent.handler = { TripRecorder.shared.markMoment() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(data)
                .environment(presets)
                .environment(location)
                .environment(places)
                .onAppear { data.start() }
        }
    }
}
