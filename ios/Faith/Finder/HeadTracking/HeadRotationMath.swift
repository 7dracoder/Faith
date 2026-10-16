import Foundation

/// Maps CoreMotion's headphone attitude angles to our convention
///: yaw + = head turned LEFT, pitch + = looking UP.
/// Pure math so the clamp and the signs are unit tested.
enum HeadRotationMath {
    /// VERIFY ON DEVICE with the debug panel (or HeadTracker's console log):
    /// turn your head left, yaw must go positive. If it goes negative, set this to -1.
    static let yawSign: Float = 1
    /// VERIFY ON DEVICE: look up, pitch must go positive. If not, set this to -1.
    static let pitchSign: Float = 1

    static let maximumPitchRadians: Float = 60 * Float.pi / 180

    /// `rawYawRadians` and `rawPitchRadians` come straight from `CMAttitude.yaw` / `.pitch`
    /// of the attitude relative to the calibration reference. Roll is ignored.
    static func headRotation(rawYawRadians: Double, rawPitchRadians: Double) -> HeadRotation {
        let yaw = yawSign * Float(rawYawRadians)

        let unclampedPitch = pitchSign * Float(rawPitchRadians)
        let pitch = min(max(unclampedPitch, -maximumPitchRadians), maximumPitchRadians)

        return HeadRotation(yawRadians: yaw, pitchRadians: pitch)
    }
}
