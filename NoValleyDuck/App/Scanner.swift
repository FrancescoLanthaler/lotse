import AVFoundation
import Observation
import os

private let tagLog = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "tags")

/// Detection-only milestone: runs the camera, logs every tag25h9 detection to the console
/// and publishes the latest frame's detections for the debug preview.
@Observable
@MainActor
final class Scanner {
    static let shared = Scanner()

    @ObservationIgnored let camera = CameraService()
    private(set) var detections: [TagDetection] = []
    private(set) var frameSize: CGSize = .zero
    private(set) var status = "Starting camera…"
    var siriMessage: String?
    private(set) var isNavigating = false
    private(set) var destinationLabel: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let navigationGuide = NavigationGuide()
    @ObservationIgnored private let navigationService = NavigationService()

    func start() async {
        guard !started else { return }
        started = true
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = "Camera access denied. Enable it in Settings."
            tagLog.error("Camera access denied")
            return
        }
        do {
            try camera.configure()
        } catch {
            status = "Camera setup failed: \(error.localizedDescription)"
            tagLog.error("Camera setup failed: \(error.localizedDescription)")
            return
        }
        camera.onFrame = { [weak self] dets, size in
            for d in dets {
                let pose = d.unitTranslation.map {
                    String(format: "t/size=(%.2f, %.2f, %.2f) err=%.2e", $0.x, $0.y, $0.z, d.poseError ?? 0)
                } ?? "no pose"
                tagLog.info("""
                tag id=\(d.id) hamming=\(d.hamming) margin=\(d.margin, format: .fixed(precision: 1)) \
                side=\(d.sidePixels, format: .fixed(precision: 0))px \
                center=(\(Int(d.center.x)),\(Int(d.center.y))) of \(Int(size.width))x\(Int(size.height)) \(pose)
                """)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.detections = dets
                self.frameSize = size
                if self.isNavigating {
                    let markerSizeCm = UserDefaults.standard.double(forKey: "markerSizeCm")
                    self.navigationGuide.announce(
                        for: dets,
                        frameSize: size,
                        markerSizeCm: markerSizeCm == 0 ? 16.3 : markerSizeCm
                    )
                }
            }
        }
        camera.start()
        status = "Scanning for tag25h9"
        tagLog.info("Camera started, scanning for tag25h9")
    }

    func startNavigating(destination: String) {
        guard !isNavigating else { return }
        isNavigating = true
        destinationLabel = destination.isEmpty ? nil : destination
        navigationGuide.start(destination: destinationLabel)
        if let destinationLabel {
            Task { await planTrip(to: destinationLabel) }
        }
    }

    func stopNavigating() {
        guard isNavigating else { return }
        isNavigating = false
        destinationLabel = nil
        navigationGuide.stop()
    }

    private func planTrip(to destination: String) async {
        do {
            let plan = try await navigationService.plan(to: destination)
            guard isNavigating else { return }
            navigationGuide.say("Route to \(plan.destination.spokenName) found. \(plan.spokenSummary)")
        } catch {
            guard isNavigating else { return }
            navigationGuide.say(error.localizedDescription)
        }
    }
}
