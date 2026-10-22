import SwiftUI

struct ContentView: View {
    @Environment(DataService.self) private var data
    @Environment(\.scenePhase) private var scenePhase
    /// The first launch: the welcome sheet says that sharing trips is on, with the switch to turn it off.
    @State private var welcome = !WelcomeView.shown

    var body: some View {
        TabView {
            PlannerView().tabItem { Label("Go", systemImage: "tram.fill") }
            LineBoardView().tabItem { Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $welcome) { WelcomeView() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: data.start(); data.refreshIfStale(); Task { await ReportQueue.shared.flush() }
            case .background: if TripRecorder.shared.phase == nil { data.stop() }     // a route in progress keeps polling
            default: break
            }
        }
    }
}
