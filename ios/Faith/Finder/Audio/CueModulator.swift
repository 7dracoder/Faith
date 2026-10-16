import Foundation
import simd

/// Maps "how far off is the listener facing" to the cue pulse rate
///. The pulse gets faster as the listener faces the target,
/// which is what resolves HRTF front/back confusion, so keep the range wide.
enum CueModulator {
    /// Pulse interval when facing the target dead on.
    static let fastestIntervalSeconds: Double = 0.15
    /// Pulse interval when the target is 90 degrees or more off to the side.
    static let slowestIntervalSeconds: Double = 0.70
    static let fullSlowdownAngleDegrees: Float = 90
    static let gain: Float = 0.9

    static func parameters(listener: ListenerPose, target: AnchoredTarget) -> CueParameters {
        let signedAngle = Geometry.signedHorizontalAngleDegrees(
            from: listener.position,
            forward: listener.forward,
            to: target.worldPosition
        )
        let angle = abs(signedAngle)

        let unclamped = angle / fullSlowdownAngleDegrees
        let t = Double(min(max(unclamped, 0), 1))
        let intervalSeconds = fastestIntervalSeconds + (slowestIntervalSeconds - fastestIntervalSeconds) * t

        let isOnTarget = angle < Config.onTargetThresholdDegrees

        return CueParameters(
            intervalSeconds: intervalSeconds,
            gain: gain,
            isOnTarget: isOnTarget
        )
    }
}
