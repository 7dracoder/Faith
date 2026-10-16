import Foundation
import os

/// Logs each prompt instead of playing it. Main-actor so `played` keeps the order lines were said.
@MainActor
final class MockVoicePromptPlayer: VoicePromptPlaying {
    private(set) var played: [VoicePrompt] = []

    private let logger = Logger(subsystem: "app.faith.finder", category: "MockVoicePrompt")

    nonisolated init() {}

    func play(_ prompt: VoicePrompt) async {
        logger.info("play \(prompt.clipName, privacy: .public)")
        played.append(prompt)
    }

    nonisolated func stop() {
        logger.info("stop")
    }
}
