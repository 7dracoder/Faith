import AVFoundation
import os

/// The ONLY place in the app that configures AVAudioSession.
enum AudioSessionConfigurator {
    private static let logger = Logger(subsystem: "app.faith.finder", category: "AudioSession")

    /// Sets the category and activates the session. Call before starting the engine.
    static func configureAndActivate() throws {
        let session = AVAudioSession.sharedInstance()

        #if targetEnvironment(simulator)
        // The simulator aborts the whole app inside AURemoteIO when an engine
        // starts under .playAndRecord and the Mac's microphone is not reachable.
        // Playback-only keeps the engine testable there. Devices use the real category.
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        #else
        // .playAndRecord because speech recognition needs the mic.
        // No .allowBluetooth (HFP): it drops AirPods into mono call audio and
        // kills spatialization. With A2DP the mic input is the iPhone's own mic.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothA2DP, .mixWithOthers]
        )
        // iOS mutes haptics while the mic records unless allowed.
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        #endif
        try session.setActive(true)

        logger.info("Session active. Output: \(outputRouteDescription(), privacy: .public)")
    }

    /// Re-activates the session after an interruption or route change.
    static func activate() throws {
        try AVAudioSession.sharedInstance().setActive(true)
    }

    /// Human-readable output route for logs and the debug readout, e.g. "AirPods Pro (BluetoothA2DPOutput)".
    static func outputRouteDescription() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outputs.isEmpty {
            return "no output"
        }

        var parts: [String] = []
        for output in outputs {
            parts.append("\(output.portName) (\(output.portType.rawValue))")
        }
        return parts.joined(separator: ", ")
    }

    /// True when the output is something worn on both ears with full-quality stereo.
    /// Spatial audio is meaningless on the phone speaker or earpiece.
    static func isHeadphoneOutput() -> Bool {
        let headphonePorts: [AVAudioSession.Port] = [
            .headphones,
            .bluetoothA2DP,
            .bluetoothLE,
            .usbAudio
        ]

        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        for output in outputs {
            if headphonePorts.contains(output.portType) {
                return true
            }
        }
        return false
    }
}
