import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.novalleyduck.NoValleyDuck", category: "prompt")

/// One possible answer to a spoken question.
struct PromptOption: Identifiable, Equatable {
    let id: String
    let label: String              // on-screen button
    let gesture: HeadGesture?      // nod / shake, nil = voice or button only
    let words: [String]            // spoken keywords, lowercase

    static let yes = PromptOption(id: "yes", label: "Yes", gesture: .nod, words: ["yes", "yeah", "yep", "sure", "ok", "okay", "ja"])
    static let no = PromptOption(id: "no", label: "No", gesture: .shake, words: ["no", "nope", "nein", "not"])
}

struct PendingPrompt: Equatable {
    let question: String
    let options: [PromptOption]
}

/// Asks a question and waits for an answer (SPEC Phase 4 step 2): gestures only count inside the
/// ~8 s window right after the question, an earcon closes the window, and with no answer the
/// question is repeated once. Nod, shake, voice and the on-screen buttons all answer.
@Observable
@MainActor
final class Prompter {
    static let window: TimeInterval = 8

    private(set) var pending: PendingPrompt?
    @ObservationIgnored private let audio: AudioGuide
    @ObservationIgnored private let voice: VoiceInput
    @ObservationIgnored private var answer: CheckedContinuation<PromptOption?, Never>?
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var busy = false

    init(audio: AudioGuide, voice: VoiceInput) {
        self.audio = audio
        self.voice = voice
    }

    /// nil = no answer after asking twice (or cancelled). Questions never overlap: a second
    /// call waits until the first one is done.
    func ask(_ question: String, options: [PromptOption] = [.yes, .no]) async -> PromptOption? {
        let cancels = self.cancels
        while busy { try? await Task.sleep(for: .milliseconds(200)) }
        guard cancels == self.cancels else { return nil }   // route stopped while waiting
        busy = true
        defer { busy = false; pending = nil }
        pending = PendingPrompt(question: question, options: options)
        for attempt in 0..<2 {
            guard pending != nil else { return nil }          // cancelled
            await audio.say(attempt == 0 ? question : "Again: \(question)")
            guard pending != nil else { return nil }          // cancelled while speaking
            if let a = await window(options) { return a }
        }
        log.info("no answer to: \(question, privacy: .public)")
        return nil
    }

    /// Head gesture from the AirPods. Ignored outside a window (SPEC: nods while walking are ignored).
    func gesture(_ g: HeadGesture) {
        guard listening, let o = pending?.options.first(where: { $0.gesture == g }) else { return }
        resolve(o)
    }

    /// On-screen button.
    func choose(_ option: PromptOption) {
        guard pending != nil else { return }
        if listening { resolve(option) } else { pendingTap = option }
    }

    func cancel() {
        cancels += 1
        pending = nil
        pendingTap = nil
        resolve(nil)
    }

    @ObservationIgnored private var cancels = 0

    /// A tap while the question is still being spoken counts once the window opens.
    @ObservationIgnored private var pendingTap: PromptOption?
    @ObservationIgnored private var windowID = 0

    private func window(_ options: [PromptOption]) async -> PromptOption? {
        if let tap = pendingTap { pendingTap = nil; return tap }
        listening = true
        windowID += 1
        let id = windowID
        let result = await withCheckedContinuation { (cont: CheckedContinuation<PromptOption?, Never>) in
            answer = cont
            Task {
                let heard = await voice.listen(timeout: Self.window) { text in
                    Self.match(text, options) != nil
                }
                if let heard, let o = Self.match(heard, options), windowID == id { resolve(o) }
            }
            Task {
                try? await Task.sleep(for: .seconds(Self.window))
                if windowID == id { resolve(nil) }
            }
        }
        listening = false
        voice.cancel()
        audio.play(.earcon)
        return result
    }

    private func resolve(_ option: PromptOption?) {
        guard let a = answer else { return }
        answer = nil
        if let option { log.info("answer: \(option.id, privacy: .public)") }
        a.resume(returning: option)
    }

    /// First option whose keyword appears as a whole word (or phrase) in `text`.
    static func match(_ text: String, _ options: [PromptOption]) -> PromptOption? {
        let words = normalize(text)
        // Longer keywords first, so "didn't stop" wins over a shorter overlapping keyword.
        let pairs = options.flatMap { o in o.words.map { (o, normalize($0)) } }.sorted { $0.1.count > $1.1.count }
        return pairs.first { words.contains($0.1) }?.0
    }

    /// " didn t stop " style: lowercase letters only, single spaces, padded so `contains` matches whole words.
    private static func normalize(_ s: String) -> String {
        " " + s.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ") + " "
    }
}
