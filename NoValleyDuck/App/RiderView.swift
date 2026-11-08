import SwiftUI

/// The rider screen. Everything here is also spoken, so the screen is only a fallback: one big
/// button for the current action, large text, VoiceOver labels everywhere.
struct RiderView: View {
    let trip: TripController
    @State private var typed = ""
    @State private var showMarkers = false
    @State private var showRouteTest = false
    @AppStorage("showRouteMap") private var showMap = false
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
                if showMap && !scanning {
                    header
                    RouteMapView(trip: trip)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxHeight: .infinity)
                    mainAction
                } else {
                    // Scrolls only when it doesn't fit (largest text sizes, a long message plus a
                    // four-answer question), so no button ends up off screen.
                    ViewThatFits(in: .vertical) {
                        VStack(spacing: 16) { header; Spacer(minLength: 0); mainAction }
                        ScrollView { VStack(spacing: 16) { header; mainAction } }
                    }
                }
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
        // VoiceOver two-finger double-tap: the current main action, wherever focus is.
        .accessibilityAction(.magicTap) {
            if trip.prompter.pending != nil { return }
            if trip.needsCalibration { trip.calibrate() }
            else if !trip.isRouteActive { Task { await trip.askDestination() } }
        }
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
                    BigButton(option.label, color: option.id == "no" || option.id == "notYet" ? Color(white: 0.3) : .blue) {
                        trip.prompter.choose(option)
                    }
                    .accessibilityHint(prompt.question)
                }
            }
        } else if trip.needsCalibration {
            VStack(spacing: 12) {
                BigButton("Set direction", color: .blue) { trip.calibrate() }
                    .accessibilityHint("Hold your phone flat, top edge pointing where you face, then activate. This lines up the beacon sound with your AirPods.")
                Button { trip.skipCalibration() } label: {
                    Text("Skip").font(.title3).frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityHint("Uses your walking direction instead.")
            }
        } else if !trip.isRouteActive {
            VStack(spacing: 12) {
                BigButton(trip.listeningForDestination ? "Listening…" : "Where to?", color: .blue) {
                    Task { await trip.askDestination() }
                }
                .accessibilityHint("Say a destination, for example Getreidegasse. A two-finger double-tap also starts this.")
                HStack {
                    // Explicit colours: the system field is dark in dark mode, and the screen is always black.
                    TextField("", text: $typed, prompt: Text("Or type a destination").foregroundStyle(.gray))
                        .font(.title3)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.black)
                        .accessibilityLabel("Destination")
                        .submitLabel(.go)
                        .onSubmit(go)
                    Button("Go", action: go).font(.title3.bold()).disabled(typed.isEmpty)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Go to typed destination")
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
                    .accessibilityHint("Stops all guidance right away.")
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
                    Toggle("Show route map", isOn: $showMap)
                } label: {
                    Label("Debug", systemImage: "ladybug").font(.title3)
                }
                .accessibilityHint("Developer tools for testing.")
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
