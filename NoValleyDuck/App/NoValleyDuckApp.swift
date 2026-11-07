import SwiftUI

@main
struct NoValleyDuckApp: App {
    @State private var scanner = Scanner.shared
    @State private var showRouteTest = false

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .top) {
                DebugView(pipeline: scanner.pipeline)
                // TEMP: opens the MapKit route test screen.
                HStack {
                    Spacer()
                    Button { showRouteTest = true } label: {
                        Image(systemName: "map").font(.title2).padding(10)
                            .background(.black.opacity(0.6), in: Circle()).foregroundStyle(.white)
                    }
                    .accessibilityLabel("Route test")
                    .padding(.trailing, 16).padding(.top, 50)
                }
                if scanner.isNavigating {
                    VStack(spacing: 12) {
                        Text(scanner.destinationLabel.map { "Navigating to \($0)…" } ?? "Navigating…")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                        Button {
                            scanner.stopNavigating()
                        } label: {
                            Text("Stop")
                                .font(.headline)
                                .padding(.horizontal, 24).padding(.vertical, 10)
                                .background(.red, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .accessibilityLabel("Stop navigation")
                        .accessibilityAddTraits(.isButton)
                    }
                    .padding(20)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.top, 60)
                }
                if let siriMessage = scanner.siriMessage {
                    Text(siriMessage)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .padding(20)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                        .padding(.top, 60)
                        .onTapGesture { scanner.siriMessage = nil }
                }
            }
            .sheet(isPresented: $showRouteTest) { NavigationDebugView() }
            .onChange(of: scanner.pipeline.lastFrame) { _, frame in scanner.frameUpdated(frame) }
            .task {
                // TEMP: launch with `-navTestDestination "Mirabellplatz"` to log a plan to the console.
                // Add `-navTestMapKitOnly YES` to skip Transitous and use MapKit only.
                if let dest = UserDefaults.standard.string(forKey: "navTestDestination") {
                    let service = NavigationService()
                    service.useTransitous = !UserDefaults.standard.bool(forKey: "navTestMapKitOnly")
                    print(await NavigationDebug.describe(dest, using: service))
                }
            }
        }
    }
}
