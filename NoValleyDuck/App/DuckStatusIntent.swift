import AppIntents

struct DuckStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Duck Status"
    static var description = IntentDescription("Says where you are in the trip and whether a stop marker was found.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let trip = TripController.shared
        let tags = trip.pipeline.lastFrame?.detections.filter { $0.status == .locked }.map(\.detection.id) ?? []
        let message = tags.isEmpty
            ? "No stop marker found. \(trip.statusTitle)."
            : "Stop marker \(tags.map(String.init).joined(separator: ", ")) found. \(trip.statusTitle)."
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct NoValleyDuckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DuckStatusIntent(),
            phrases: ["Duck status in \(.applicationName)"],
            shortTitle: "Duck Status",
            systemImageName: "camera.viewfinder"
        )
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
