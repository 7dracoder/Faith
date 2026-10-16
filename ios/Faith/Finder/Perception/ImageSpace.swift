import Foundation

/// Maps UPRIGHT image space (what the vision model sees) to SENSOR image space (what
/// ARCamera.intrinsics, capturedImage and the LiDAR depth map use).
/// Both are normalized: (0,0) top-left, (1,1) bottom-right.
///
/// ARKit's sensor image is always landscape-right, however the phone is held.
/// For a phone held portrait, the upright image is the sensor image rotated
/// 90 degrees clockwise:
///     upright.x = 1 - sensor.y,  upright.y = sensor.x
/// so the inverse used here is:
///     sensor.x = upright.y,      sensor.y = 1 - upright.x
///
/// This is candidate A. VERIFY ON DEVICE with the corner test
/// (object near the top-left of the preview, request it, the red sphere must land
/// on it). If it is wrong, switch to the candidate that works and update
/// ImageSpaceTests so it stays locked.
enum ImageSpace {
    static func sensorNormalized(
        fromUpright point: NormalizedPoint,
        rotation: UprightRotation
    ) -> NormalizedPoint {
        switch rotation {
        case .portrait:
            return NormalizedPoint(
                x: point.y,
                y: 1.0 - point.x
            )
        case .landscapeRight:
            // The sensor image is already landscape-right.
            return point
        }
    }
}
