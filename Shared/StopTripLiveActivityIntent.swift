import AppIntents

/// "Stop" button on the Live Activity. Runs in the app process; the app sets `handler` at launch
/// (the widget extension only needs the type to draw the button).
struct StopTripLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop guiding"
    static var openAppWhenRun = false

    @MainActor static var handler: (() -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.handler?()
        return .result()
    }
}
