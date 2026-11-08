import AppIntents

struct StartNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "Navigate"
    static var description = IntentDescription("Plans a walk and bus trip to a destination and guides you there by sound.")
    // iOS refuses to start a Live Activity from a background intent, and a background-run app has no
    // window to close. So the app opens, starts the activity, and the rider can leave or lock the phone.
    static var openAppWhenRun = true

    // Required, so Siri asks "Where to?" itself and the trip starts as soon as it has the answer.
    @Parameter(title: "Destination", requestValueDialog: "Where to?")
    var destination: String

    static var parameterSummary: some ParameterSummary {
        Summary("Navigate to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trip = TripController.shared
        Task { await trip.setup() }       // camera and stop data; not needed to start walking
        trip.start(destination: destination)
        return .result(dialog: "Guiding you to \(destination).")
    }
}

struct StopNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Guiding"
    static var description = IntentDescription("Stops spoken guidance.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        TripController.shared.stop()
        return .result()
    }
}

struct NoValleyDuckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartNavigationIntent(),
            // Not "Navigate with …": Siri takes "navigate" as a Maps request and never reaches the app.
            phrases: ["Guide me with \(.applicationName)", "Start a trip with \(.applicationName)",
                      "Start guiding me with \(.applicationName)"],
            shortTitle: "Navigate",
            systemImageName: "figure.walk"
        )
        AppShortcut(
            intent: StopNavigationIntent(),
            phrases: ["Stop guiding me in \(.applicationName)"],
            shortTitle: "Stop Guiding",
            systemImageName: "stop.circle"
        )
    }
}
