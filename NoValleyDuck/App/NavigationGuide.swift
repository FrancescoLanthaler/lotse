import AVFoundation
import os

private let navLog = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "navigation")

/// Turns detections into spoken left/right/distance guidance for eyes-free navigation.
@MainActor
final class NavigationGuide {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastBucket: String?
    private var lastSpokenAt: Date = .distantPast
    private var lastSearchAnnouncedAt: Date = .distantPast

    func start(destination: String?) {
        activateAudioSession()
        lastBucket = nil
        lastSpokenAt = .distantPast
        lastSearchAnnouncedAt = .distantPast
        if let destination, !destination.isEmpty {
            speak("Finding a route to \(destination).")
        } else {
            speak("Navigation started.")
        }
    }

    func stop() {
        speak("Navigation stopped.")
        deactivateAudioSession()
    }

    /// Lets the trip planner (route summary, errors) share this guide's speech queue and audio session.
    func say(_ text: String) {
        speak(text)
    }

    func announce(for detections: [TagDetection], frameSize: CGSize, markerSizeCm: Double) {
        guard let best = bestDetection(in: detections) else {
            let now = Date()
            if now.timeIntervalSince(lastSearchAnnouncedAt) > 4 {
                lastSearchAnnouncedAt = now
                lastBucket = nil
                speak("Searching for a tag.")
            }
            return
        }

        let markerSize = markerSizeCm / 100
        let bucket: String
        if let translation = best.unitTranslation {
            let angle = atan2(translation.x, translation.z) * 180 / .pi
            let direction = directionLabel(forAngleDegrees: angle)
            if let distance = best.distance(markerSize: markerSize) {
                bucket = "\(direction)|\(distanceBand(metres: distance))"
            } else {
                bucket = direction
            }
        } else {
            let offset = (best.center.x - frameSize.width / 2) / max(frameSize.width / 2, 1)
            let direction = directionLabel(forNormalizedOffset: offset)
            bucket = direction
        }

        let now = Date()
        guard bucket != lastBucket || now.timeIntervalSince(lastSpokenAt) > 3 else { return }
        lastBucket = bucket
        lastSpokenAt = now
        speak(phrase(for: best, markerSize: markerSize))
    }

    private func bestDetection(in detections: [TagDetection]) -> TagDetection? {
        detections
            .filter { $0.hamming == 0 }
            .max { $0.margin < $1.margin }
    }

    private func directionLabel(forAngleDegrees angle: Double) -> String {
        switch angle {
        case ..<(-20): return "left"
        case -20..<(-5): return "slightly left"
        case -5...5: return "ahead"
        case 5..<20: return "slightly right"
        default: return "right"
        }
    }

    private func directionLabel(forNormalizedOffset offset: Double) -> String {
        switch offset {
        case ..<(-0.4): return "left"
        case -0.4..<(-0.1): return "slightly left"
        case -0.1...0.1: return "ahead"
        case 0.1..<0.4: return "slightly right"
        default: return "right"
        }
    }

    private func distanceBand(metres: Double) -> String {
        switch metres {
        case ..<1: return "very close"
        case 1..<3: return "close"
        case 3..<6: return "nearby"
        default: return "far"
        }
    }

    private func phrase(for detection: TagDetection, markerSize: Double) -> String {
        guard let translation = detection.unitTranslation else {
            let offset = detection.center.x
            navLog.info("nav guidance (no pose), center.x=\(offset)")
            return "Tag ahead, no distance available."
        }
        let angle = atan2(translation.x, translation.z) * 180 / .pi
        let direction = directionLabel(forAngleDegrees: angle)
        if let distance = detection.distance(markerSize: markerSize) {
            return "Tag \(direction), \(distanceBand(metres: distance))."
        }
        return "Tag \(direction)."
    }

    private func speak(_ text: String) {
        navLog.info("speaking: \(text)")
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            navLog.error("audio session activate failed: \(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            navLog.error("audio session deactivate failed: \(error.localizedDescription)")
        }
    }
}

extension NavigationPlan {
    /// Step-by-step sentence for text-to-speech, reusing `BusLeg.announcement` for the transit legs.
    var spokenSummary: String {
        legs.map { leg in
            switch leg {
            case .walk(let w):
                let minutes = max(1, Int(w.expectedTravelTimeSeconds / 60))
                return "Walk \(minutes) minute\(minutes == 1 ? "" : "s") to \(w.to.spokenName)."
            case .bus(let b):
                return b.announcement
            }
        }.joined(separator: " ")
    }
}
