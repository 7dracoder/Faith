import AVFoundation
import os

/// Plays the pre-recorded voice lines.
///
/// The clips are generated once with ElevenLabs (`scripts/make_voice_clips.py`,
/// see Voice/ELEVENLABS.md) and shipped in `Voice/Clips/`, so nothing here
/// touches the network. They play centered, not spatialized, on the audio
/// module's `AVAudioSession`, which this class never configures. While a line
/// plays the cue is ducked, not stopped.
///
/// All state is touched on the main thread only, which is what makes the
/// unchecked `Sendable` safe.
final class VoicePromptPlayer: NSObject, VoicePromptPlaying, AVAudioPlayerDelegate, @unchecked Sendable {
    private struct Playback {
        let number: Int
        let player: AVAudioPlayer
        let continuation: CheckedContinuation<Void, Never>
    }

    /// `AudioBufferLoader` order: a .wav wins over an .mp3 of the same name.
    static let clipExtensions = ["wav", "mp3"]
    /// Extra time after a clip's length before `play` gives up waiting for it to end.
    private static let finishGraceSeconds: TimeInterval = 1

    private let logger = Logger(subsystem: "app.faith.finder", category: "VoicePrompt")
    private weak var ducking: CueDucking?
    private var players: [String: AVAudioPlayer] = [:]
    private var current: Playback?
    private var playbackCount = 0
    private var watchdog: DispatchWorkItem?

    /// `clipURLs` maps `VoicePrompt.clipName` to an audio file. A file that cannot
    /// be opened is logged and skipped, never a crash.
    init(ducking: CueDucking?, clipURLs: [String: URL]) {
        self.ducking = ducking
        super.init()

        for (name, url) in clipURLs {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self
                players[name] = player
            } catch {
                logger.error("Voice clip \(name, privacy: .public) could not be opened: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Loads every clip of `VoicePrompt.allClipNames` from the bundle.
    convenience init(ducking: CueDucking?, bundle: Bundle = .main) {
        let logger = Logger(subsystem: "app.faith.finder", category: "VoicePrompt")
        var urls: [String: URL] = [:]
        for name in VoicePrompt.allClipNames {
            if let url = Self.clipURL(named: name, bundle: bundle) {
                urls[name] = url
            } else {
                logger.error("Voice clip \(name, privacy: .public) is missing. Run scripts/make_voice_clips.py (Voice/ELEVENLABS.md).")
            }
        }
        self.init(ducking: ducking, clipURLs: urls)
    }

    /// The real player when `audio` is the real engine (so the cue can be ducked).
    /// nil for mock audio: AppEnvironment keeps `MockVoicePromptPlayer` then.
    static func make(audio: SpatialAudioRendering, bundle: Bundle = .main) -> VoicePromptPlayer? {
        guard let ducking = audio as? CueDucking else {
            return nil
        }
        return VoicePromptPlayer(ducking: ducking, bundle: bundle)
    }

    static func clipURL(named name: String, bundle: Bundle = .main) -> URL? {
        for fileExtension in clipExtensions {
            if let url = bundle.url(forResource: name, withExtension: fileExtension) {
                return url
            }
        }
        return nil
    }

    /// Names of the clips that loaded. Main thread.
    var loadedClipNames: [String] {
        return players.keys.sorted()
    }

    // MARK: - VoicePromptPlaying

    func play(_ prompt: VoicePrompt) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.start(prompt, continuation: continuation)
            }
        }
    }

    func stop() {
        if Thread.isMainThread {
            finishCurrent()
            return
        }
        DispatchQueue.main.async {
            self.finishCurrent()
        }
    }

    // MARK: - Playback (main thread)

    private func start(_ prompt: VoicePrompt, continuation: CheckedContinuation<Void, Never>) {
        // A new prompt cuts off the one that is playing.
        finishCurrent()

        let name = prompt.clipName
        guard let player = players[name] else {
            logger.error("No clip for \(name, privacy: .public), staying silent")
            continuation.resume()
            return
        }

        player.currentTime = 0
        player.volume = Config.voiceLineVolume
        guard player.play() else {
            logger.error("Clip \(name, privacy: .public) would not start")
            continuation.resume()
            return
        }
        ducking?.setCueDucked(true)
        logger.info("Playing \(name, privacy: .public)")

        playbackCount += 1
        let number = playbackCount
        current = Playback(number: number, player: player, continuation: continuation)

        // The delegate normally ends it. This only fires if the callback never comes
        // (an interruption can swallow it), so a request can never hang on a voice line.
        let work = DispatchWorkItem { [weak self] in
            self?.finishPlayback(number: number)
        }
        watchdog = work
        let limit = player.duration + Self.finishGraceSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: work)
    }

    private func finishPlayback(number: Int) {
        guard let current, current.number == number else {
            return
        }
        finishCurrent()
    }

    /// Stops the clip that is playing, restores the cue and lets its `play` call return.
    private func finishCurrent() {
        guard let playback = current else {
            return
        }
        current = nil
        watchdog?.cancel()
        watchdog = nil

        if playback.player.isPlaying {
            playback.player.stop()
        }
        ducking?.setCueDucked(false)
        playback.continuation.resume()
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.finishIfCurrent(player)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            self.finishIfCurrent(player)
        }
    }

    private func finishIfCurrent(_ player: AVAudioPlayer) {
        guard let current, current.player === player else {
            return
        }
        // Playing again already: this callback belongs to the previous run of the same clip.
        guard !player.isPlaying else {
            return
        }
        finishCurrent()
    }
}
