import SwiftUI

@main
struct NoValleyDuckApp: App {
    @State private var trip = TripController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        StopTripLiveActivityIntent.handler = { TripController.shared.stop(); TripLiveActivity.endAll() }
    }

    var body: some Scene {
        WindowGroup {
            RiderView(trip: trip)
                .task {
                    // HACK: launch with `-startDestination "Getreidegasse"` to start a route without voice.
                    if let dest = UserDefaults.standard.string(forKey: "startDestination") { trip.start(destination: dest) }
                    await trip.setup()
                }
                .task {
                    // TEMP: launch with `-navTestDestination "Mirabellplatz"` to log a plan to the console.
                    // Add `-navTestMapKitOnly YES` to skip Transitous and use MapKit only.
                    if let dest = UserDefaults.standard.string(forKey: "navTestDestination") {
                        let service = NavigationService()
                        service.useTransitous = !UserDefaults.standard.bool(forKey: "navTestMapKitOnly")
                        print(await NavigationDebug.describe(dest, using: service))
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { trip.becameActive() } else if phase == .background { trip.resignedActive() }
                }
        }
    }
}
