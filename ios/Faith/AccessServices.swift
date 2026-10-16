import AVFoundation
import CoreMotion
import Speech
import SwiftUI
import UIKit

@MainActor
final class AccessServices: ObservableObject {
    @Published var motionEnabled = false
    @Published var focusedIndex = -1
    @Published var motionStatus = "Touch and text ready"
    @Published var listening = false
    @Published var transcript = ""
    @Published var speechStatus = ""
    var optionCount = 0
    var suspended = false
    var hapticsEnabled = false
    var spokenUpdates = false
    private let motion = CMMotionManager()
    private var baseline: Double?
    private var centered = true
    private var lastMove = Date.distantPast
    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var hasTap = false
    private var stopTimer: Task<Void, Never>?

    func feedback(_ message: String, success: Bool = false) {
        UIAccessibility.post(notification: .announcement, argument: message)
        if hapticsEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .warning)
        }
        if spokenUpdates && !UIAccessibility.isVoiceOverRunning { read(message) }
    }

    func read(_ message: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate); return }
        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = 0.46
        synthesizer.speak(utterance)
    }

    func toggleMotion() {
        if motionEnabled { stopMotion(); return }
        guard motion.isDeviceMotionAvailable else {
            motionStatus = "Motion is unavailable on this device. Touch and keyboard still work."
            return
        }
        baseline = nil
        centered = true
        motionEnabled = true
        motionStatus = "Hold comfortably to calibrate. Tilt left or right to explore."
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let roll = sample?.attitude.roll else { return }
            Task { @MainActor in self?.handleMotion(roll) }
        }
    }

    private func handleMotion(_ roll: Double) {
        guard motionEnabled else { return }
        guard let baseline = self.baseline else {
            self.baseline = roll
            motionStatus = "Tilt controls ready. Return to center between moves."
            return
        }
        guard !suspended, optionCount > 0 else { return }
        let delta = roll - baseline
        if abs(delta) < 0.1 { centered = true }
        guard abs(delta) > 0.28, centered, Date().timeIntervalSince(lastMove) > 1.1 else { return }
        centered = false
        lastMove = Date()
        focusedIndex = max(0, min(optionCount - 1, focusedIndex + (delta > 0 ? 1 : -1)))
        motionStatus = "Option \(focusedIndex + 1) of \(optionCount)"
        if hapticsEnabled { UISelectionFeedbackGenerator().selectionChanged() }
    }

    func stopMotion() {
        motion.stopDeviceMotionUpdates()
        motionEnabled = false
        baseline = nil
        motionStatus = "Touch and text ready"
    }

    func toggleDictation() async {
        if listening { stopDictation(); return }
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let micAllowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard speechAllowed, micAllowed else {
            speechStatus = "Dictation permission was not granted. Type your search instead."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            speechStatus = "On-device dictation isn’t available. Type or use your keyboard’s dictation."
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            recognitionRequest = request
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw FaithAPIError.server("No microphone input is available.") }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            hasTap = true
            engine.prepare()
            try engine.start()
            listening = true
            speechStatus = "Listening. Tap Stop when finished. Your words appear below."
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.stopDictation() }
                }
            }
            stopTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled { self?.stopDictation() }
            }
        } catch {
            stopDictation()
            speechStatus = "Dictation couldn’t start. Type your search instead."
        }
    }

    func stopDictation() {
        stopTimer?.cancel()
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        recognitionRequest?.endAudio()
        recognition?.cancel()
        recognition = nil
        recognitionRequest = nil
        listening = false
        speechStatus = "Dictation stopped. Review your text before searching."
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func pause() {
        stopMotion()
        if listening { stopDictation() }
        synthesizer.stopSpeaking(at: .immediate)
    }
}
