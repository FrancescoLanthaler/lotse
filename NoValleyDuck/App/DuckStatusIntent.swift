import AppIntents

struct DuckStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Duck Status"
    static var description = IntentDescription("Reports whether NoValleyDuck currently sees an AprilTag.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let scanner = Scanner.shared
        let message = scanner.detections.isEmpty
            ? "No tags detected."
            : "\(scanner.detections.count) tag(s) detected: \(scanner.status)."
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
        Scanner.shared.siriMessage = note
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
            phrases: ["Start \(.applicationName)"],
            shortTitle: "Start Guiding",
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
