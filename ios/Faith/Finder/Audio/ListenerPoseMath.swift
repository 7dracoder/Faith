import Foundation
import simd

/// Turns the phone pose plus the AirPods head rotation into the pose of the
/// listener's ears. Pure math, unit tested.
/// Conventions: ARKit world space, meters, +Y up. Yaw + = LEFT, pitch + = UP.
enum ListenerPoseMath {
    private static let worldUp = SIMD3<Float>(0, 1, 0)
    private static let defaultForward = SIMD3<Float>(0, 0, -1)

    static func compose(body: BodyPose, head: HeadRotation, rig: ListenerRig) -> ListenerPose {
        let bodyForward = horizontalUnit(body.forward)

        let position: SIMD3<Float>
        switch rig {
        case .standInFront(let backOffsetMeters, let upOffsetMeters):
            position = body.position - bodyForward * backOffsetMeters + worldUp * upOffsetMeters
        case .chestMount(let upOffsetMeters):
            position = body.position + worldUp * upOffsetMeters
        }

        // + yaw = head turned LEFT, which is a positive rotation around +Y.
        let yawRotation = simd_quatf(angle: head.yawRadians, axis: worldUp)
        let forwardYaw = simd_normalize(yawRotation.act(bodyForward))
        let rightYaw = simd_normalize(simd_cross(forwardYaw, worldUp))

        // + pitch = looking UP, which is a positive rotation around the right axis.
        let pitchRotation = simd_quatf(angle: head.pitchRadians, axis: rightYaw)
        let forward = simd_normalize(pitchRotation.act(forwardYaw))
        let up = simd_normalize(simd_cross(rightYaw, forward))

        return ListenerPose(position: position, forward: forward, up: up)
    }

    /// `BodyPose.forward` should already be a horizontal unit vector. This keeps
    /// the audio engine from receiving NaNs if it ever is not.
    private static func horizontalUnit(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        var flat = vector
        flat.y = 0

        let length = simd_length(flat)
        if length < 1e-5 {
            return defaultForward
        }
        return flat / length
    }
}
