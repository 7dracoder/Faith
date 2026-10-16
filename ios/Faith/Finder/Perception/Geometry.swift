import Foundation
import simd

/// Shared geometry helpers.
/// Conventions: ARKit world space, meters, +Y up. Display angles are + = RIGHT.
enum Geometry {
    /// Minimum horizontal length of the camera's forward before we consider it
    /// unreliable (phone pointing nearly straight down or up).
    static let minimumHorizontalForwardLength: Float = 0.2

    /// The camera's forward (-Z column) projected onto the horizontal plane and normalized.
    /// Returns nil when the phone points nearly straight down/up; callers keep the previous forward.
    static func horizontalForward(fromCameraTransform transform: simd_float4x4) -> SIMD3<Float>? {
        let zAxis = transform.columns.2
        var forward = SIMD3<Float>(-zAxis.x, -zAxis.y, -zAxis.z)
        forward.y = 0

        let horizontalLength = simd_length(forward)
        if horizontalLength < minimumHorizontalForwardLength {
            return nil
        }
        return forward / horizontalLength
    }

    /// + = target is to the right of forward. Degrees, -180...180.
    static func signedHorizontalAngleDegrees(
        from position: SIMD3<Float>,
        forward: SIMD3<Float>,
        to target: SIMD3<Float>
    ) -> Float {
        var toTarget = target - position
        toTarget.y = 0
        var flatForward = forward
        flatForward.y = 0

        let targetLength = simd_length(toTarget)
        let forwardLength = simd_length(flatForward)
        if targetLength < 1e-6 || forwardLength < 1e-6 {
            return 0
        }

        let a = flatForward / forwardLength
        let b = toTarget / targetLength

        let dot = simd_dot(a, b)
        // With +Y up, cross(forward, right).y is negative, so negate it to make right positive.
        let crossY = simd_cross(a, b).y
        let radians = atan2(-crossY, dot)
        return radians * 180 / Float.pi
    }

    /// Distance in the XZ plane. Ignores height.
    static func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let dx = b.x - a.x
        let dz = b.z - a.z
        return (dx * dx + dz * dz).squareRoot()
    }
}
