import Foundation
import CoreHaptics
import os

/// One guidance tap and how long to wait before the next one.
struct HapticPulse: Equatable {
    var interval: TimeInterval
    var intensity: Float
    var sharpness: Float
    /// Two soft taps instead of one: the user is facing away from the object.
    var isWrongWay: Bool
}

/// Distance to pulse: about one tap a second from 3 m away, speeding up to one every
/// 0.15 s and growing stronger and sharper within 30 cm.
enum HapticGuidance {
    static let farMeters: Float = 3.0
    static let nearMeters: Float = 0.30
    static let slowestInterval: TimeInterval = 1.0
    static let fastestInterval: TimeInterval = 0.15
    /// Facing more than this far off the object counts as the wrong way, unless already within reach.
    static let wrongWayDegrees: Float = 90
    static let wrongWayMinimumMeters: Float = 0.6

    /// 0 at 3 m or farther, 1 at 30 cm or closer.
    static func closeness(phoneDistance: Float) -> Float {
        let raw = (farMeters - phoneDistance) / (farMeters - nearMeters)
        return min(max(raw, 0), 1)
    }

    static func pulse(phoneDistance: Float, angleDegrees: Float) -> HapticPulse {
        let c = closeness(phoneDistance: phoneDistance)
        let interval = slowestInterval + (fastestInterval - slowestInterval) * TimeInterval(c)
        if phoneDistance > wrongWayMinimumMeters && abs(angleDegrees) > wrongWayDegrees {
            return HapticPulse(interval: max(interval, 0.8), intensity: 0.45, sharpness: 0.1, isWrongWay: true)
        }
        return HapticPulse(interval: interval, intensity: 0.35 + 0.65 * c, sharpness: 0.3 + 0.6 * c, isWrongWay: false)
    }
}

/// Plays guidance pulses (HapticGuidance). Silent on devices without haptics (simulator, iPads).
///
/// Robust to iOS stopping the haptic engine behind our back (app backgrounded, audio
/// interruption, server reset): the engine reports it through `stoppedHandler` /
/// `resetHandler`, and the next pulse restarts it.
@MainActor
final class ProximityHaptics {
    private var engine: CHHapticEngine?
    private var isEngineRunning = false
    private var lastPulseAt: Date?
    private let logger = Logger(subsystem: "app.faith.finder", category: "ProximityHaptics")

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return
        }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            engine.stoppedHandler = { [weak self] reason in
                Task { @MainActor in
                    self?.handleEngineStopped(reason: reason)
                }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.isEngineRunning = false
                }
            }
            self.engine = engine
        } catch {
            logger.error("Haptics unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called every frame during guidance; taps when the pulse's interval has passed. nil = stop.
    func update(_ pulse: HapticPulse?, now: Date = Date()) {
        guard let pulse else {
            stop()
            return
        }
        guard engine != nil else {
            return
        }
        if let lastPulseAt, now.timeIntervalSince(lastPulseAt) < pulse.interval {
            return
        }
        if lastPulseAt == nil {
            logger.info("Guidance haptics on")
        }
        lastPulseAt = now
        play(pulse)
    }

    func stop() {
        guard lastPulseAt != nil else {
            return
        }
        lastPulseAt = nil
        logger.info("Guidance haptics off")
    }

    private func play(_ pulse: HapticPulse) {
        guard let engine else {
            return
        }
        func tap(_ intensity: Float, at time: TimeInterval) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness)
            ], relativeTime: time)
        }
        let events = pulse.isWrongWay
            ? [tap(pulse.intensity, at: 0), tap(pulse.intensity * 0.7, at: 0.09)]
            : [tap(pulse.intensity, at: 0)]
        do {
            if !isEngineRunning {
                try engine.start()
                isEngineRunning = true
            }
            try engine.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {
            logger.warning("Haptic pulse failed (\(error.localizedDescription, privacy: .public)); restarting next time")
            isEngineRunning = false
        }
    }

    private func handleEngineStopped(reason: CHHapticEngine.StoppedReason) {
        logger.warning("Haptic engine stopped by iOS (reason \(reason.rawValue, privacy: .public)); will restart when needed")
        isEngineRunning = false
    }
}
