import Foundation
import os

final class MockVoiceListener: VoiceCommandListening {
    var onPartialTranscript: ((String) -> Void)?

    private let logger = Logger(subsystem: "app.faith.finder", category: "MockVoice")
    private let transcript = "where's my mug"

    func requestAuthorization() async -> Bool {
        return true
    }

    func startListening() throws {
        logger.info("startListening")
        onPartialTranscript?("where's")
    }

    func stopListening() async -> String {
        logger.info("stopListening -> \"\(self.transcript, privacy: .public)\"")
        onPartialTranscript?(transcript)
        return transcript
    }
}
