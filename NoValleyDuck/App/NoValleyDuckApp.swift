import SwiftUI

@main
struct NoValleyDuckApp: App {
    @State private var pipeline = MarkerPipeline()

    var body: some Scene {
        WindowGroup {
            DebugView(pipeline: pipeline)
        }
    }
}
