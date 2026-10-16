import AVFoundation
import Speech
import os

/// Checks shared by everything in Voice/ that taps the microphone.
enum MicrophoneAccess {
    /// Throws when the microphone cannot be tapped right now. Call before touching
    /// `AVAudioEngine.inputNode`: without a record-capable session (mock audio, or the
    /// simulator's playback-only category) there is no input to tap.
    static func checkReady() throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw FinderError.speechNotAuthorized
        }
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord, session.isInputAvailable else {
            throw FinderError.speechFailed("No microphone. Voice needs the real audio service on a device.")
        }
    }
}

/// `SFSpeechRecognizer` fed by its own `AVAudioEngine` input tap.
/// On-device recognition when the phone supports it: faster, and it works on bad venue Wi-Fi.
/// It never configures `AVAudioSession`; the Audio module owns that.
final class AppleSpeechBackend: SpeechRecognitionBackend {
    private let logger = Logger(subsystem: "app.faith.finder", category: "SpeechBackend")
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasTap = false
    /// Bumped on every start and cancel so callbacks of an old task are ignored.
    private var generation = 0

    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            return false
        }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start(
        contextualStrings: [String],
        onResult: @escaping (String, Bool) -> Void,
        onEnd: @escaping () -> Void
    ) throws {
        cancel()

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw FinderError.speechNotAuthorized
        }
        guard let recognizer, recognizer.isAvailable else {
            throw FinderError.speechFailed("Speech recognition is not available right now")
        }
        try MicrophoneAccess.checkReady()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw FinderError.speechFailed("Microphone format is not ready")
        }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.contextualStrings = contextualStrings
        if recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            newRequest.append(buffer)
        }
        hasTap = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stopMicrophone()
            throw FinderError.speechFailed("Voice engine failed to start: \(error.localizedDescription)")
        }

        generation += 1
        let current = generation
        request = newRequest
        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            // Copied out here: the result object stays on the recognizer's queue.
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error?.localizedDescription

            DispatchQueue.main.async {
                guard let self, current == self.generation else {
                    return
                }
                if let transcript {
                    onResult(transcript, isFinal)
                }
                if let failure {
                    self.logger.info("Recognizer ended: \(failure, privacy: .public)")
                    onEnd()
                }
            }
        }
        logger.info("Recognizer started. On-device: \(newRequest.requiresOnDeviceRecognition, privacy: .public)")
    }

    func endAudio() {
        stopMicrophone()
        request?.endAudio()
    }

    func cancel() {
        generation += 1
        stopMicrophone()
        task?.cancel()
        task = nil
        request = nil
    }

    private func stopMicrophone() {
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }
}
