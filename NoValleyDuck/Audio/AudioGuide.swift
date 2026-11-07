import AVFoundation
import os

private let log = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "audio")

/// All app audio in one engine and one session (SPEC §3 "Background operation"):
/// a 3D beacon (HRTF), short earcons, and speech that ducks the beacon. While a route runs the
/// engine never stops, so iOS keeps the app alive with the screen locked.
@MainActor
final class AudioGuide: NSObject, AVSpeechSynthesizerDelegate {
    enum Cue { case chime, tick, earcon, spotBeep, found, lost }

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let beacon = AVAudioPlayerNode()
    private let cues = AVAudioPlayerNode()
    private let keepAlive = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var waiters: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private var configured = false
    private(set) var running = false
    private let beaconVolume: Float = 0.7

    var isSpeaking: Bool { synthesizer.isSpeaking }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // playAndRecord (not playback) so voice answers can use the iPhone mic without
            // switching category mid-route; A2DP keeps AirPods output in stereo for the HRTF.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.allowBluetoothA2DP, .duckOthers, .defaultToSpeaker])
            try session.setActive(true)
            configure()
            try engine.start()
            keepAlive.scheduleBuffer(buffer("silence"), at: nil, options: .loops)
            keepAlive.play()
            cues.play()
            beacon.play()
            running = true
            log.info("audio started, route \(session.currentRoute.outputs.map(\.portName).joined(separator: ","))")
        } catch {
            log.error("audio start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard running else { return }
        running = false
        synthesizer.stopSpeaking(at: .word)
        beacon.stop(); cues.stop(); keepAlive.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configure() {
        guard !configured else { return }
        configured = true
        [environment, beacon, cues, keepAlive].forEach(engine.attach)
        engine.connect(beacon, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        engine.connect(cues, to: engine.mainMixerNode, format: format)
        engine.connect(keepAlive, to: engine.mainMixerNode, format: format)
        beacon.renderingAlgorithm = .HRTFHQ
        beacon.volume = beaconVolume
        cues.volume = 0.6
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)

        // Route changes (AirPods in/out) and interruptions stop the engine; bring it back.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated { if type == .ended { self?.restart() } }
        }
    }

    private func restart() {
        guard running else { return }
        log.info("audio restart after route change / interruption")
        running = false
        engine.stop()
        start()
    }

    // MARK: - Beacon

    /// Puts the beacon at `angle` degrees from straight ahead (+ = right) and plays one ping.
    /// `onTarget` switches to the brighter "you're facing it" tone.
    func ping(angle: Double, onTarget: Bool) {
        guard running else { return }
        place(beacon, angle: angle)
        beacon.scheduleBuffer(buffer(onTarget ? "onTarget" : "beacon"))
    }

    /// Moves the beacon while a ping plays, so turning the head is heard immediately.
    func moveBeacon(angle: Double) { place(beacon, angle: angle) }

    /// Waiting-spot beep, panned towards `angle` (phone-relative).
    func spotBeep(angle: Double) {
        guard running else { return }
        place(beacon, angle: angle)
        beacon.scheduleBuffer(buffer("spotBeep"))
    }

    private func place(_ node: AVAudioPlayerNode, angle: Double) {
        let a = angle * .pi / 180
        node.position = AVAudio3DPoint(x: Float(sin(a)), y: 0, z: Float(-cos(a)))
    }

    func play(_ cue: Cue) {
        guard running else { return }
        let name: String = switch cue {
        case .chime: "chime"
        case .tick: "tick"
        case .earcon: "earcon"
        case .spotBeep: "spotBeep"
        case .found: "found"
        case .lost: "lost"
        }
        cues.scheduleBuffer(buffer(name))
    }

    // MARK: - Speech

    /// Queues `text` and returns when it has been spoken. AVSpeechSynthesizer plays its queue in
    /// order, so two messages never overlap.
    func say(_ text: String) async {
        log.info("say: \(text, privacy: .public)")
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        await withCheckedContinuation { cont in
            waiters[ObjectIdentifier(u)] = cont
            synthesizer.speak(u)
        }
    }

    /// Fire-and-forget variant.
    func speak(_ text: String) { Task { await say(text) } }

    func stopSpeaking() { synthesizer.stopSpeaking(at: .word) }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.beacon.volume = self.beaconVolume * 0.2 }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.finished(id) }
    }

    private func finished(_ id: ObjectIdentifier) {
        waiters.removeValue(forKey: id)?.resume()
        if !synthesizer.isSpeaking { beacon.volume = beaconVolume }
    }

    // MARK: - Sounds

    private func buffer(_ name: String) -> AVAudioPCMBuffer {
        if let b = buffers[name] { return b }
        let b: AVAudioPCMBuffer = switch name {
        case "beacon": file("beacon", "wav") ?? tones([(660, 0.12)])
        case "onTarget": tones([(1320, 0.07), (0, 0.05), (1320, 0.07)])
        case "spotBeep": tones([(880, 0.07)])
        case "tick": tones([(2000, 0.015)], gain: 0.25)
        case "chime": tones([(1047, 0.12), (1319, 0.12), (1568, 0.22)])
        case "earcon": tones([(784, 0.09), (523, 0.14)], gain: 0.5)
        case "found": file("found", "mp3") ?? tones([(988, 0.1), (1319, 0.2)])
        case "lost": file("lost", "mp3") ?? tones([(659, 0.1), (440, 0.2)])
        default: tones([(0, 0.5)])         // "silence": keeps the engine rendering
        }
        buffers[name] = b
        return b
    }

    /// Short sine tones with a soft attack/release. Frequency 0 = pause.
    private func tones(_ notes: [(hz: Double, seconds: Double)], gain: Float = 0.6) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let total = notes.reduce(0) { $0 + Int($1.seconds * rate) }
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        b.frameLength = AVAudioFrameCount(total)
        let out = b.floatChannelData![0]
        var i = 0
        for note in notes {
            let n = Int(note.seconds * rate)
            for k in 0..<n {
                let env = Float(min(1, Double(k) / 200, Double(n - k) / 400))
                out[i] = note.hz == 0 ? 0 : gain * env * Float(sin(2 * .pi * note.hz * Double(k) / rate))
                i += 1
            }
        }
        return b
    }

    /// A bundled sound converted to the engine's mono format.
    private func file(_ name: String, _ ext: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let f = try? AVAudioFile(forReading: url),
              let src = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: src)) != nil else { return nil }
        if src.format == format { return src }
        guard let conv = AVAudioConverter(from: src.format, to: format) else { return nil }
        let ratio = format.sampleRate / src.format.sampleRate
        guard let dst = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024)
        else { return nil }
        var fed = false
        var error: NSError?
        conv.convert(to: dst, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        return error == nil ? dst : nil
    }
}
