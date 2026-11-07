import AppIntents

struct StartNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "Navigate"
    static var description = IntentDescription("Plans a walk and bus trip to a destination and guides you there by sound.")
    static var openAppWhenRun = true

    @Parameter(title: "Destination", requestValueDialog: "Where to?")
    var destination: DestinationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Navigate to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let trip = TripController.shared
        Task { await trip.setup() }       // camera and stop data; not needed to start walking
        trip.start(destination: destination.name)
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
