import SwiftUI

/// The rider screen. Everything here is also spoken, so the screen is only a fallback: one big
/// button for the current action, large text, VoiceOver labels everywhere.
struct RiderView: View {
    let trip: TripController
    @State private var typed = ""
    @State private var showMarkers = false
    @State private var showRouteTest = false
    @AccessibilityFocusState private var promptFocused: Bool

    private var scanning: Bool {
        if case .scanning = trip.phase { return true }
        return trip.phase == .toSpot
    }

    var body: some View {
        ZStack {
            if scanning {
                CameraPreview(session: trip.pipeline.camera.session, frame: trip.pipeline.lastFrame)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            } else {
                Color.black.ignoresSafeArea()
            }
            VStack(spacing: 16) {
                header
                Spacer(minLength: 0)
                mainAction
                footer
            }
            .padding(16)
            .foregroundStyle(.white)
        }
        .sheet(isPresented: $showMarkers) {
            DebugView(pipeline: trip.pipeline)
                .onAppear { trip.pipeline.camera.start() }
                .onDisappear { if !scanning { trip.pipeline.camera.stop() } }
        }
        .sheet(isPresented: $showRouteTest) { NavigationDebugView() }
        .onChange(of: trip.prompter.pending) { _, p in promptFocused = p != nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trip.statusTitle)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            if !trip.lastSpoken.isEmpty {
                Text(trip.lastSpoken).font(.title3)
                    .accessibilityLabel("Last message: \(trip.lastSpoken)")
            }
            if let g = trip.spotGuidance {
                Text("Waiting spot: \(g.clockHour) o'clock, \(g.distance, specifier: "%.1f") metres")
                    .font(.title2.bold())
            }
            if let siri = trip.siriMessage {
                Text(siri).font(.title3)
                    .onTapGesture { trip.siriMessage = nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var mainAction: some View {
        if let prompt = trip.prompter.pending {
            VStack(spacing: 12) {
                Text(prompt.question).font(.title2.bold())
                    .accessibilityFocused($promptFocused)
                ForEach(prompt.options) { option in
                    BigButton(option.label, color: option.id == "no" || option.id == "notYet" ? .gray : .blue) {
                        trip.prompter.choose(option)
                    }
                    .accessibilityHint(prompt.question)
                }
            }
        } else if trip.needsCalibration {
            VStack(spacing: 12) {
                BigButton("Set direction", color: .blue) { trip.calibrate() }
                    .accessibilityHint("Hold your phone flat, pointing forward, then double-tap.")
                Button("Skip") { trip.skipCalibration() }.font(.title3)
            }
        } else if !trip.isRouteActive {
            VStack(spacing: 12) {
                BigButton(trip.listeningForDestination ? "Listening…" : "Where to?", color: .blue) {
                    Task { await trip.askDestination() }
                }
                .accessibilityHint("Say a destination, for example Getreidegasse.")
                HStack {
                    TextField("Or type a destination", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .foregroundStyle(.black)
                        .submitLabel(.go)
                        .onSubmit(go)
                    Button("Go", action: go).font(.title3.bold()).disabled(typed.isEmpty)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                if trip.isRouteActive {
                    Button(role: .destructive) { trip.stop() } label: {
                        Text("Stop route").font(.title3.bold())
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(.red, in: Capsule()).foregroundStyle(.white)
                    }
                }
                Spacer()
                Menu {
                    Button("Fast-forward bus time") { trip.fastForward() }
                    Button("Simulate ride") { trip.simulateRide() }
                    Button("Skip marker scan") { trip.skipScan() }
                    Toggle("Demo stop (\(DemoBundle.shared?.stop.name ?? "none"))", isOn: Binding(
                        get: { trip.pipeline.location.demoOverride },
                        set: { trip.pipeline.location.setDemoOverride($0) }))
                    Button("Marker debug view") { showMarkers = true }
                    Button("Route test") { showRouteTest = true }
                } label: {
                    Label("Debug", systemImage: "ladybug").font(.title3)
                }
            }
            // Required attribution for Transitous data.
            Link("Transit data: Transitous and sources", destination: TransitousClient.attributionURL)
                .font(.footnote)
        }
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
    }

    private func go() {
        let text = typed
        typed = ""
        trip.start(destination: text)
    }
}

private struct BigButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    init(_ title: String, color: Color, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, minHeight: 110)
                .background(color, in: RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(.white)
        }
    }
}
