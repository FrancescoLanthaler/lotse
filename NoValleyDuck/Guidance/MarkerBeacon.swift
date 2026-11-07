import AVFoundation
import Observation

@Observable @MainActor
final class MarkerBeacon {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private let speech = AVSpeechSynthesizer()
    private var cue: AVAudioPlayer?
    private var prepared = false
    private var announcedAlignment = false
    private var acquiredAt: Date?
    private var lastSeen: Date?
    private var targetID: Int?
    private var buffer: AVAudioPCMBuffer?
    private var lastBeep = Date.distantPast
    var enabled = false
    var spokenCuesEnabled = false {
        didSet { if !spokenCuesEnabled { speech.stopSpeaking(at: .immediate) } }
    }
    var headTracking = false {
        didSet {
            if #available(iOS 18, *) { environment.isListenerHeadTrackingEnabled = headTracking }
        }
    }
    private(set) var status = "Audio guidance off"

    func update(detections: [TagDetection], lastFrame: Date, active: Bool, markerSize: Double) {
        guard enabled, active else { return }
        guard Date().timeIntervalSince(lastFrame) < 1 else { lostIfNeeded(); return }
        let candidates = detections.filter { $0.hamming == 0 && $0.margin >= 40 && $0.unitTranslation != nil }
        let detection = candidates.first { $0.id == targetID } ?? (targetID == nil ? candidates.max { $0.margin < $1.margin } : nil)
        guard let detection, let position = detection.unitTranslation,
              let direction = BeaconDirection.marker(cameraX: position.x, cameraY: position.y, cameraZ: position.z)
        else { lostIfNeeded(); return }
        do {
            try prepare()
            if !engine.isRunning { try engine.start() }
            lastSeen = lastFrame
            player.position = AVAudio3DPoint(x: direction.x, y: 0, z: direction.z)
            if targetID == nil {
                targetID = detection.id
                acquiredAt = Date()
                status = "Marker \(detection.id) detected"
                playCue("found")
                speak(status)
            } else if !announcedAlignment, let acquiredAt,
                      Date().timeIntervalSince(acquiredAt) >= 2, abs(direction.x) < 0.15 {
                announcedAlignment = true
                playCue("aligned")
            }
            let distance = detection.distance(markerSize: markerSize) ?? 5
            if Date().timeIntervalSince(lastBeep) >= BeaconDirection.beaconInterval(distance: distance), let buffer {
                player.scheduleBuffer(buffer)
                if !player.isPlaying { player.play() }
                lastBeep = Date()
            }
        } catch {
            reportAudioError(error)
        }
    }

    private func prepare() throws {
        guard !prepared else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient, options: [.mixWithOthers])
        try session.setActive(true)
        engine.attach(environment)
        engine.attach(player)
        guard let url = Bundle.main.url(forResource: "beacon", withExtension: "wav") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadUnknown)
        }
        try file.read(into: buffer)
        engine.connect(player, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        player.renderingAlgorithm = .HRTF
        player.volume = 0.12
        self.buffer = buffer
        try engine.start()
        prepared = true
    }

    private func lostIfNeeded() {
        guard targetID != nil, let lastSeen, Date().timeIntervalSince(lastSeen) >= 1 else { return }
        player.stop()
        targetID = nil
        announcedAlignment = false
        acquiredAt = nil
        self.lastSeen = nil
        lastBeep = .distantPast
        status = "Marker lost. Scan again."
        playCue("lost")
        speak(status)
    }

    func stop() {
        player.stop()
        speech.stopSpeaking(at: .immediate)
        targetID = nil
        announcedAlignment = false
        acquiredAt = nil
        lastSeen = nil
        lastBeep = .distantPast
        if !status.hasPrefix("Audio unavailable:") {
            status = enabled ? "Audio guidance paused" : "Audio guidance off"
        }
    }

    func start() {
        do {
            try prepare()
            status = "Searching for marker"
        } catch {
            reportAudioError(error)
        }
    }

    private func reportAudioError(_ error: Error) {
        stop()
        engine.stop()
        if !prepared {
            engine.detach(player)
            engine.detach(environment)
        }
        enabled = false
        status = "Audio unavailable: \(error.localizedDescription)"
    }

    private func speak(_ text: String) {
        guard spokenCuesEnabled else { return }
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }

    private func playCue(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return }
        cue = try? AVAudioPlayer(contentsOf: url)
        cue?.volume = 0.3
        cue?.play()
    }
}
