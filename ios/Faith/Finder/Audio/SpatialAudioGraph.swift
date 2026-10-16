import AVFoundation
import simd

/// The nodes and wiring of the audio engine, kept apart
/// from session handling and pulsing so the spatialization itself can be
/// rendered offline in unit tests.
///
///   cuePlayers (MONO 48 kHz, one per voice) --> environment (HRTF) --> mainMixer --> output
///   earconPlayer (stereo)                   -------------------------> mainMixer
///
/// World coordinates go in unchanged: AVAudioEnvironmentNode uses the same
/// right-handed, +Y up, meters convention as ARKit.
final class SpatialAudioGraph {
    /// A cue can be longer than the pulse interval (the echo cue rings for about
    /// 1 s, the fastest interval is 0.15 s). Each pulse goes to the next voice so
    /// the tails overlap instead of being cut off or queued up.
    static let cueVoiceCount = 8

    let engine = AVAudioEngine()
    let environment = AVAudioEnvironmentNode()
    let cuePlayers: [AVAudioPlayerNode]
    let earconPlayer = AVAudioPlayerNode()

    private var isBuilt = false

    init() {
        var players: [AVAudioPlayerNode] = []
        for _ in 0..<Self.cueVoiceCount {
            players.append(AVAudioPlayerNode())
        }
        cuePlayers = players
    }

    func buildIfNeeded() throws {
        if isBuilt {
            return
        }

        let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: AudioBufferLoader.sampleRate,
            channels: 1
        )
        let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: AudioBufferLoader.sampleRate,
            channels: 2
        )
        guard let monoFormat, let stereoFormat else {
            throw FinderError.audioEngineFailed("Could not create the engine formats")
        }

        engine.attach(environment)
        engine.attach(earconPlayer)
        engine.connect(environment, to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(earconPlayer, to: engine.mainMixerNode, format: stereoFormat)

        for cuePlayer in cuePlayers {
            engine.attach(cuePlayer)
            // The cue MUST reach the environment node as mono or it is not spatialized.
            engine.connect(cuePlayer, to: environment, format: monoFormat)
            cuePlayer.renderingAlgorithm = .HRTFHQ
            cuePlayer.sourceMode = .pointSource
        }

        environment.outputType = .headphones
        environment.reverbParameters.enable = false

        let attenuation = environment.distanceAttenuationParameters
        attenuation.distanceAttenuationModel = .inverse
        attenuation.referenceDistance = 0.3
        attenuation.maximumDistance = 5
        attenuation.rolloffFactor = 1.0

        isBuilt = true
    }

    func setListener(_ pose: ListenerPose) {
        environment.listenerPosition = AVAudio3DPoint(
            x: pose.position.x,
            y: pose.position.y,
            z: pose.position.z
        )

        let forward = AVAudio3DVector(x: pose.forward.x, y: pose.forward.y, z: pose.forward.z)
        let up = AVAudio3DVector(x: pose.up.x, y: pose.up.y, z: pose.up.z)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(forward: forward, up: up)
    }

    /// Every voice plays from the same spot.
    func setSourcePosition(_ worldPosition: SIMD3<Float>) {
        let position = AVAudio3DPoint(
            x: worldPosition.x,
            y: worldPosition.y,
            z: worldPosition.z
        )
        for cuePlayer in cuePlayers {
            cuePlayer.position = position
        }
    }

    func setCueVolume(_ volume: Float) {
        for cuePlayer in cuePlayers {
            cuePlayer.volume = volume
        }
    }

    /// Call only while the engine is running.
    func playCuePlayers() {
        for cuePlayer in cuePlayers {
            if !cuePlayer.isPlaying {
                cuePlayer.play()
            }
        }
    }

    func stopCuePlayers() {
        for cuePlayer in cuePlayers {
            cuePlayer.stop()
        }
    }
}
