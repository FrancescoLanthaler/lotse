import SwiftUI
import Combine

struct MarkerGuidance: ViewModifier {
    let scanner: Scanner
    @State private var beacon = MarkerBeacon()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("markerSizeCm") private var markerSizeCm = 16.3
    @AppStorage("spokenCuesEnabled") private var spokenCuesEnabled = false
    @State private var showSettings = false
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                HStack {
                    Text(beacon.status).font(.footnote)
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .padding(12)
                .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .sheet(isPresented: $showSettings) {
                GuidanceSettings(beacon: beacon)
            }
            .onAppear { beacon.spokenCuesEnabled = spokenCuesEnabled }
            .onChange(of: spokenCuesEnabled) { _, enabled in beacon.spokenCuesEnabled = enabled }
            .onReceive(timer) { _ in
                beacon.update(detections: scanner.detections, lastFrame: scanner.lastFrame, active: scenePhase == .active, markerSize: markerSizeCm / 100)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { beacon.stop() }
            }
            .onChange(of: beacon.enabled) { _, enabled in
                if enabled { beacon.start() } else { beacon.stop() }
            }
            .onDisappear { beacon.stop() }
    }
}
