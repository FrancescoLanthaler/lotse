import CoreLocation
import Observation
import UIKit
import UserNotifications
import os

private let log = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "route")

/// Runs one trip door to door (SPEC §2): plan → walk with the spatial beacon → find the stop and
/// the waiting spot with markers → board → ride → exit scan → last walk. Everything that must
/// keep working with the screen locked is driven by location updates and a run-loop timer here,
/// not by UI code.
@Observable
@MainActor
final class TripController: NSObject, CLLocationManagerDelegate {
    static let shared = TripController()
    /// "Board bus X?" (and with it the driver's pickup message) comes this long before the scheduled
    /// departure. Not just 3 min: at a terminus like Salzburg Messe the bus stands there early and
    /// riders got on before the question, so the driver never heard of them.
    static let boardAskLead: TimeInterval = 10 * 60

    enum Phase: Equatable {
        case idle, planning
        case walking
        case scanning(exit: Bool)     // Phase 3 (find the bay) or Phase 6 (confirm the exit stop)
        case toSpot                   // Phase 3 step 4: guidance to the waiting spot
        case waiting                  // Phase 4
        case riding                   // Phase 5
        case arrived
    }

    private(set) var phase: Phase = .idle { didSet { updateLiveActivity() } }
    @ObservationIgnored private var requestedDestination: String?
    @ObservationIgnored private var walkRemaining: Double?       // metres left on the walk, for the Live Activity
    @ObservationIgnored private var walkTurn: (name: String, meters: Double)?
    private(set) var lastSpoken = ""
    private(set) var plan: NavigationPlan?
    private(set) var needsCalibration = false
    private(set) var listeningForDestination = false
    private(set) var spotGuidance: Guidance?
    private(set) var departure: Date?
    /// Debug: shifts the app's clock for the "fast-forward" button.
    private(set) var timeShift: TimeInterval = 0

    let pipeline = MarkerPipeline()
    let audio: AudioGuide
    let voice: VoiceInput
    let prompter: Prompter
    @ObservationIgnored let head = HeadTracker()
    @ObservationIgnored private let navigation = NavigationService()
    @ObservationIgnored private let driver = DriverClient()
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var setUp = false

    // Location
    @ObservationIgnored private(set) var location: CLLocation?
    @ObservationIgnored private var phoneHeading: Double?
    @ObservationIgnored private var phoneHeadingAccuracy: Double = -1     // degrees, < 0 = invalid
    @ObservationIgnored private var weakFixSince: Date?
    @ObservationIgnored private var warnedWeakFix = false
    @ObservationIgnored private var recentCourses: [Double] = []
    @ObservationIgnored private var simulating = false

    // Legs (a copy of the plan's, so redirects and re-plans can replace them)
    @ObservationIgnored private(set) var legs: [Leg] = []
    @ObservationIgnored private(set) var legIndex = 0 { didSet { updateLiveActivity() } }

    // Walking
    @ObservationIgnored private(set) var checkpoints: [Checkpoint] = []
    @ObservationIgnored private(set) var checkpointIndex = 0
    @ObservationIgnored private var announcedTurns: Set<Int> = []
    @ObservationIgnored private var offRouteSince: Date?
    @ObservationIgnored private var lastDistanceUpdate: (at: Date, remaining: Double)?
    @ObservationIgnored private var replanning = false
    @ObservationIgnored private var lastPing = Date.distantPast
    @ObservationIgnored private var lastDirectionLog = Date.distantPast

    // Stop, bay and bus
    @ObservationIgnored private var bus: BusLeg?
    @ObservationIgnored private var stopContext: StopContext?
    @ObservationIgnored private var timetable: Timetable?
    @ObservationIgnored private var targetBayId: String?
    @ObservationIgnored private var spotBayId: String?
    @ObservationIgnored private var checkingBay = false

    // Scanning and waiting spot
    @ObservationIgnored private var scanStarted = Date.distantPast
    @ObservationIgnored private var cameraOn = false
    @ObservationIgnored private var lastTick = Date.distantPast
    @ObservationIgnored private var lastNoMarkerHint: Date?
    @ObservationIgnored private var lastUnlockHint: Date?
    @ObservationIgnored private var lastFrame: FrameResult?
    @ObservationIgnored private var spot: SIMD3<Double>?
    @ObservationIgnored private var lastSpotSeen: Date?
    @ObservationIgnored private var lastSpotSpoken: (at: Date, text: String)?
    @ObservationIgnored private var lastSpotBeep = Date.distantPast
    @ObservationIgnored private var spotLostSaid = false

    // Waiting and boarding
    @ObservationIgnored private var askedBoard = false
    @ObservationIgnored private var boardRetry: Date?
    @ObservationIgnored private var pickupRequestId: String?
    @ObservationIgnored private var nextComeCheck: Date?
    @ObservationIgnored private var fastSince: Date?
    @ObservationIgnored private var boardingAskAfter = Date.distantPast

    // Riding
    @ObservationIgnored private var rideStops: [Place] = []
    @ObservationIgnored private var reachedStop = -1 { didSet { updateLiveActivity() } }
    @ObservationIgnored private var askedStopRequest = false
    @ObservationIgnored private var nearExitSince: Date?

    override init() {
        let audio = AudioGuide(), voice = VoiceInput()
        self.audio = audio
        self.voice = voice
        prompter = Prompter(audio: audio, voice: voice)
        super.init()
    }

    var now: Date { Date().addingTimeInterval(timeShift) }
    var isRouteActive: Bool { phase != .idle && phase != .arrived }
    /// Stops left until the exit stop while riding, for the rider screen (not observed: poll it).
    var stopsToGo: Int? { phase == .riding && !rideStops.isEmpty ? rideStops.count - 1 - reachedStop : nil }
    private var busName: String { bus?.line.map { "Bus \($0)" } ?? "The bus" }
    private var stopName: String { bus?.boardingStop.spokenName ?? stopContext?.stop.name ?? "the stop" }
    private var lateralSign: Double { GuidanceEngine.portraitLateralSign * (pipeline.lateralFlipped ? -1 : 1) }

    /// One line for the screen and VoiceOver.
    var statusTitle: String {
        switch phase {
        case .idle: "Where to?"
        case .planning: "Planning your route"
        case .walking:
            if case .walk(let w)? = legs[safe: legIndex] { "Walking to \(w.to.spokenName)" } else { "Walking" }
        case .scanning(let exit): exit ? "Confirm the stop: hold your phone up and turn slowly"
            : "Find the stop marker: hold your phone up and turn slowly"
        case .toSpot: "Going to the waiting spot"
        case .waiting:
            "Waiting for \(busName.lowercased())" + (departure.map { ", due \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
        case .riding: "On \(busName.lowercased())"
        case .arrived: "Arrived at \(plan?.destination.spokenName ?? "your destination")"
        }
    }

    private func updateLiveActivity() {
        var state = TripActivityAttributes.ContentState(
            status: statusTitle, symbol: TripLiveActivity.symbol(phase), headline: statusTitle)
        switch phase {
        case .walking:
            if case .walk(let w)? = legs[safe: legIndex] {
                let target = w.to.spokenName
                state.headline = walkTurn.map { "Turn \($0.name)" } ?? "Continue to \(target)"
                state.symbol = walkTurn.map { Self.turnSymbol($0.name) } ?? "arrow.up"
                state.distanceMeters = (walkTurn?.meters ?? walkRemaining).map { Int(($0 / 10).rounded()) * 10 }
                state.totalMeters = walkRemaining.map { Int(($0 / 10).rounded()) * 10 }
                if let r = walkRemaining, w.distanceMeters > 0 { state.progress = min(1, max(0, 1 - r / w.distanceMeters)) }
            }
        case .waiting:
            state.headline = [bus?.line.map { "Bus \($0)" }, bus?.direction.map { "to \($0)" }]
                .compactMap { $0 }.joined(separator: " ")
            state.time = departure
            state.timeLabel = "Departs"
        case .riding:
            let next = reachedStop + 1
            if next < rideStops.count {
                state.headline = "Next stop: \(rideStops[next].spokenName)"
                state.progress = Double(next) / Double(rideStops.count)
                let left = rideStops.count - next
                state.status = "\(left) stop\(left == 1 ? "" : "s") to go"
            }
        default: break
        }
        state.eta = etaAtDestination()
        TripLiveActivity.update(phase: phase, destination: plan?.destination.spokenName ?? requestedDestination,
                                state: state)
    }

    /// Arrival at the destination: this leg's remaining time, then the bus timetable and later walks.
    private func etaAtDestination() -> Date? {
        guard legIndex < legs.count else { return nil }
        var t: Date?
        if phase == .walking, case .walk(let w) = legs[legIndex], let r = walkRemaining {
            t = now.addingTimeInterval(r / 1.3)     // HACK: 1.3 m/s walking speed
            _ = w
        } else if case .bus(let b) = legs[legIndex] {
            t = b.estimate?.expectedArrival
        }
        for leg in legs[(legIndex + 1)...] {
            switch leg {
            case .bus(let b): t = b.estimate?.expectedArrival ?? t
            case .walk(let w): t = t?.addingTimeInterval(w.expectedTravelTimeSeconds)
            }
        }
        return t
    }

    private static func turnSymbol(_ turn: String) -> String {
        switch turn {
        case "slight left": "arrow.up.left"
        case "slight right": "arrow.up.right"
        case let t where t.contains("left"): "arrow.turn.up.left"
        case let t where t.contains("right"): "arrow.turn.up.right"
        default: "arrow.up"
        }
    }

    // MARK: - Setup

    /// Called at launch (and by Siri): camera permission, stop data, location.
    func setup() async {
        guard !setUp else { return }
        setUp = true
        configureLocation()
        Task { [weak self] in
            guard let self else { return }
            for await e in self.pipeline.events() { self.handle(e) }
        }
        await pipeline.start()
        // The pipeline starts the camera; keep it off until a scan needs it (battery).
        if !needsCamera { pipeline.camera.stop() }
        UIApplication.shared.isIdleTimerDisabled = needsCamera
    }

    private func configureLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.requestWhenInUseAuthorization()
    }

    private var needsCamera: Bool {
        if case .scanning = phase { return true }
        return phase == .toSpot
    }

    // MARK: - Phase 1: destination

    /// The in-app "Where to?" button.
    func askDestination() async {
        guard !isRouteActive, !listeningForDestination else { return }
        audio.start()
        guard await VoiceInput.requestAccess() else {
            await say("Microphone or speech recognition access is off. You can type the destination instead.", idle: true)
            return
        }
        await say("Where to?", idle: true)
        listeningForDestination = true
        let text = await voice.listen(timeout: 8, hints: Self.placeHints, alsoIn: Locale(identifier: "de-AT"))
        listeningForDestination = false
        guard let text = text ?? voice.otherLanguage, !text.isEmpty else {
            await say("I didn't catch that. Use the Where to button again, or type the destination.", idle: true)
            if !isRouteActive { audio.stop() }
            return
        }
        start(destination: text, heard: voice.alternatives, german: voice.otherLanguage)
    }

    /// The known place a transcription most likely meant ("Oil park" → "Europark"), nil if none is
    /// close. Short names must match exactly, else "mall" would become "Mülln". "Salzburg" is ignored,
    /// else "Cool Mama Hotel Salzburg" would become "Messe Salzburg". Only a fallback when the search
    /// for the words as heard finds nothing.
    static func matchPlace(_ heard: [String], in places: [String] = placeHints) -> String? {
        func norm<S: StringProtocol>(_ s: S) -> [Character] {
            Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber })
        }
        var best: (place: String, score: Double)?
        for h in heard {
            let words = h.split(separator: " ").filter { norm($0) != norm("Salzburg") }
            for i in words.indices {
                for n in 1...3 where i + n <= words.count {            // "take me to Euro park"
                    let w = norm(words[i..<(i + n)].joined())
                    for p in places {
                        let q = norm(p.split(separator: " ").filter { norm($0) != norm("Salzburg") }.joined())
                        let score = w == q ? 1
                            : w.count >= 6 && q.count >= 6
                            ? 1 - Double(q.difference(from: w).count) / Double(w.count + q.count) : 0
                        if score >= 0.6, score > best?.score ?? 0 { best = (p, score) }
                    }
                }
            }
        }
        return best?.place
    }

    // HACK: hand-picked Salzburg destinations so the English recogniser hears "Europark", not "Oilpark".
    nonisolated static let placeHints = [
        "Europark", "Mirabellplatz", "Getreidegasse", "Hauptbahnhof", "Hanuschplatz", "Ferdinand-Hanusch-Platz",
        "Residenzplatz", "Mozartplatz", "Kapitelplatz", "Domplatz", "Festspielhaus", "Makartplatz", "Linzergasse",
        "Kajetanerplatz", "Rathaus", "Messe Salzburg", "Salzburgarena", "Red Bull Arena", "Flughafen Salzburg",
        "Hellbrunn", "Kleßheim", "Alpenstraße", "Lehen", "Itzling", "Gnigl", "Obergnigl", "Nonntal", "Mülln",
        "Maxglan", "Liefering", "Parsch", "Aigen", "Anif", "Grödig", "Wals", "Taxham", "Zentrum im Berg",
        "Unipark Nonntal", "Landeskrankenhaus", "Universität Salzburg", "Hofstallgasse", "Bürgerspitalgasse",
    ]

    /// When the search finds nothing for `destination`, the app tries what the German recogniser
    /// heard, then the closest name from the place list (`heard` = the recogniser's other guesses).
    func start(destination: String, heard: [String] = [], german: String? = nil) {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return }
        var fallbacks: [String] = []
        for f in [german, Self.matchPlace(heard + [german, destination].compactMap { $0 })].compactMap({ $0 })
        where !([destination] + fallbacks).contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) {
            fallbacks.append(f)
        }
        guard !isRouteActive else { speak("A route is already running. Stop it first."); return }
        requestedDestination = destination
        plan = nil          // before phase: its didSet reads plan for the Live Activity title
        phase = .planning
        beginSession()
        Task { await planRoute(to: destination, fallbacks: fallbacks) }
    }

    private func planRoute(to destination: String, fallbacks: [String]) async {
        speak("Looking for \(destination).")
        do {
            var plan: NavigationPlan?
            for (i, query) in ([destination] + fallbacks).enumerated() where plan == nil {
                guard phase == .planning else { return }
                if i > 0 { speak("Not found. Trying \(query).") }
                do {
                    plan = try await navigation.plan(to: query)
                } catch NavigationError.destinationNotFound where i < fallbacks.count {
                    continue
                }
            }
            guard let plan, phase == .planning else { return }
            self.plan = plan
            legs = plan.legs
            await say("\(Self.readback(plan.destination)). Starting route.")
            await say(Self.summary(plan))
            guard phase == .planning else { return }          // stopped while speaking
            if case .walk = legs.first {
                // Nobody knows what the beeps mean unless we say it once.
                speak("Follow the beacon sound: it comes from the direction to walk. A quick double beep means you're facing the right way, a chime means you passed a point on the route.")
            }
            if head.isConnected {
                needsCalibration = true
                speak("So the sound turns with your head, hold your phone flat in front of you, top edge pointing where you face, and press Set direction. Or just start walking.")
            }
            beginLeg(0)
        } catch {
            guard phase == .planning else { return }
            await say("\(error.localizedDescription) Route not started.")
            if phase == .planning { end() }
        }
    }

    /// "Getreidegasse, 5020 Salzburg"
    static func readback(_ place: Place) -> String {
        guard let address = place.address, !address.isEmpty, address != place.name else { return place.spokenName }
        let rest = address.components(separatedBy: ", ").filter { $0 != place.name && $0 != "Austria" && $0 != "Österreich" }
        return ([place.spokenName] + rest.prefix(2)).joined(separator: ", ")
    }

    /// "Walk 4 minutes to Mirabellplatz, bus 2 towards Obergnigl, 3 stops, then walk 2 minutes."
    static func summary(_ plan: NavigationPlan) -> String {
        var parts: [String] = []
        var leaves: String?
        for (i, leg) in plan.legs.enumerated() {
            switch leg {
            case .walk(let w):
                let m = max(1, Int((w.expectedTravelTimeSeconds / 60).rounded()))
                let mins = "\(m) minute\(m == 1 ? "" : "s")"
                parts.append(i == 0 ? "walk \(mins) to \(w.to.spokenName)" : "then walk \(mins)")
            case .bus(let b):
                var s = b.line.map { "bus \($0)" } ?? "a bus"
                if let d = b.direction { s += " towards \(spoken(d))" }
                if b.source == .transitous { s += ", \(b.stopsToRide) stop\(b.stopsToRide == 1 ? "" : "s")" }
                if i == 0 { s = "take \(s) from \(b.boardingStop.spokenName)" }
                parts.append(s)
                if leaves == nil, let e = b.estimate {
                    leaves = " The bus leaves at \(e.expectedDeparture.formatted(date: .omitted, time: .shortened))."
                }
            }
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst() + "." + (leaves ?? "")
    }

    /// Timetable names carry the town ("Salzburg Obergnigl"); drop it for speech.
    static func spoken(_ name: String) -> String {
        name.hasPrefix("Salzburg ") ? String(name.dropFirst("Salzburg ".count)) : name
    }

    // MARK: - Session (screen locked keeps working)

    private func beginSession() {
        audio.start()
        head.start()
        head.onGesture = { [weak self] g in self?.prompter.gesture(g) }
        configureLocation()
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops the route (Siri "stop guiding", the Stop button, or a failed plan).
    func stop() {
        guard isRouteActive || phase == .arrived else { return }
        if let id = pickupRequestId, phase == .waiting { Task { try? await driver.setStatus(request: id, "cancelled") } }
        // Everything off right away: a plan, prompt or message still in flight finds the phase idle
        // and stops there. Only the audio stays on for the last message.
        end(keepAudio: true)
        audio.stopSpeaking()
        Task {
            await say("Route stopped.", idle: true)
            if phase == .idle { audio.stop() }       // unless a new route started meanwhile
        }
    }

    private func end(keepAudio: Bool = false) {
        phase = .idle
        timer?.invalidate()
        timer = nil
        setCamera(false)
        prompter.cancel()
        voice.cancel()
        head.stop()
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        locationManager.allowsBackgroundLocationUpdates = false
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["scan"])
        if !keepAudio { audio.stop() }
        resetTripState()
    }

    private func resetTripState() {
        legs = []; legIndex = 0; bus = nil; stopContext = nil; timetable = nil
        targetBayId = nil; spotBayId = nil; departure = nil; askedBoard = false; boardRetry = nil
        pickupRequestId = nil; nextComeCheck = nil; fastSince = nil; rideStops = []; reachedStop = -1
        askedStopRequest = false; nearExitSince = nil; spot = nil; spotGuidance = nil
        needsCalibration = false; timeShift = 0; simulating = false
        pipeline.location.pin(nil)
    }

    /// Trip speech. Silent once the route is stopped (`idle`), so nothing from the old route is
    /// spoken after "Route stopped."; `idle: true` is for the messages that belong there.
    private func say(_ text: String, idle: Bool = false) async {
        guard idle || phase != .idle else { return }
        lastSpoken = text
        await audio.say(text)
    }

    private func speak(_ text: String) {
        guard phase != .idle else { return }
        lastSpoken = text
        audio.speak(text)
    }

    // MARK: - Legs

    private func beginLeg(_ i: Int) {
        legIndex = i
        guard i < legs.count else { arrive(); return }
        switch legs[i] {
        case .walk(let w): startWalk(w)
        case .bus(let b):
            bus = b
            startScan(exit: false)
        }
    }

    private func arrive() {
        phase = .arrived
        setCamera(false)
        Task {
            await say("You've arrived at \(plan?.destination.spokenName ?? "your destination").")
            guard phase == .arrived else { return }
            end()
            phase = .arrived
        }
    }

    // MARK: - Phase 2: walking with the beacon

    private func startWalk(_ w: WalkingLeg) {
        phase = .walking
        setCamera(false)
        checkpoints = RouteGeometry.checkpoints(for: w)
        checkpointIndex = 0
        announcedTurns = []
        offRouteSince = nil
        lastDistanceUpdate = nil
        walkRemaining = nil; walkTurn = nil
        weakFixSince = nil
        warnedWeakFix = false
        log.info("walk to \(w.to.name, privacy: .public): \(self.checkpoints.count) checkpoints")
    }

    /// Head direction: AirPods (calibrated / GPS-aligned), else the walking course, else the phone compass.
    private var heading: (degrees: Double, source: String)? {
        if let h = head.heading { return (h, "AirPods") }
        if let loc = location, loc.speed > 0.7, loc.course >= 0 { return (loc.course, "walking course") }
        return phoneHeading.map { ($0, "phone compass") }
    }

    /// Debug: what the beacon is based on right now (shown on the route map).
    var directionInfo: (location: CLLocation, heading: Double?, target: Coordinate, text: String)? {
        guard phase == .walking, checkpointIndex < checkpoints.count, let loc = location else { return nil }
        let target = checkpoints[checkpointIndex].coordinate
        let bearing = Coordinate(loc.coordinate).bearing(to: target)
        let d = Int(Coordinate(loc.coordinate).distance(to: target))
        guard let h = heading else {
            return (loc, nil, target, "Target \(Int(bearing))° \(d) m · no heading yet · GPS ±\(Int(loc.horizontalAccuracy)) m")
        }
        let off = Int((bearing - h.degrees + 540).truncatingRemainder(dividingBy: 360) - 180)
        return (loc, h.degrees, target, "Facing \(Int(h.degrees))° (\(h.source)) · target \(Int(bearing))° \(d) m · off \(off)° · GPS ±\(Int(loc.horizontalAccuracy)) m")
    }

    private func walkTick() {
        guard checkpointIndex < checkpoints.count, let loc = location else { return }
        let target = checkpoints[checkpointIndex].coordinate
        let bearing = Coordinate(loc.coordinate).bearing(to: target)
        let angle = heading.map { (bearing - $0.degrees + 540).truncatingRemainder(dividingBy: 360) - 180 } ?? 0
        // With the fix error near the distance to the target (indoors), the direction can be anything:
        // then never claim "facing the right way".
        let weak = loc.horizontalAccuracy > max(20, Coordinate(loc.coordinate).distance(to: target) / 2)
        let onTarget = heading != nil && !weak && abs(angle) < 20
        if weak, loc.horizontalAccuracy > 20 {
            let since = weakFixSince ?? now
            weakFixSince = since
            if !warnedWeakFix, now.timeIntervalSince(since) >= 5, !audio.isSpeaking {
                warnedWeakFix = true
                speak("Your position is uncertain here, so the beacon direction may be wrong. It gets better outside.")
            }
        } else {
            weakFixSince = nil
        }
        if now.timeIntervalSince(lastDirectionLog) >= 5, let info = directionInfo {
            lastDirectionLog = now
            log.info("direction: \(info.text, privacy: .public)")
        }
        audio.moveBeacon(angle: angle)
        if now.timeIntervalSince(lastPing) >= (onTarget ? 0.8 : 1.1) {
            lastPing = now
            audio.ping(angle: angle, onTarget: onTarget)
        }
    }

    private func walkLocation(_ loc: CLLocation) {
        guard case .walk(let w)? = legs[safe: legIndex], checkpointIndex < checkpoints.count else { return }
        let p = Coordinate(loc.coordinate)

        // GPS course re-aligns the AirPods yaw while walking straight (SPEC Phase 2, head direction).
        if loc.speed > 0.8, loc.course >= 0 {
            recentCourses = Array((recentCourses + [loc.course]).suffix(5))
            let spread = recentCourses.map { abs(($0 - loc.course + 540).truncatingRemainder(dividingBy: 360) - 180) }.max() ?? 180
            if recentCourses.count == 5, spread < 15 { head.align(toCourse: loc.course) }
        } else {
            recentCourses = []
        }

        // Checkpoints: reached within 10 m. The last one (the stop or the destination) allows for
        // GPS error up to 20 m, otherwise a 15 m fix could never "arrive". Coarser fixes (indoors,
        // Wi-Fi only) can't arrive at all: they put a rider inside a building at the stop next to it.
        let last = checkpoints.count - 1
        if let j = (checkpointIndex...last).last(where: { k in
            if k == last, loc.horizontalAccuracy > 20 { return false }
            let reach = k == last ? max(10, loc.horizontalAccuracy) : 10
            return checkpoints[k].coordinate.distance(to: p) <= reach
        }) {
            checkpointIndex = j + 1
            if checkpointIndex > last { finishWalk(); return }
            audio.play(.chime)
        }
        // Walked past a checkpoint without the fix coming within 10 m (GPS error, other side of the
        // street): aim at the next one instead of back at it. Never skips to the final target.
        let ahead = RouteGeometry.nextIndex(after: p, checkpoints: checkpoints, from: checkpointIndex)
        if ahead > checkpointIndex, ahead < last, loc.horizontalAccuracy <= 25 {
            checkpointIndex = ahead
            audio.play(.chime)
        }

        // Turn callouts: "Turn left in 10 metres."
        if let k = (checkpointIndex...min(checkpointIndex + 2, last)).first(where: { checkpoints[$0].turn != nil }),
           !announcedTurns.contains(k), let turn = checkpoints[k].turn {
            let d = checkpoints[k].coordinate.distance(to: p)
            if d <= 20 {
                announcedTurns.insert(k)
                speak(d < 8 ? "Turn \(turn) now." : "Turn \(turn) in \(Int((d / 5).rounded()) * 5) metres.")
            }
        }

        // Distance updates.
        let remaining = RouteGeometry.remaining(from: p, checkpoints: checkpoints, index: checkpointIndex)
        if let u = lastDistanceUpdate {
            if !audio.isSpeaking, now.timeIntervalSince(u.at) >= 45 || u.remaining - remaining >= 75 {
                lastDistanceUpdate = (now, remaining)
                speak("\(Int((remaining / 10).rounded()) * 10) metres to \(w.to.spokenName).")
            }
        } else {
            lastDistanceUpdate = (now, remaining)
        }

        // Live Activity: only when the 10 m rounded distances or the next turn change.
        let turn = (checkpointIndex...last).first(where: { checkpoints[$0].turn != nil }).flatMap { k in
            checkpoints[k].turn.map { (name: $0, meters: checkpoints[k].coordinate.distance(to: p)) }
        }
        if walkTurn?.name != turn?.name || walkTurn.map({ Int($0.meters / 10) }) != turn.map({ Int($0.meters / 10) })
            || walkRemaining.map({ Int($0 / 10) }) != Int(remaining / 10) {
            walkRemaining = remaining
            walkTurn = turn
            updateLiveActivity()
        }

        // Off route: more than 30 m from the path for 10 s → recalculate.
        if RouteGeometry.distance(from: p, toPath: w.path) > 30, loc.horizontalAccuracy <= 30, !replanning {
            let since = offRouteSince ?? now
            offRouteSince = since
            if now.timeIntervalSince(since) >= 10 { replan(from: p, to: w.to) }
        } else {
            offRouteSince = nil
        }
    }

    private func replan(from p: Coordinate, to destination: Place) {
        replanning = true
        speak("You're off the route. Finding a new route.")
        let index = legIndex
        Task {
            let leg = await navigation.walkingLegOrStraightLine(
                from: Place(name: "Current location", address: nil, coordinate: p), to: destination)
            replanning = false
            guard phase == .walking, legIndex == index else { return }
            legs[index] = .walk(leg: leg)
            startWalk(leg)
            speak("New route found. Follow the beacon.")
        }
    }

    private func finishWalk() {
        let next = legIndex + 1
        guard next < legs.count else { arrive(); return }
        if case .bus(let b) = legs[next] {
            legIndex = next
            bus = b
            speak("Arriving at stop \(b.boardingStop.spokenName).")
            startScan(exit: false)
        } else {
            beginLeg(next)
        }
    }

    /// Start calibration: the phone is held pointing forward (SPEC Phase 2 step 1).
    func calibrate() {
        needsCalibration = false
        guard head.isConnected else { speak("AirPods head tracking isn't connected. I'll use your walking direction."); return }
        guard let h = phoneHeading else {
            speak("The compass isn't ready yet. Start walking, I'll use your walking direction.")
            return
        }
        // Calibrate even with a poor compass: without it the AirPods aren't used at all (turning the
        // head changes nothing). Walking straight outside corrects the offset (align(toCourse:)).
        head.calibrate(phoneHeading: h)
        if phoneHeadingAccuracy < 0 || phoneHeadingAccuracy > 25 {
            // Indoors, near metal or with the phone held upright the compass can be off by 90° or more.
            speak("Direction set, but the compass is unreliable here, so it may be off. It corrects itself once you walk outside.")
        } else {
            speak("Direction set. Follow the beacon.")
        }
    }

    func skipCalibration() { needsCalibration = false }

    // MARK: - Phase 3: stop marker and waiting spot

    private func startScan(exit: Bool) {
        phase = .scanning(exit: exit)
        scanStarted = now
        lastNoMarkerHint = nil
        lastUnlockHint = nil
        spot = nil
        lastSpotSeen = nil
        spotGuidance = nil
        checkingBay = false
        if !exit { targetBayId = nil; spotBayId = nil }
        pipeline.requestedLine = nil
        // Most stops have no markers yet: check the backend first, so the rider isn't asked to
        // scan for something that isn't there.
        let place = exit ? bus?.alightingStop : bus?.boardingStop
        Task {
            let (ctx, hasMarkers) = await markerContext(near: place)
            guard phase == .scanning(exit: exit) else { return }
            if !exit, let ctx { stopContext = ctx }
            // Markers count at the stop the trip expects, not whatever GPS picks (or none indoors).
            pipeline.location.pin(hasMarkers ? ctx?.stop : nil)
            guard hasMarkers else { noScan(exit: exit, reason: "This stop has no markers"); return }
            if UIApplication.shared.applicationState != .background {   // .inactive = screen on, e.g. an alert
                beginCameraScan()
            } else {
                askToUnlock()
            }
        }
    }

    /// The backend stop at `place` (or the demo stop), preferring one with bay markers.
    private func markerContext(near place: Place?) async -> (StopContext?, Bool) {
        func hasBays(_ c: StopContext) -> Bool { c.markers.values.contains { $0.kind != .vehicle } }
        guard let place else { return (pipeline.stop, pipeline.stop.map(hasBays) ?? false) }
        let c = place.coordinate.clCoordinate
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        let stops = await pipeline.repository.stops(near: c, radius: 80)
            .filter { $0.location.distance(from: here) <= 80 }
            .sorted { $0.location.distance(from: here) < $1.location.distance(from: here) }
        var nearest: StopContext?
        for s in stops.prefix(5) {
            let ctx = await pipeline.repository.context(for: s)
            if hasBays(ctx) { return (ctx, true) }
            if nearest == nil { nearest = ctx }
        }
        // The planned stop has no markers: with the demo switch on, the demo stop's markers stand in
        // (only then: a real stop with markers always wins, so the switch can't hijack a real trip).
        if pipeline.location.demoOverride, let demo = DemoBundle.shared?.stop {
            let ctx = await pipeline.repository.context(for: demo)
            return (ctx, hasBays(ctx))
        }
        return (nearest, false)
    }

    /// No marker scan possible (none at this stop, or none found): carry on without the waiting spot.
    private func noScan(exit: Bool, reason: String) {
        log.info("no scan: \(reason, privacy: .public)")
        if exit {
            exitScanDone()
            return
        }
        phase = .waiting
        setCamera(false)
        spotGuidance = nil
        Task {
            await say("\(reason), so I can't guide you to the exact waiting spot. Wait at the stop for \(busName.lowercased()). I'll ask you before it comes.")
            guard phase == .waiting else { return }
            await setupDeparture()
        }
    }

    private func askToUnlock() {
        lastUnlockHint = now
        speak("Unlock your phone to scan the stop marker.")
        let c = UNMutableNotificationContent()
        c.title = "Scan the stop marker"
        c.body = "Open Lotse, hold your phone up and turn slowly."
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "scan", content: c, trigger: nil))
    }

    private func beginCameraScan() {
        guard !cameraOn else { return }
        setCamera(true)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["scan"])
        if case .scanning(let exit) = phase {
            speak(exit ? "When you're off the bus, hold your phone up and turn slowly to find the stop marker."
                       : "You're at \(stopName). Take out your phone, hold it up and turn slowly.")
        }
    }

    private func setCamera(_ on: Bool) {
        guard on != cameraOn else { return }
        cameraOn = on
        if on { pipeline.camera.start() } else { pipeline.camera.stop() }
        UIApplication.shared.isIdleTimerDisabled = on
    }

    /// App came to the front (e.g. the user unlocked the phone to scan).
    func becameActive() {
        // iOS only allows starting a Live Activity in the foreground; a Siri start in the background retries here.
        if isRouteActive { updateLiveActivity() }
        if needsCamera { beginCameraScan() }
    }

    func resignedActive() {
        // iOS stops the camera in the background; start it again (and speak) on return.
        if cameraOn { setCamera(false) }
    }

    private func scanTick() {
        guard cameraOn else {
            if let t = lastUnlockHint, now.timeIntervalSince(t) >= 60 { askToUnlock() }
            return
        }
        // A soft tick every ~2 s while nothing is found, so the user knows it's working.
        if now.timeIntervalSince(lastTick) >= 2 { lastTick = now; audio.play(.tick) }
        let since = lastNoMarkerHint ?? scanStarted
        if now.timeIntervalSince(since) >= 20, !audio.isSpeaking {
            lastNoMarkerHint = now
            speak("No stop marker found. Turn slowly.")
        }
        if case .scanning(exit: true) = phase, now.timeIntervalSince(scanStarted) >= 60 {
            speak("No stop marker found. Starting the walk anyway.")
            exitScanDone()
        } else if case .scanning(exit: false) = phase, now.timeIntervalSince(scanStarted) >= 120, !checkingBay {
            noScan(exit: false, reason: "I couldn't find a stop marker")
        }
    }

    private func handle(_ e: MarkerEvent) {
        guard case .found(let lock) = e else { return }
        guard case .scanning(let exit) = phase, lock.marker.kind != .vehicle, !checkingBay else { return }
        checkingBay = true
        Task {
            await markerFound(lock, exit: exit)
            checkingBay = false
        }
    }

    private func markerFound(_ lock: LockedMarker, exit: Bool) async {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        audio.play(.found)
        stopContext = pipeline.stop
        let name = pipeline.stop.map { Self.spoken($0.stop.name) } ?? stopName

        if exit {
            let label = lock.bay?.label ?? ""
            await say("You're at \(name)\(label.isEmpty ? "" : ", bay \(label)").")
            guard case .scanning = phase else { return }
            exitScanDone()
            return
        }
        guard let bay = lock.bay else {
            speak("This marker is at the stop entrance. Keep turning slowly to find your bay.")
            return
        }
        if targetBayId == nil { await resolveTargetBay() }
        guard case .scanning = phase else { return }

        if let target = targetBayId, target != bay.id {
            await say("This is the stop for the other direction. Your stop is across the street.")
            guard case .scanning = phase else { return }
            if let targetBay = stopContext?.bays[target] { redirect(to: targetBay) }
            return
        }
        spotBayId = bay.id
        phase = .toSpot
        lastTick = now
        let line = targetBayId == nil ? "You're at \(name)." :
            "\(busName)\(bus?.direction.map { " towards \(Self.spoken($0))" } ?? "") stops here."
        if let s = WaitingSpot.spotInCamera(lock.detection, marker: lock.marker) {
            let g = WaitingSpot.guidance(s, lateralSign: lateralSign)
            spot = s
            lastSpotSeen = now
            lastSpotSpoken = (now, spotText(g))
            await say("\(line) The waiting spot is \(spotText(g)).")
        } else {
            await say(line)
        }
    }

    /// Which bay the planned bus leaves from: the timetable (line + direction + time) first, then
    /// the platform letter from Transitous, then the only bay that serves the line.
    private func resolveTargetBay() async {
        guard let b = bus, let ctx = pipeline.stop else { return }
        let tt = await pipeline.repository.timetable(for: ctx.stop)
        timetable = tt
        let planned = b.estimate?.expectedDeparture ?? now
        if let line = b.line, let tt {
            let deps = tt.departures(after: now.addingTimeInterval(-30 * 60), limit: 5000).filter { $0.line == line }
            let sameWay = deps.filter { Self.sameDirection($0.headsign, b.direction) }
            let pool = sameWay.isEmpty && Set(deps.map(\.bayId)).count == 1 ? deps : sameWay
            if let d = pool.min(by: { abs($0.time.timeIntervalSince(planned)) < abs($1.time.timeIntervalSince(planned)) }) {
                targetBayId = d.bayId
            }
        }
        if targetBayId == nil, let platform = b.boardingPlatform, !platform.isEmpty {
            targetBayId = ctx.bays.values.first { $0.label == platform }?.id
        }
        if targetBayId == nil, let line = b.line {
            let serving = ctx.bays.values.filter { $0.lines.contains(line) }
            if serving.count == 1 { targetBayId = serving[0].id }
        }
        log.info("target bay: \(self.targetBayId ?? "unknown", privacy: .public)")
    }

    static func sameDirection(_ headsign: String, _ direction: String?) -> Bool {
        guard let direction else { return false }
        let a = spoken(headsign).lowercased(), b = spoken(direction).lowercased()
        return a.contains(b) || b.contains(a)
    }

    /// Wrong side of the street: a short walk to the right bay, then scan again.
    private func redirect(to bay: Bay) {
        setCamera(false)
        guard let loc = location else { startScan(exit: false); return }
        let index = legIndex
        Task {
            let to = Place(name: "\(stopName)\(bay.label.isEmpty ? "" : ", bay \(bay.label)")", address: nil,
                           coordinate: Coordinate(latitude: bay.lat, longitude: bay.lon))
            let leg = await navigation.walkingLegOrStraightLine(
                from: Place(name: "Current location", address: nil, coordinate: Coordinate(loc.coordinate)), to: to)
            guard isRouteActive, legIndex == index else { return }
            legs.insert(.walk(leg: leg), at: index)
            startWalk(leg)
            speak("Put your phone away and follow the beacon to the other side.")
        }
    }

    private func spotTick() {
        if let frame = pipeline.lastFrame, frame != lastFrame {
            lastFrame = frame
            if let est = WaitingSpot.estimate(frame, bayId: spotBayId) {
                // Smooth, so a new marker coming into view doesn't make the guidance jump.
                spot = spot.map { $0 + 0.3 * (est - $0) } ?? est
                lastSpotSeen = now
                spotLostSaid = false
            }
        }
        guard let spot, let seen = lastSpotSeen, now.timeIntervalSince(seen) < 1.5 else {
            spotGuidance = nil
            if now.timeIntervalSince(lastTick) >= 2 { lastTick = now; audio.play(.tick) }
            if let seen = lastSpotSeen, now.timeIntervalSince(seen) >= 3, !spotLostSaid {
                spotLostSaid = true
                speak("Marker lost. Hold your phone up and turn slowly.")
            }
            return
        }
        let g = WaitingSpot.guidance(spot, lateralSign: lateralSign)
        spotGuidance = g
        if g.distance <= WaitingSpot.arrivalDistance { atSpot(); return }
        // Beeps speed up as the user gets closer and come from the spot's direction.
        if now.timeIntervalSince(lastSpotBeep) >= BeaconDirection.beaconInterval(distance: g.distance) {
            lastSpotBeep = now
            audio.spotBeep(angle: g.bearingDeg)
        }
        let text = spotText(g)
        if !audio.isSpeaking, let last = lastSpotSpoken,
           (text != last.text && now.timeIntervalSince(last.at) >= 3) || now.timeIntervalSince(last.at) >= 8 {
            lastSpotSpoken = (now, text)
            speak(text.prefix(1).uppercased() + text.dropFirst() + ".")
        } else if lastSpotSpoken == nil {
            lastSpotSpoken = (now, text)
        }
    }

    /// "2 o'clock, 4 metres"
    private func spotText(_ g: Guidance) -> String {
        let m = max(1, Int(g.distance.rounded()))
        return "\(g.clockHour) o'clock, \(m) metre\(m == 1 ? "" : "s")"
    }

    private func atSpot() {
        phase = .waiting
        setCamera(false)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        spotGuidance = nil
        Task {
            await say("You're at the waiting spot. \(busName) stops right here. You can put your phone away.")
            guard phase == .waiting else { return }
            await setupDeparture()
        }
    }

    // MARK: - Phase 4: waiting and boarding

    private func setupDeparture() async {
        if timetable == nil, let ctx = stopContext ?? pipeline.stop {
            timetable = await pipeline.repository.timetable(for: ctx.stop)
        }
        departure = nextDeparture(after: now.addingTimeInterval(-60)) ?? bus?.estimate?.expectedDeparture
            ?? now.addingTimeInterval(5 * 60)
        askedBoard = false
        boardRetry = nil
        nextComeCheck = nil
        if let d = departure {
            log.info("waiting for \(self.busName, privacy: .public) at \(d)")
            if d.timeIntervalSince(now) > Self.boardAskLead + 60 {
                speak("\(busName) is due at \(d.formatted(date: .omitted, time: .shortened)). I'll ask you a few minutes before.")
            }
        }
    }

    /// Next scheduled departure of our line and direction from our bay (scheduled times only).
    private func nextDeparture(after date: Date) -> Date? {
        guard let b = bus, let line = b.line, let tt = timetable else { return nil }
        let deps = tt.departures(after: date, bay: spotBayId ?? targetBayId, limit: 500).filter { $0.line == line }
        let sameWay = deps.filter { Self.sameDirection($0.headsign, b.direction) }
        return (sameWay.isEmpty ? deps : sameWay).first?.time
    }

    private func waitTick() {
        guard let dep = departure else { return }
        if !askedBoard, now >= dep.addingTimeInterval(-Self.boardAskLead), boardRetry.map({ now >= $0 }) ?? true {
            askedBoard = true
            Task { await askBoard() }
        }
        // Bus didn't come or didn't stop: ask 5 minutes after the scheduled time, if the user hasn't moved.
        let check = nextComeCheck ?? dep.addingTimeInterval(5 * 60)
        if now >= check, prompter.pending == nil, distanceToStop.map({ $0 < 100 }) ?? true {
            nextComeCheck = .distantFuture
            Task { await askHasCome() }
        }
    }

    private var distanceToStop: Double? {
        guard let loc = location, let b = bus else { return nil }
        return Coordinate(loc.coordinate).distance(to: b.boardingStop.coordinate)
    }

    private func askBoard() async {
        guard let dep = departure else { return }
        let mins = Int((dep.timeIntervalSince(now) / 60).rounded(.up))
        let due = mins <= 0 ? "due now" : "due in \(mins) minute\(mins == 1 ? "" : "s")"
        let answer = await prompter.ask("\(busName) is \(due). Do you want to board it?")
        guard phase == .waiting else { return }
        switch answer?.id {
        case "yes":
            await sendPickup()
        case "no":
            await say("OK. I'll ask you again for the next \(busName.lowercased()).")
            await moveToNextDeparture()
        default:
            // No answer twice: ask once more a minute later, never send without a yes.
            if dep.timeIntervalSince(now) > 60 { askedBoard = false; boardRetry = now.addingTimeInterval(60) }
        }
    }

    private func sendPickup() async {
        guard let ctx = stopContext ?? pipeline.stop, let line = bus?.line, let dep = departure else {
            await say("I can't message the driver of this bus. Please signal the driver when the bus arrives.")
            return
        }
        do {
            pickupRequestId = try await driver.pickup(stopId: ctx.stop.id, bayId: spotBayId ?? targetBayId,
                                                      line: line, departure: dep)
            await say("Done. The driver of \(busName.lowercased()) knows you're waiting here.")
        } catch {
            log.error("pickup failed: \(error.localizedDescription, privacy: .public)")
            await say("I couldn't reach the driver. Please signal the driver when the bus arrives.")
        }
    }

    private func moveToNextDeparture() async {
        if let id = pickupRequestId {
            pickupRequestId = nil
            Task { try? await driver.setStatus(request: id, "cancelled") }
        }
        let after = (departure ?? now).addingTimeInterval(60)
        departure = nextDeparture(after: after)
        askedBoard = false
        boardRetry = nil
        nextComeCheck = nil
        if let d = departure {
            await say("The next \(busName.lowercased()) is due at \(d.formatted(date: .omitted, time: .shortened)). I'll ask you before it comes.")
        } else {
            await say("I couldn't find another departure in the timetable.")
        }
    }

    private func askHasCome() async {
        let came = PromptOption(id: "came", label: "It came", gesture: .nod, words: ["yes", "it came", "came"])
        let notYet = PromptOption(id: "notYet", label: "Not yet", gesture: .shake, words: ["not yet", "no", "nope"])
        let didntStop = PromptOption(id: "didntStop", label: "It didn't stop", gesture: nil,
                                     words: ["didn't stop", "did not stop", "drove past", "didn't"])
        let onIt = PromptOption(id: "onIt", label: "I'm on it", gesture: nil, words: ["on it", "on the bus", "i'm on"])
        let answer = await prompter.ask("Has \(busName.lowercased()) come yet?", options: [notYet, came, didntStop, onIt])
        guard phase == .waiting else { return }
        switch answer?.id {
        case "notYet":
            await say("OK. I'll ask again in 5 minutes.")
            nextComeCheck = now.addingTimeInterval(5 * 60)
        case "onIt":
            await confirmBoarded()
        case "didntStop":
            await fileComplaint()
        case "came":
            let on = await prompter.ask("Are you on \(busName.lowercased())? Nod if you are. Shake if it didn't stop.")
            guard phase == .waiting else { return }
            if on?.id == "yes" { await confirmBoarded() }
            else if on?.id == "no" { await fileComplaint() }
            else { nextComeCheck = now.addingTimeInterval(2 * 60) }
        default:
            nextComeCheck = now.addingTimeInterval(5 * 60)
        }
    }

    /// Only ever on an explicit "it didn't stop".
    private func fileComplaint() async {
        guard let line = bus?.line, let dep = departure else { return }
        do {
            try await driver.complaint(line: line, stopName: stopName, scheduled: dep)
            await say("I've filed a complaint that \(busName.lowercased()) didn't stop.")
        } catch {
            await say("I couldn't send the complaint.")
        }
        await moveToNextDeparture()
    }

    private func waitLocation(_ loc: CLLocation) {
        // Boarding: > ~15 km/h for 20 s after the scheduled departure, away from the stop.
        guard let dep = departure, now >= dep, loc.speed > 15 / 3.6, (distanceToStop ?? 0) > 50 else {
            fastSince = nil
            return
        }
        let since = fastSince ?? now
        fastSince = since
        guard now.timeIntervalSince(since) >= 20, now >= boardingAskAfter, prompter.pending == nil else { return }
        boardingAskAfter = now.addingTimeInterval(2 * 60)
        Task {
            let answer = await prompter.ask("Are you on \(busName.lowercased())?")
            guard phase == .waiting else { return }
            if answer?.id == "yes" { await confirmBoarded() }
        }
    }

    // MARK: - Phase 5: riding

    private func confirmBoarded() async {
        guard let b = bus else { return }
        phase = .riding
        if let id = pickupRequestId { Task { try? await driver.setStatus(request: id, "boarded") } }
        rideStops = b.intermediateStops.map(\.stop) + [b.alightingStop]
        reachedStop = -1
        askedStopRequest = false
        nearExitSince = nil
        if b.source == .transitous {
            await say("You're on \(busName.lowercased()), \(rideStops.count) stop\(rideStops.count == 1 ? "" : "s") to go.")
            if rideStops.count == 1, phase == .riding { await askStopRequest() }
        } else {
            await say("You're on the bus. I'll tell you before \(b.alightingStop.spokenName).")
        }
    }

    private func rideLocation(_ loc: CLLocation) {
        guard !rideStops.isEmpty else { return }
        let p = Coordinate(loc.coordinate)
        let last = rideStops.count - 1
        if reachedStop < last,
           let i = ((reachedStop + 1)...last).last(where: { rideStops[$0].coordinate.distance(to: p) < 60 }),
           i < last {
            reachedStop = i
            let left = last - i
            if left == 1, !askedStopRequest { Task { await askStopRequest() } }
            else if left > 1 { speak("\(rideStops[i].spokenName). \(left) stops to go.") }
        }
        let toExit = rideStops[last].coordinate.distance(to: p)
        // Fallback when GPS missed the stop before (or MapKit gave no stop list).
        if !askedStopRequest, toExit < 300 { Task { await askStopRequest() } }
        if toExit < 50, loc.speed >= 0, loc.speed < 1.5 {
            let since = nearExitSince ?? now
            nearExitSince = since
            if now.timeIntervalSince(since) >= 5 { arrivedAtExit() }
        } else {
            nearExitSince = nil
        }
    }

    /// "Next stop is Hanuschplatz, that's yours. Request the stop?" Never requested without a yes.
    private func askStopRequest() async {
        guard phase == .riding, !askedStopRequest, let b = bus else { return }
        askedStopRequest = true
        let exit = b.alightingStop.spokenName
        let answer = await prompter.ask("Next stop is \(exit), that's yours. Request the stop?")
        guard phase == .riding else { return }
        switch answer?.id {
        case "yes":
            guard let line = b.line else {
                await say("I can't message the driver of this bus. Please press the stop button.")
                return
            }
            do {
                try await driver.stopRequest(line: line, stopName: exit)
                await say("Stop requested. The driver knows you're getting off at \(exit).")
            } catch {
                await say("I couldn't reach the driver. Please press the stop button.")
            }
        case "no":
            await say("OK. Press the stop button yourself when you're ready.")
        default:
            await say("No answer, so I didn't request the stop.")
        }
    }

    private func arrivedAtExit() {
        guard phase == .riding else { return }
        speak("This is \(bus?.alightingStop.spokenName ?? "your stop"). Get off here.")
        startScan(exit: true)
    }

    // MARK: - Phase 6: exit scan, then the last walk

    private func exitScanDone() {
        setCamera(false)
        let next = legIndex + 1
        guard next < legs.count else { arrive(); return }
        if case .walk(let w) = legs[next] {
            legIndex = next
            let m = max(1, Int((w.expectedTravelTimeSeconds / 60).rounded()))
            speak("Now walk \(m) minute\(m == 1 ? "" : "s") to \(w.to.spokenName). Put your phone away and follow the beacon.")
            startWalk(w)
        } else {
            beginLeg(next)
        }
    }

    // MARK: - Timer and location

    private func tick() {
        switch phase {
        case .walking: walkTick()
        case .scanning: scanTick()
        case .toSpot: spotTick()
        case .waiting: waitTick()
        default: break
        }
    }

    private func handleLocation(_ loc: CLLocation) {
        log.debug("location \(loc.coordinate.latitude), \(loc.coordinate.longitude) ±\(loc.horizontalAccuracy) m, \(loc.speed) m/s")
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 50 else { return }
        location = loc
        switch phase {
        case .walking: walkLocation(loc)
        case .waiting: waitLocation(loc)
        case .riding: rideLocation(loc)
        default: break
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard !simulating else { return }
            locations.forEach(handleLocation)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        MainActor.assumeIsolated {
            phoneHeading = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
            phoneHeadingAccuracy = h.headingAccuracy
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("location: \(error.localizedDescription)")
    }

    // MARK: - Debug (stage demo)

    /// Jumps the clock to the next bus event: the board prompt, then "has the bus come yet?".
    func fastForward() {
        guard phase == .waiting, let dep = departure else { return }
        let target = askedBoard ? max(now, dep.addingTimeInterval(5 * 60)) : dep.addingTimeInterval(-Self.boardAskLead)
        timeShift += max(0, target.timeIntervalSince(now)) + 0.5
        log.info("fast-forward, clock now \(self.now)")
    }

    /// Simulated ride: pretends to board and passes the stops every few seconds.
    func simulateRide() {
        guard phase == .waiting || phase == .riding, bus != nil else { return }
        simulating = true
        Task {
            if phase == .waiting { await confirmBoarded() }
            for stop in rideStops {
                guard simulating, phase == .riding else { break }
                handleLocation(fake(stop.coordinate, speed: 8))
                try? await Task.sleep(for: .seconds(8))
            }
            for _ in 0..<8 where simulating && phase == .riding {
                handleLocation(fake(rideStops.last!.coordinate, speed: 0))
                try? await Task.sleep(for: .seconds(1))
            }
            simulating = false
        }
    }

    /// Ends the current walk as if its target was reached: indoors GPS never arrives, so this
    /// lets the hall demo go straight to the marker scan.
    func skipWalk() {
        guard phase == .walking else { return }
        log.info("debug: walk skipped")
        finishWalk()
    }

    /// Skips the current scan (debug, or when no markers are up at a stop).
    func skipScan() {
        switch phase {
        case .scanning(exit: true): exitScanDone()
        case .scanning(exit: false), .toSpot: atSpot()
        default: break
        }
    }

    private func fake(_ c: Coordinate, speed: Double) -> CLLocation {
        CLLocation(coordinate: c.clCoordinate, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                   course: -1, speed: speed, timestamp: .now)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
