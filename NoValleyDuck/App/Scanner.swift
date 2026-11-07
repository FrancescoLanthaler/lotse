import AVFoundation
import Observation
import os

private let tagLog = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "tags")

/// Detection-only milestone: runs the camera, logs every tag25h9 detection to the console
/// and publishes the latest frame's detections for the debug preview.
@Observable
@MainActor
final class Scanner {
    @ObservationIgnored let camera = CameraService()
    private(set) var detections: [TagDetection] = []
    private(set) var frameSize: CGSize = .zero
    private(set) var lastFrame = Date.distantPast
    private(set) var status = "Starting camera…"
    @ObservationIgnored private var started = false

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
            let capturedAt = Date()
            Task { @MainActor [weak self] in
                self?.detections = dets
                self?.frameSize = size
                self?.lastFrame = capturedAt
            }
        }
        camera.start()
        status = "Scanning for tag25h9"
        tagLog.info("Camera started, scanning for tag25h9")
    }
}
