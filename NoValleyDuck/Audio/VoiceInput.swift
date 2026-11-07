import AVFoundation
import Speech
import os

private let log = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "voice")

/// Speech-to-text from the iPhone mic, for the "Where to?" button and spoken prompt answers.
/// Uses its own engine for input; the output engine in `AudioGuide` keeps running.
@MainActor
final class VoiceInput {
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var continuation: CheckedContinuation<String?, Never>?
    private var latest: String?
    private var generation = 0          // ignores callbacks and timeouts of an earlier listen

    static func requestAccess() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    var isListening: Bool { task != nil }

    /// Listens for up to `timeout` seconds. Returns early when `done` accepts the text so far
    /// (e.g. a "yes" was heard), else the final transcript. nil if nothing was understood.
    func listen(timeout: TimeInterval, locale: Locale = .current,
                done: @escaping (String) -> Bool = { _ in false }) async -> String? {
        cancel()
        #if targetEnvironment(simulator)
        return nil              // no mic input in the simulator (see AudioGuide.start)
        #endif
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        latest = nil
        generation += 1
        let gen = generation

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return nil }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            // e.g. the mic can't start while the app is in the background.
            log.error("voice input start failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return nil
        }

        return await withCheckedContinuation { cont in
            continuation = cont
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    if let text, !text.isEmpty { self.latest = text }
                    if let text, done(text) { self.finish(text) }
                    else if final || error != nil { self.finish(self.latest) }
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.generation == gen else { return }
                self.finish(self.latest)
            }
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ text: String?) {
        guard task != nil || continuation != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        let c = continuation
        continuation = nil
        c?.resume(returning: text)
        if let text { log.info("heard: \(text, privacy: .public)") }
    }
}
