import Foundation
import simd

/// "Metal detector" for the last stretch of a search. Once the PHONE is inside a bubble
/// around the object, the cue follows the phone's distance to the object instead of the
/// head's angle: the pulse speeds up (and the phone vibrates harder) as it closes in.
/// Pure functions, unit tested. Tuning values live in Config.
enum DetectorCue {
    /// Hysteresis so the mode doesn't flicker at the edge: enter inside the enter radius,
    /// leave only beyond the (larger) exit radius.
    static func isActive(phoneDistance: Float, wasActive: Bool) -> Bool {
        if wasActive {
            return phoneDistance < Config.detectorExitRadiusMeters
        }
        return phoneDistance < Config.detectorEnterRadiusMeters
    }

    /// 0 at the bubble edge, 1 when the phone is touching the object.
    static func closeness(phoneDistance: Float) -> Float {
        let edge = Config.detectorEnterRadiusMeters
        let touching = Config.detectorTouchingMeters
        let span = max(edge - touching, 0.001)
        let raw = (edge - phoneDistance) / span
        return min(max(raw, 0), 1)
    }

    /// Replaces the angle-based cue with a distance-based one while in the bubble.
    static func adjust(_ cue: CueParameters, phoneDistance: Float) -> CueParameters {
        let c = Double(closeness(phoneDistance: phoneDistance))
        let slowest = Config.detectorSlowestIntervalSeconds
        let fastest = Config.detectorFastestIntervalSeconds
        let interval = slowest + (fastest - slowest) * c

        var adjusted = cue
        adjusted.intervalSeconds = interval
        adjusted.gain = min(1, max(cue.gain, 0.9 + 0.1 * Float(c)))
        adjusted.isOnTarget = phoneDistance < Config.detectorOnTargetMeters
        return adjusted
    }
}

/// Keeps the 3D sound steady while the user reaches with the phone. The listener's ears are
/// derived from the phone (chest rig), so moving the phone toward the object would drag the
/// sound around. Walking still updates the ears; once the ears are within arm's reach of the
/// object they lock, and they unlock again if the phone moves well away (walking off).
enum ReachLock {
    /// Returns the ear position to use and whether it is locked.
    static func update(
        locked: SIMD3<Float>?,
        liveEars: SIMD3<Float>,
        phone: SIMD3<Float>,
        target: SIMD3<Float>
    ) -> SIMD3<Float>? {
        if let locked {
            let phoneDistance = Geometry.horizontalDistance(phone, target)
            if phoneDistance > Config.reachUnlockMeters {
                return nil
            }
            return locked
        }
        let earsDistance = Geometry.horizontalDistance(liveEars, target)
        if earsDistance < Config.reachLockMeters {
            return liveEars
        }
        return nil
    }
}
