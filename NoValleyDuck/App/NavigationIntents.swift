import AppIntents

struct StartNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "Navigate"
    static var description = IntentDescription("Plans a walk and bus trip to a destination and guides you there by sound.")
    static var openAppWhenRun = true

    // Optional on purpose: Siri's own "Where to?" is often only shown, not spoken (Siri response
    // settings, typed requests), and its dictation is worse at German place names. Without a
    // destination the app asks out loud itself, with its own recognisers (see askDestination).
    @Parameter(title: "Destination")
    var destination: DestinationEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Navigate to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let trip = TripController.shared
        Task { await trip.setup() }       // camera and stop data; not needed to start walking
        if let destination {
            trip.start(destination: destination.name)
        } else {
            Task {
                // HACK: let Siri finish and release the mic and audio before asking.
                try? await Task.sleep(for: .seconds(1.2))
                await trip.askDestination()
            }
        }
        return .result()
    }
}

struct StopNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Guiding"
    static var description = IntentDescription("Stops spoken guidance.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        TripController.shared.stop()
        return .result()
    }
}
