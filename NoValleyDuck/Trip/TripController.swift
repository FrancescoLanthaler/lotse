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

    enum Phase: Equatable {
        case idle, planning
        case walking
        case scanning(exit: Bool)     // Phase 3 (find the bay) or Phase 6 (confirm the exit stop)
        case toSpot                   // Phase 3 step 4: guidance to the waiting spot
        case waiting                  // Phase 4
        case riding                   // Phase 5
        case arrived
    }

    private(set) var phase: Phase = .idle
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
    @ObservationIgnored private var recentCourses: [Double] = []
    @ObservationIgnored private var simulating = false

    // Legs (a copy of the plan's, so redirects and re-plans can replace them)
    @ObservationIgnored private var legs: [Leg] = []
    @ObservationIgnored private var legIndex = 0

    // Walking
    @ObservationIgnored private var checkpoints: [Checkpoint] = []
    @ObservationIgnored private var checkpointIndex = 0
    @ObservationIgnored private var announcedTurns: Set<Int> = []
    @ObservationIgnored private var offRouteSince: Date?
    @ObservationIgnored private var lastDistanceUpdate: (at: Date, remaining: Double)?
    @ObservationIgnored private var replanning = false
    @ObservationIgnored private var lastPing = Date.distantPast

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
    @ObservationIgnored private var reachedStop = -1
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
            await say("Microphone or speech recognition access is off. You can type the destination instead.")
            return
        }
        await say("Where to?")
        listeningForDestination = true
        let text = await voice.listen(timeout: 8, hints: Self.placeHints)
        listeningForDestination = false
        guard let text, !text.isEmpty else {
            await say("I didn't catch that. Tap Where to and try again.")
            if !isRouteActive { audio.stop() }
            return
        }
        start(destination: text)
    }

    // HACK: hand-picked Salzburg destinations so the English recogniser hears "Europark", not "Oilpark".
    static let placeHints = [
        "Europark", "Mirabellplatz", "Getreidegasse", "Hauptbahnhof", "Hanuschplatz", "Ferdinand-Hanusch-Platz",
        "Residenzplatz", "Mozartplatz", "Kapitelplatz", "Domplatz", "Festspielhaus", "Makartplatz", "Linzergasse",
        "Kajetanerplatz", "Rathaus", "Messe Salzburg", "Salzburgarena", "Red Bull Arena", "Flughafen Salzburg",
        "Hellbrunn", "Kleßheim", "Alpenstraße", "Lehen", "Itzling", "Gnigl", "Obergnigl", "Nonntal", "Mülln",
        "Maxglan", "Liefering", "Parsch", "Aigen", "Anif", "Grödig", "Wals", "Taxham", "Zentrum im Berg",
        "Unipark Nonntal", "Landeskrankenhaus", "Universität Salzburg", "Hofstallgasse", "Bürgerspitalgasse",
    ]

    func start(destination: String) {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return }
        guard !isRouteActive else { speak("A route is already running. Stop it first."); return }
        phase = .planning
        plan = nil
        beginSession()
        Task { await planRoute(to: destination) }
    }

    private func planRoute(to destination: String) async {
        speak("Looking for \(destination).")
        do {
            let plan = try await navigation.plan(to: destination)
            guard phase == .planning else { return }
            self.plan = plan
            legs = plan.legs
            await say("\(Self.readback(plan.destination)). Starting route.")
            await say(Self.summary(plan))
            if head.isConnected {
                needsCalibration = true
                speak("To set the direction, hold your phone flat, pointing forward, and double-tap the screen. Or just start walking.")
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
        // Idle right away, so a plan or prompt still in flight can't carry on.
        phase = .idle
        setCamera(false)
        prompter.cancel()
        voice.cancel()
        audio.stopSpeaking()
        Task {
            await say("Route stopped.")
            if phase == .idle { end() }       // unless a new route started meanwhile
        }
    }

    private func end() {
        phase = .idle
        timer?.invalidate()
        timer = nil
        setCamera(false)
        head.stop()
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        locationManager.allowsBackgroundLocationUpdates = false
        audio.stop()
        resetTripState()
    }

    private func resetTripState() {
        legs = []; legIndex = 0; bus = nil; stopContext = nil; timetable = nil
        targetBayId = nil; spotBayId = nil; departure = nil; askedBoard = false; boardRetry = nil
        pickupRequestId = nil; nextComeCheck = nil; fastSince = nil; rideStops = []; reachedStop = -1
        askedStopRequest = false; nearExitSince = nil; spot = nil; spotGuidance = nil
        needsCalibration = false; timeShift = 0; simulating = false
    }

    private func say(_ text: String) async {
        lastSpoken = text
        await audio.say(text)
    }

    private func speak(_ text: String) {
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
        log.info("walk to \(w.to.name, privacy: .public): \(self.checkpoints.count) checkpoints")
    }

    /// Head direction: AirPods (calibrated / GPS-aligned), else the walking course, else the phone compass.
    private var heading: Double? {
        if let h = head.heading { return h }
        if let loc = location, loc.speed > 0.7, loc.course >= 0 { return loc.course }
        return phoneHeading
    }

    private func walkTick() {
        guard checkpointIndex < checkpoints.count, let loc = location else { return }
        let bearing = Coordinate(loc.coordinate).bearing(to: checkpoints[checkpointIndex].coordinate)
        let angle = heading.map { (bearing - $0 + 540).truncatingRemainder(dividingBy: 360) - 180 } ?? 0
        let onTarget = heading != nil && abs(angle) < 20
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
        guard let h = phoneHeading else { speak("The compass isn't ready yet. Start walking, I'll use your walking direction."); return }
        head.calibrate(phoneHeading: h)
        speak("Direction set. Follow the beacon.")
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
        if UIApplication.shared.applicationState != .background {   // .inactive = screen on, e.g. an alert
            beginCameraScan()
        } else {
            askToUnlock()
        }
    }

    private func askToUnlock() {
        lastUnlockHint = now
        speak("Unlock your phone to scan the stop marker.")
        let c = UNMutableNotificationContent()
        c.title = "Scan the stop marker"
        c.body = "Open NoValleyDuck, hold your phone up and turn slowly."
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
            if d.timeIntervalSince(now) > 4 * 60 {
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
        if !askedBoard, now >= dep.addingTimeInterval(-3 * 60), boardRetry.map({ now >= $0 }) ?? true {
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
            if rideStops.count == 1 { await askStopRequest() }
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
        guard !askedStopRequest, let b = bus else { return }
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
        MainActor.assumeIsolated { phoneHeading = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("location: \(error.localizedDescription)")
    }

    // MARK: - Debug (stage demo)

    /// Jumps the clock to the next bus event: the board prompt, then "has the bus come yet?".
    func fastForward() {
        guard phase == .waiting, let dep = departure else { return }
        let target = askedBoard ? max(now, dep.addingTimeInterval(5 * 60)) : dep.addingTimeInterval(-3 * 60)
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
