import AppIntents

struct StartNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Guiding"
    static var description = IntentDescription("Starts spoken guidance toward the nearest detected tag.")
    static var openAppWhenRun = true

    @Parameter(title: "Destination", requestValueDialog: "Where would you like to go?")
    var destination: DestinationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start guiding me to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        Scanner.shared.startNavigating(destination: destination.name)
        return .result()
    }
}

struct StopNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Guiding"
    static var description = IntentDescription("Stops spoken guidance.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Scanner.shared.stopNavigating()
        return .result()
    }
}
