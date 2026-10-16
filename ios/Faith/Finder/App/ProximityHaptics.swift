import Foundation
import CoreHaptics
import os

/// Continuous vibration whose strength follows how close the phone is to the object
/// (DetectorCue.closeness). Silent on devices without haptics (simulator, iPads).
///
/// Robust to iOS stopping the haptic engine behind our back (app backgrounded, audio
/// interruption, server reset): the engine reports it through `stoppedHandler` /
/// `resetHandler`, and a failed parameter update also triggers a restart. Found on device:
/// without this, vibration sometimes never started in the next round.
@MainActor
final class ProximityHaptics {
    private var engine: CHHapticEngine?
    private var isEngineRunning = false
    private var player: CHHapticAdvancedPatternPlayer?
    private var isPlaying = false
    private var lastUpdate = Date.distantPast
    private let updateInterval: TimeInterval = 0.05
    private let logger = Logger(subsystem: "app.faith.finder", category: "ProximityHaptics")

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return
        }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            // Stay running between rounds; only the player starts and stops.
            engine.isAutoShutdownEnabled = false
            engine.stoppedHandler = { [weak self] reason in
                Task { @MainActor in
                    self?.handleEngineStopped(reason: reason)
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.handleEngineReset()
                }
            }
            self.engine = engine
        } catch {
            logger.error("Haptics unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// nil = stop. Otherwise 0 (bubble edge, faint) ... 1 (touching, strong and sharp).
    func update(closeness: Float?) {
        guard let closeness else {
            stop()
            return
        }
        guard engine != nil else {
            return
        }
        if !isPlaying {
            start()
            if !isPlaying {
                return
            }
        }

        let now = Date()
        guard now.timeIntervalSince(lastUpdate) >= updateInterval else {
            return
        }
        lastUpdate = now

        let intensity = CHHapticDynamicParameter(
            parameterID: .hapticIntensityControl,
            value: 0.15 + 0.85 * closeness,
            relativeTime: 0
        )
        let sharpness = CHHapticDynamicParameter(
            parameterID: .hapticSharpnessControl,
            value: 0.2 + 0.6 * closeness,
            relativeTime: 0
        )
        do {
            try player?.sendParameters([intensity, sharpness], atTime: CHHapticTimeImmediate)
        } catch {
            // The engine or player went away without telling us: rebuild on the next update.
            logger.warning("Haptics update failed (\(error.localizedDescription, privacy: .public)); restarting")
            isPlaying = false
            isEngineRunning = false
            player = nil
        }
    }

    func stop() {
        guard isPlaying else {
            return
        }
        isPlaying = false
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        logger.info("Proximity haptics off")
    }

    private func start() {
        guard let engine else {
            return
        }
        do {
            if !isEngineRunning {
                try engine.start()
                isEngineRunning = true
            }
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ],
                relativeTime: 0,
                duration: 30
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
            isPlaying = true
            logger.info("Proximity haptics on")
        } catch {
            logger.error("Could not start haptics: \(error.localizedDescription, privacy: .public)")
            isEngineRunning = false
            isPlaying = false
            player = nil
        }
    }

    private func handleEngineStopped(reason: CHHapticEngine.StoppedReason) {
        logger.warning("Haptic engine stopped by iOS (reason \(reason.rawValue, privacy: .public)); will restart when needed")
        isEngineRunning = false
        isPlaying = false
        player = nil
    }

    private func handleEngineReset() {
        logger.warning("Haptic engine reset by iOS; will restart when needed")
        isEngineRunning = false
        let wasPlaying = isPlaying
        isPlaying = false
        player = nil
        if wasPlaying {
            start()
        }
    }
}
