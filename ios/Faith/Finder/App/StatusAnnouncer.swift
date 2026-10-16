import AVFoundation
import os

/// Spoken app-status lines a blind user needs that aren't part of a search
/// (App/Sounds/<rawValue>.wav, Ava voice). Plays on the audio module's session and
/// never configures it.
enum StatusLine: String, CaseIterable {
    /// "The camera is still starting. Hold the phone up, and move it slowly."
    case cameraStarting = "status_camera_starting"
    /// "Camera ready. Hold anywhere to ask."
    case cameraReady = "status_camera_ready"
}

@MainActor
protocol StatusAnnouncing: AnyObject {
    func say(_ line: StatusLine)
}

@MainActor
final class StatusAnnouncer: StatusAnnouncing {
    private let logger = Logger(subsystem: "app.faith.finder", category: "StatusAnnouncer")
    private var players: [StatusLine: AVAudioPlayer] = [:]

    init(bundle: Bundle = .main) {
        for line in StatusLine.allCases {
            guard let url = bundle.url(forResource: line.rawValue, withExtension: "wav") else {
                logger.error("Missing status clip \(line.rawValue, privacy: .public)")
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[line] = player
            } catch {
                logger.error("Unreadable status clip \(line.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func say(_ line: StatusLine) {
        for player in players.values where player.isPlaying {
            player.stop()
        }
        guard let player = players[line] else {
            return
        }
        player.currentTime = 0
        player.volume = Config.voiceLineVolume
        player.play()
        logger.info("Saying \(line.rawValue, privacy: .public)")
    }
}
