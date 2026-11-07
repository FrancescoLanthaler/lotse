import AVFoundation
import Observation
import os

/// App-wide entry point for Siri intents and the UI. The camera and safety filter live in
/// `MarkerPipeline` (one camera session for the whole app).
@Observable
@MainActor
final class Scanner {
    static let shared = Scanner()

    @ObservationIgnored let pipeline = MarkerPipeline()
    var siriMessage: String?
    private(set) var isNavigating = false
    private(set) var destinationLabel: String?
    @ObservationIgnored private let navigationGuide = NavigationGuide()
    @ObservationIgnored private let navigationService = NavigationService()

    var detections: [TagDetection] { pipeline.lastFrame?.detections.map(\.detection) ?? [] }
    /// When the latest camera frame arrived (MarkerBeacon drops stale frames).
    private(set) var lastFrame = Date.distantPast
    var status: String { pipeline.cameraError ?? "Scanning for tag25h9" }

    func frameUpdated(_ frame: FrameResult?) {
        lastFrame = Date()
        guard isNavigating, let frame else { return }
        // Only IDs that passed the safety filter may be spoken.
        let safe = frame.detections.filter { $0.status == .locked }.map(\.detection)
        navigationGuide.announce(for: safe, frameSize: frame.frame.size,
                                 markerSizeCm: (frame.lock?.marker.sizeM ?? 0.163) * 100)
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
