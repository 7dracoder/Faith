import AVFoundation
import os

/// On-device text to speech for sentences with no recorded clip. Nothing leaves the phone.
@MainActor
final class SentenceSpeaker: NSObject, SentenceSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private let logger = Logger(subsystem: "app.faith.finder", category: "SentenceSpeaker")

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        logger.info("Speaking a \(text.count, privacy: .public)-character sentence")
        await withCheckedContinuation { continuation in
            waiting[ObjectIdentifier(utterance)] = continuation
            synthesizer.speak(utterance)
        }
    }

    private func done(_ id: ObjectIdentifier) {
        waiting.removeValue(forKey: id)?.resume()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.done(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.done(id) }
    }
}
