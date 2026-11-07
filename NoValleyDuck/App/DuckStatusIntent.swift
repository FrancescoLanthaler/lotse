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

struct ShowMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Note"
    static var description = IntentDescription("Opens NoValleyDuck and displays the given text.")
    static var openAppWhenRun = true

    @Parameter(title: "Note")
    var note: String

    @MainActor
    func perform() async throws -> some IntentResult {
        TripController.shared.siriMessage = note
        return .result()
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
            intent: ShowMessageIntent(),
            phrases: ["Do something weird in \(.applicationName)"],
            shortTitle: "Show Note",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: StartNavigationIntent(),
            phrases: ["Navigate with \(.applicationName)", "Start \(.applicationName)",
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
