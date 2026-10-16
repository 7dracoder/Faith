import Foundation
import os

/// The speech recognizer and microphone, behind a protocol so the push-to-talk
/// logic is unit tested without audio hardware. Call every method from the main thread.
protocol SpeechRecognitionBackend: AnyObject {
    func requestAuthorization() async -> Bool
    /// Starts the microphone and the recognizer. Both callbacks arrive on the main queue.
    /// `onResult` gets the best transcript so far and whether it is the final one.
    /// `onEnd` means the recognizer is done (final result delivered, or it failed).
    func start(
        contextualStrings: [String],
        onResult: @escaping (String, Bool) -> Void,
        onEnd: @escaping () -> Void
    ) throws
    /// No more audio is coming: the recognizer wraps up and delivers its final result.
    func endAudio()
    /// Stops everything now. No more callbacks.
    func cancel()
}

/// Push-to-talk speech to text on the phone itself.
///
/// Press starts the microphone, release returns what was said ("where's my mug").
/// The coordinator hands that to the locator, which picks out the object, and it
/// understands "found" / "calibrate" on its own.
///
/// Call `startListening` from the main thread. All state is touched on main only,
/// which is what makes the unchecked `Sendable` safe.
final class VoiceCommandListener: VoiceCommandListening, @unchecked Sendable {
    /// The microphone closes by itself this long after the press.
    static let hardStopSeconds: TimeInterval = 6
    /// After release: how long to wait for the recognizer's final wording before
    /// settling for the best partial transcript.
    static let finalResultGraceSeconds: TimeInterval = 1.0

    /// Words the recognizer should favor: the objects we expect, the voice commands,
    /// and the answers to "want to navigate?".
    static var contextualStrings: [String] {
        let commands = ["calibrate", "recalibrate", "recenter", "found", "found it", "got it"]
        let answers = ["yes", "yeah", "yep", "sure", "okay", "go", "navigate", "no", "nope", "nah", "cancel"]
        return Config.knownObjects + commands + answers
    }

    var onPartialTranscript: ((String) -> Void)?

    private let backend: SpeechRecognitionBackend
    private let hardStop: TimeInterval
    private let finalResultGrace: TimeInterval
    private let logger = Logger(subsystem: "app.faith.finder", category: "VoiceListener")

    private var isActive = false
    /// Bumped per press so late callbacks of an old one are ignored.
    private var sessionNumber = 0
    private var hasEndedAudio = false
    private var isRecognitionDone = false
    private var bestTranscript = ""
    private var waiters: [CheckedContinuation<String, Never>] = []
    private var hardStopTimer: DispatchWorkItem?
    private var graceTimer: DispatchWorkItem?

    init(
        backend: SpeechRecognitionBackend,
        hardStop: TimeInterval = VoiceCommandListener.hardStopSeconds,
        finalResultGrace: TimeInterval = VoiceCommandListener.finalResultGraceSeconds
    ) {
        self.backend = backend
        self.hardStop = hardStop
        self.finalResultGrace = finalResultGrace
    }

    // MARK: - VoiceCommandListening

    func requestAuthorization() async -> Bool {
        let granted = await backend.requestAuthorization()
        logger.info("Speech and microphone permission granted: \(granted, privacy: .public)")
        return granted
    }

    func startListening() throws {
        if isActive {
            logger.info("startListening while already listening, starting over")
            finish(with: "")
        }

        sessionNumber += 1
        let session = sessionNumber
        hasEndedAudio = false
        isRecognitionDone = false
        bestTranscript = ""

        try backend.start(
            contextualStrings: Self.contextualStrings,
            onResult: { [weak self] transcript, isFinal in
                self?.handleResult(transcript, isFinal: isFinal, session: session)
            },
            onEnd: { [weak self] in
                self?.handleRecognitionEnded(session: session)
            }
        )
        isActive = true

        hardStopTimer = schedule(after: hardStop) { [weak self] in
            self?.handleHardStop(session: session)
        }
        logger.info("Listening")
    }

    func stopListening() async -> String {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.resolveStop(continuation)
            }
        }
    }

    private func resolveStop(_ continuation: CheckedContinuation<String, Never>) {
        guard isActive else {
            continuation.resume(returning: "")
            return
        }
        if !waiters.isEmpty {
            // Second call while the first is still waiting for the final wording: cancel.
            logger.info("stopListening called again, cancelling")
            waiters.append(continuation)
            finish(with: "")
            return
        }

        waiters.append(continuation)
        endAudioIfNeeded()
        if isRecognitionDone {
            finish(with: bestTranscript)
            return
        }
        let session = sessionNumber
        graceTimer = schedule(after: finalResultGrace) { [weak self] in
            self?.handleGraceExpired(session: session)
        }
    }

    // MARK: - Recognizer events

    private func handleResult(_ transcript: String, isFinal: Bool, session: Int) {
        guard session == sessionNumber, isActive else {
            return
        }
        // The final result is sometimes empty; never let it erase what was heard.
        if !transcript.isEmpty {
            bestTranscript = transcript
            onPartialTranscript?(transcript)
        }
        if isFinal {
            handleRecognitionEnded(session: session)
        }
    }

    private func handleRecognitionEnded(session: Int) {
        guard session == sessionNumber, isActive else {
            return
        }
        isRecognitionDone = true
        // Still holding push-to-talk: keep the transcript for the release.
        if !waiters.isEmpty {
            finish(with: bestTranscript)
        }
    }

    private func handleHardStop(session: Int) {
        guard session == sessionNumber, isActive else {
            return
        }
        logger.info("Hard stop, microphone closed")
        endAudioIfNeeded()
    }

    private func handleGraceExpired(session: Int) {
        guard session == sessionNumber, isActive else {
            return
        }
        logger.info("No final result in time, using the best partial transcript")
        finish(with: bestTranscript)
    }

    // MARK: - Ending

    private func endAudioIfNeeded() {
        guard !hasEndedAudio else {
            return
        }
        hasEndedAudio = true
        backend.endAudio()
    }

    private func finish(with result: String) {
        hardStopTimer?.cancel()
        hardStopTimer = nil
        graceTimer?.cancel()
        graceTimer = nil

        backend.cancel()
        isActive = false
        logger.info("Heard \"\(result, privacy: .public)\"")

        let waiting = waiters
        waiters = []
        for continuation in waiting {
            continuation.resume(returning: result)
        }
    }

    private func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return work
    }
}
