import Foundation
import SwiftUI

/// The rider screen. Everything here is also spoken, so the screen is a fallback for VoiceOver and
/// for low-vision riders: black background, yellow-on-black and white-on-black only (contrast well
/// above WCAG AAA), large bold Dynamic Type, one big button for the current action at the bottom,
/// and every state carried by text and icons, never by colour alone.
struct RiderView: View {
    let trip: TripController
    @State private var typed = ""
    @State private var showMarkers = false
    @State private var showRouteTest = false
    @AppStorage("showRouteMap") private var showMap = false

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
                Palette.background.ignoresSafeArea()
            }
            VStack(spacing: 14) {
                if showMap && !scanning {
                    header
                    RouteMapView(trip: trip)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .frame(maxHeight: .infinity)
                    mainAction
                } else if trip.prompter.pending != nil {
                    // Scrolls only when it doesn't fit (largest text sizes, a long message plus a
                    // four-answer question), so no answer button ends up off screen.
                    ViewThatFits(in: .vertical) {
                        VStack(spacing: 14) { content; Spacer(minLength: 0); mainAction }
                        ScrollView { VStack(spacing: 14) { content; mainAction } }
                    }
                } else {
                    // Trip info scrolls; the action buttons stay pinned at the bottom, always in
                    // the same place, so they can be found by touch.
                    ScrollView { VStack(spacing: 14) { content } }
                        .scrollBounceBehavior(.basedOnSize)
                    mainAction
                }
                footer
            }
            .padding(16)
            .foregroundStyle(Palette.text)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showMarkers) {
            DebugView(pipeline: trip.pipeline)
                .onAppear { trip.pipeline.camera.start() }
                .onDisappear { if !scanning { trip.pipeline.camera.stop() } }
        }
        .sheet(isPresented: $showRouteTest) { NavigationDebugView() }
        // VoiceOver two-finger double-tap: the current main action, wherever focus is.
        .accessibilityAction(.magicTap) {
            if trip.prompter.pending != nil { return }
            if trip.needsCalibration { trip.calibrate() }
            else if !trip.isRouteActive { Task { await trip.askDestination() } }
        }
    }

    // MARK: - Top: status, current step, journey

    @ViewBuilder private var content: some View {
        header
        // Leg index, stops to go and the bus clock aren't observed, so refresh once a second.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 14) {
                if trip.isRouteActive && trip.phase != .planning {
                    currentStepCard
                    if trip.legs.count > 1 { JourneyOverview(legs: trip.legs, current: trip.legIndex) }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if trip.phase == .planning {
                    ProgressView().tint(Palette.accent).controlSize(.large)
                        .accessibilityHidden(true)
                }
                Text(trip.statusTitle)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if !trip.lastSpoken.isEmpty {
                Text(trip.lastSpoken)
                    .font(.title3)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Last message: \(trip.lastSpoken)")
            }
            if let g = trip.spotGuidance {
                Label("Waiting spot: \(g.clockHour) o'clock, \(g.distance, specifier: "%.1f") metres",
                      systemImage: "location.north.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(over: scanning)
    }

    /// The bus the rider is on or heading to, in large type (the header already says what to do
    /// right now). The line number is shown the way it appears on the bus front, for riders with
    /// some sight.
    @ViewBuilder private var currentStepCard: some View {
        if let (_, bus) = upcomingBus {
            BusCard(bus: bus,
                    departure: trip.departure ?? bus.estimate?.expectedDeparture,
                    now: trip.now,
                    stopsToGo: trip.stopsToGo,
                    riding: trip.phase == .riding,
                    heading: trip.phase == .walking ? "Your bus" : nil)
                .panel(over: scanning, highlighted: true)
        }
    }

    /// The bus leg the rider is on or heading to.
    private var upcomingBus: (Int, BusLeg)? {
        for i in trip.legIndex..<trip.legs.count {
            if case .bus(let b) = trip.legs[i] { return (i, b) }
        }
        return nil
    }

    // MARK: - Bottom: the one main action

    @ViewBuilder private var mainAction: some View {
        if let prompt = trip.prompter.pending {
            VStack(spacing: 12) {
                Text(prompt.question)
                    .font(.title.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(prompt.options) { option in
                    let secondary = option.id == "no" || option.id == "notYet"
                    BigButton(option.label, style: secondary ? .secondary : .primary) {
                        trip.prompter.choose(option)
                    }
                    .accessibilityHint(prompt.question)
                }
            }
            .panel(over: scanning)
        } else if trip.needsCalibration {
            VStack(spacing: 12) {
                BigButton("Set direction", icon: "location.north.line.fill", style: .primary) { trip.calibrate() }
                    .accessibilityHint("Hold your phone flat, top edge pointing where you face, then activate. This lines up the beacon sound with your AirPods.")
                BigButton("Skip", style: .secondary, compact: true) { trip.skipCalibration() }
                    .accessibilityHint("Uses your walking direction instead.")
            }
        } else if !trip.isRouteActive {
            VStack(spacing: 12) {
                BigButton(trip.listeningForDestination ? "Listening…" : "Where to?",
                          icon: trip.listeningForDestination ? "waveform" : "mic.fill",
                          style: .primary, tall: true) {
                    Task { await trip.askDestination() }
                }
                .accessibilityHint("Say a destination, for example Getreidegasse. A two-finger double-tap also starts this.")
                HStack(spacing: 10) {
                    // Explicit colours: the screen is always black, the field always white.
                    TextField("", text: $typed, prompt: Text("Or type a destination").foregroundStyle(Color(white: 0.35)))
                        .font(.title3.bold())
                        .padding(.horizontal, 14)
                        .frame(minHeight: 60)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.black)
                        .tint(.black)
                        .accessibilityLabel("Destination")
                        .submitLabel(.go)
                        .onSubmit(go)
                    Button(action: go) {
                        Text("Go").font(.title2.bold())
                            .frame(minWidth: 72, minHeight: 60)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.black)
                    }
                    .disabled(typed.isEmpty)
                    .opacity(typed.isEmpty ? 0.5 : 1)
                    .accessibilityLabel("Go to typed destination")
                }
            }
        } else {
            HStack(spacing: 12) {
                BigButton("Repeat", icon: "arrow.counterclockwise", style: .secondary, compact: true) {
                    trip.audio.speak(trip.lastSpoken)
                }
                .disabled(trip.lastSpoken.isEmpty)
                .accessibilityLabel("Repeat last message")
                .accessibilityHint("Speaks the last instruction again.")
                BigButton("Stop route", icon: "xmark.octagon.fill", style: .danger, compact: true) { trip.stop() }
                    .accessibilityHint("Stops all guidance right away.")
            }
        }
    }

    // MARK: - Footer: developer tools and the required data attribution

    private var footer: some View {
        HStack(alignment: .center) {
            // Required attribution for Transitous data.
            Link("Transit data: Transitous and sources", destination: TransitousClient.attributionURL)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
                .underline()
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
                Image(systemName: "ladybug")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(Palette.secondaryText)
            }
            .accessibilityLabel("Debug")
            .accessibilityHint("Developer tools for testing.")
        }
        .padding(.horizontal, 6)
        .background(scanning ? Color.black.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 12))
        // VoiceOver reaches the developer tools last.
        .accessibilitySortPriority(-1)
    }

    private func go() {
        let text = typed
        guard !text.isEmpty else { return }
        typed = ""
        trip.start(destination: text)
    }
}

// MARK: - Palette

/// Only high-contrast pairs: yellow or white on black (≈ 15:1 and 21:1), black on yellow, white on dark red (≈ 8:1).
private enum Palette {
    static let background = Color.black
    static let panel = Color(white: 0.11)
    static let text = Color.white
    static let secondaryText = Color(white: 0.82)
    static let accent = Color(red: 1, green: 0.84, blue: 0.04)      // #FFD60A
    static let danger = Color(red: 0.62, green: 0, blue: 0.1)
}

private extension View {
    /// A dark rounded panel. Over the camera it's more opaque so text stays readable.
    func panel(over camera: Bool = false, highlighted: Bool = false) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(camera ? Color.black.opacity(0.8) : Palette.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                if highlighted { RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.accent, lineWidth: 3) }
            }
    }
}

// MARK: - Cards

private struct BusCard: View {
    let bus: BusLeg
    let departure: Date?
    let now: Date
    let stopsToGo: Int?
    let riding: Bool
    var heading: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let heading {
                Text(heading).font(.headline).foregroundStyle(Palette.secondaryText)
            }
            busRow
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((heading.map { "\($0). " } ?? "") + accessibilityText)
    }

    private var busRow: some View {
        HStack(alignment: .top, spacing: 16) {
            // Line number like on the bus front display.
            Text(bus.line ?? "Bus")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(minWidth: 96, minHeight: 96)
                .padding(.horizontal, 8)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(.black)
            VStack(alignment: .leading, spacing: 6) {
                if let direction = bus.direction {
                    Text("towards \(direction)").font(.title2.bold())
                }
                if riding {
                    if let stopsToGo {
                        Text(stopsToGo <= 1 ? "Next stop is yours" : "\(stopsToGo) stops to go")
                            .font(.title2.bold()).foregroundStyle(Palette.accent)
                    }
                    Text("Get off at \(bus.alightingStop.spokenName)").font(.title3)
                } else {
                    Text(stopLine).font(.title3)
                    if let departure {
                        Text(departureLine(departure)).font(.title2.bold()).foregroundStyle(Palette.accent)
                    }
                }
                if bus.wheelchairAccessible == true {
                    Label("Step-free bus", systemImage: "figure.roll").font(.headline)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stopLine: String {
        var s = "From \(bus.boardingStop.spokenName)"
        if let p = bus.boardingPlatform, !p.isEmpty { s += ", platform \(p)" }
        return s
    }

    private func minutes(until date: Date) -> Int { max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up))) }

    private func departureLine(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let m = minutes(until: date)
        return m == 0 ? "Due now · \(time)" : "In \(m) min · \(time)"
    }

    private var accessibilityText: String {
        var s = "Bus \(bus.line ?? "")" + (bus.direction.map { " towards \($0)" } ?? "") + "."
        if riding {
            if let stopsToGo { s += stopsToGo <= 1 ? " Next stop is yours." : " \(stopsToGo) stops to go." }
            s += " Get off at \(bus.alightingStop.spokenName)."
        } else {
            s += " \(stopLine)."
            if let departure {
                let m = minutes(until: departure)
                s += " Departs \(departure.formatted(date: .omitted, time: .shortened))"
                s += m == 0 ? ", due now." : ", in \(m) minute\(m == 1 ? "" : "s")."
            }
        }
        if bus.wheelchairAccessible == true { s += " Step-free bus." }
        return s
    }
}

/// Every leg of the trip in one list. "Done", "Now" and "Next" are written out, so the state
/// doesn't depend on colour.
private struct JourneyOverview: View {
    let legs: [Leg]
    let current: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your trip").font(.headline).foregroundStyle(Palette.secondaryText)
                .accessibilityAddTraits(.isHeader)
            ForEach(legs.indices, id: \.self) { i in
                row(i)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(i + 1) of \(legs.count), \(state(i).lowercased()): \(title(legs[i]))")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(_ i: Int) -> some View {
        let isNow = i == current
        return HStack(spacing: 12) {
            Image(systemName: i < current ? "checkmark.circle.fill" : icon(legs[i]))
                .font(.title3.bold())
                .frame(width: 32)
            Text(title(legs[i]))
                .font(isNow ? .title3.bold() : .body)
                .strikethrough(i < current)
            Spacer(minLength: 8)
            Text(state(i))
                .font(.subheadline.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isNow ? Palette.accent : .clear, in: Capsule())
                .foregroundStyle(isNow ? .black : Palette.secondaryText)
        }
        .foregroundStyle(i < current ? Palette.secondaryText : Palette.text)
    }

    private func state(_ i: Int) -> String { i < current ? "Done" : i == current ? "Now" : "Next" }

    private func icon(_ leg: Leg) -> String {
        if case .bus = leg { return "bus.fill" }
        return "figure.walk"
    }

    private func title(_ leg: Leg) -> String {
        switch leg {
        case .walk(let w): "Walk \(Int(w.distanceMeters)) m to \(w.to.spokenName)"
        case .bus(let b): "Bus \(b.line ?? "") to \(b.alightingStop.spokenName)"
        }
    }
}

// MARK: - Button

private struct BigButton: View {
    enum Style { case primary, secondary, danger }

    let title: String
    let icon: String?
    let style: Style
    let tall: Bool
    let compact: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, icon: String? = nil, style: Style, tall: Bool = false, compact: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.style = style
        self.tall = tall
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon { Image(systemName: icon).accessibilityHidden(true) }
                Text(title).multilineTextAlignment(.center)
            }
            .font(compact ? .title2.bold() : .largeTitle.bold())
            .frame(maxWidth: .infinity, minHeight: tall ? 150 : compact ? 72 : 110)
            .padding(.horizontal, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                if style == .secondary {
                    RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.text, lineWidth: 3)
                }
            }
            .foregroundStyle(style == .primary ? Color.black : Palette.text)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch style {
        case .primary: Palette.accent
        case .secondary: Palette.panel
        case .danger: Palette.danger
        }
    }
}
