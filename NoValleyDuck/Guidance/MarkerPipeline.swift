import AVFoundation
import Foundation
import Observation
import UIKit
import os

private let log = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "markers")

/// The marker side of the app, in one object: camera → AprilTag → safety filter → distance and
/// clock direction → rider state, with the stop (and so the meaning of each ID) from GPS.
///
/// Consumers (soundscape, speech, UI) use it on the main actor:
///  - observe `state`, `lock`, `stop` (Observation), and/or
///  - `for await e in pipeline.events() { … }` for found / arrived / lost / stopChanged /
///    reducedRange. Each call to `events()` returns an independent stream.
@Observable
@MainActor
final class MarkerPipeline {
    private(set) var state: MarkerState = .noStop
    /// The locked marker with smoothed guidance, updated every processed frame it is visible.
    private(set) var lock: LockedMarker?
    private(set) var reducedRange = false
    private(set) var lastFrame: FrameResult?
    private(set) var cameraError: String?
    /// Hall-test CSV currently being written, and how many locks happened during it
    /// (false-positive test: must stay 0 with no demo markers in view).
    private(set) var recordingURL: URL?
    private(set) var recordedLocks = 0

    let location: LocationGate
    var stop: StopContext? { location.context }

    /// Prefer this line's bus-door marker over everything else (set when the rider requests a line).
    var requestedLine: String? { didSet { updatePreferred() } }

    /// Safety threshold for the decision margin (spec: start at 40, tune in the hall).
    var minMargin: Float = 40 {
        didSet { let m = minMargin; let p = processor; camera.onFrameQueue { p.tracker.minMargin = m } }
    }
    /// Flip if left/right comes out reversed in the direction test.
    var lateralFlipped = UserDefaults.standard.bool(forKey: "lateralFlipped.v2") {
        didSet {
            UserDefaults.standard.set(lateralFlipped, forKey: "lateralFlipped.v2")
            let s = lateralSign; let p = processor
            camera.onFrameQueue { p.engine.lateralSign = s }
        }
    }

    private var lateralSign: Double {
        lateralFlipped ? -GuidanceEngine.portraitLateralSign : GuidanceEngine.portraitLateralSign
    }

    @ObservationIgnored let camera = CameraService()
    @ObservationIgnored private let processor = FrameProcessor()
    @ObservationIgnored private let recorder = HallTestRecorder()
    @ObservationIgnored let repository: StopRepository
    @ObservationIgnored private var machine = MarkerStateMachine()
    @ObservationIgnored private var catalog = MarkerCatalog.empty
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<MarkerEvent>.Continuation] = [:]
    @ObservationIgnored private var started = false

    init(repository: StopRepository = StopRepository()) {
        self.repository = repository
        location = LocationGate(repository: repository)
    }

    func events() -> AsyncStream<MarkerEvent> {
        AsyncStream { cont in
            let id = UUID()
            subscribers[id] = cont
            cont.onTermination = { [weak self] _ in Task { @MainActor [weak self] in self?.subscribers[id] = nil } }
        }
    }

    func start() async {
        guard !started else { return }
        started = true

        let s = lateralSign; let p = processor
        camera.onFrameQueue { p.engine.lateralSign = s }

        location.onChange = { [weak self] ctx in self?.stopChanged(ctx) }
        location.start()
        catalog.vehicles = await repository.vehicleMarkers()
        pushCatalog()

        startThermalWatch()

        guard await AVCaptureDevice.requestAccess(for: .video) else {
            cameraError = "Camera access denied. Enable it in Settings."
            log.error("camera access denied")
            return
        }
        do { try camera.configure() } catch {
            cameraError = "Camera setup failed: \(error.localizedDescription)"
            log.error("camera setup failed: \(error.localizedDescription)")
            return
        }
        let processor = processor, recorder = recorder
        camera.onFrame = { [weak self] dets, frame in
            let result = processor.process(dets, frame: frame)
            recorder.write(result, stop: processor.catalog.stop?.stop.name ?? "")
            for d in dets {
                log.debug("tag \(d.id) ham=\(d.hamming) margin=\(d.margin, format: .fixed(precision: 1)) side=\(d.sidePixels, format: .fixed(precision: 0))px")
            }
            Task { @MainActor [weak self] in self?.handle(result) }
        }
        camera.start()
        // Spec: keep scanning with the screen curtain on / phone in a pocket-free hold.
        UIApplication.shared.isIdleTimerDisabled = true
        log.info("marker pipeline started")
    }

    // MARK: - Hall test recording

    func setRecording(_ on: Bool) {
        let recorder = recorder
        if on {
            let url = HallTestRecorder.newURL()
            camera.onFrameQueue { recorder.begin(url) }
            recordingURL = url
            recordedLocks = 0
        } else {
            camera.onFrameQueue { recorder.end() }
            recordingURL = nil
        }
    }

    /// Finished and running recordings, newest first.
    var recordings: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: URL.documentsDirectory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("hall-test-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - Frame results (main actor)

    private func handle(_ result: FrameResult) {
        lastFrame = result
        if result.lock != nil || result.lockedTag == nil { lock = result.lock }
        let events = machine.update(hasStop: stop != nil, lockedTag: result.lockedTag, visible: result.lock)
        state = machine.state
        events.forEach(emit)
    }

    private func stopChanged(_ ctx: StopContext?) {
        catalog.stop = ctx
        pushCatalog()
        updatePreferred()
        lock = nil
        machine.reset(hasStop: ctx != nil).forEach(emit)
        state = machine.state
        emit(.stopChanged(ctx?.stop))
        log.info("stop: \(ctx?.stop.name ?? "none") (\(ctx?.markers.count ?? 0) markers)")
    }

    private func pushCatalog() {
        let c = catalog, p = processor
        camera.onFrameQueue { p.setCatalog(c) }
    }

    private func updatePreferred() {
        let tag = requestedLine.flatMap { line in catalog.vehicles.values.first { $0.vehicleLine == line }?.tagId }
        let p = processor
        camera.onFrameQueue { p.preferredTag = tag }
    }

    private func emit(_ e: MarkerEvent) {
        if case .found = e, recordingURL != nil { recordedLocks += 1 }
        log.info("event: \(String(describing: e), privacy: .public)")
        subscribers.values.forEach { $0.yield(e) }
    }

    // MARK: - Heat (spec: at .serious go to 5 fps + decimate 2, announce "reduced range")

    private func startThermalWatch() {
        applyThermal(ProcessInfo.processInfo.thermalState)
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
                self?.applyThermal(ProcessInfo.processInfo.thermalState)
            }
        }
    }

    private func applyThermal(_ s: ProcessInfo.ThermalState) {
        let hot = s == .serious || s == .critical
        guard hot != reducedRange else { return }
        reducedRange = hot
        camera.setThrottled(hot)
        emit(.reducedRange(hot))
    }
}
