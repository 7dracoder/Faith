import Foundation
import simd

struct Ray: Equatable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>          // unit
}

/// Turns a point in a SAVED snapshot into world-space rays and points.
/// Pure math, unit tested. Uses the snapshot's camera, never the live camera, so
/// results stay correct after the phone has moved.
enum RayMath {
    // LiDAR sampling.
    static let depthPatchRadius = 3                  // 7 x 7 patch
    static let minimumDepthSamples = 8
    static let minimumDepthConfidence: UInt8 = 1     // ARConfidenceLevel.medium
    /// iPhone LiDAR is rated to about 5 m (was 3 m: objects asked for from farther away fell back to guesses).
    static let depthRangeMeters: ClosedRange<Float> = 0.1...5.0
    /// Closer values belong to the object, farther ones to the table behind it.
    static let depthPercentile: Float = 0.3

    static func ray(through uprightPoint: NormalizedPoint, snapshot: Snapshot) -> Ray {
        let pixel = sensorPixel(for: uprightPoint, snapshot: snapshot)
        let unnormalized = cameraDirection(pixel: pixel, intrinsics: snapshot.intrinsics)
        let directionCamera = simd_normalize(unnormalized)

        let transform = snapshot.cameraTransform
        let rotated = transform * SIMD4<Float>(directionCamera, 0)
        let directionWorld = simd_normalize(SIMD3<Float>(rotated.x, rotated.y, rotated.z))

        return Ray(origin: translation(of: transform), direction: directionWorld)
    }

    static func point(along ray: Ray, distance: Float) -> SIMD3<Float> {
        return ray.origin + ray.direction * distance
    }

    /// Where the ray hits the horizontal plane y = planeY. nil if the ray is parallel
    /// to the plane or the plane is behind the ray's origin.
    static func intersectHorizontalPlane(ray: Ray, planeY: Float) -> SIMD3<Float>? {
        let verticalSpeed = ray.direction.y
        if abs(verticalSpeed) < 1e-6 {
            return nil
        }

        let distance = (planeY - ray.origin.y) / verticalSpeed
        if distance <= 0 {
            return nil
        }
        return point(along: ray, distance: distance)
    }

    /// LiDAR path. Samples depth around the point and unprojects to world space.
    /// Returns nil if too few confident samples or depth outside 0.1...5.0 m.
    static func worldPointFromDepth(uprightPoint: NormalizedPoint, snapshot: Snapshot) -> SIMD3<Float>? {
        guard let depth = snapshot.depth else {
            return nil
        }
        let expectedCount = depth.width * depth.height
        guard expectedCount > 0,
              depth.depthMeters.count == expectedCount,
              depth.confidence.count == expectedCount else {
            return nil
        }

        let sensor = ImageSpace.sensorNormalized(
            fromUpright: uprightPoint,
            rotation: snapshot.uprightRotation
        )

        // The depth map is aligned with capturedImage, just lower resolution.
        let centerX = clamp(Int(sensor.x * Double(depth.width)), 0, depth.width - 1)
        let centerY = clamp(Int(sensor.y * Double(depth.height)), 0, depth.height - 1)

        let samples = validDepthSamples(depth: depth, centerX: centerX, centerY: centerY)
        guard samples.count >= minimumDepthSamples else {
            return nil
        }
        let depthMeters = percentile(samples, depthPercentile)

        // Unproject with the snapshot intrinsics in SENSOR pixels (they match
        // capturedImage, not the depth map). z is exactly -1, so scaling by the
        // depth (distance along the optical axis) gives the camera-space point.
        let pixel = sensorPixel(for: uprightPoint, snapshot: snapshot)
        let directionCamera = cameraDirection(pixel: pixel, intrinsics: snapshot.intrinsics)
        let pointCamera = directionCamera * depthMeters

        let world = snapshot.cameraTransform * SIMD4<Float>(pointCamera, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    // MARK: - Object size

    /// Rough physical height (meters) of the object in `box`, from how tall the box is in
    /// the photo and how far away the object is: pixels * distance / focal length.
    /// Viewed from above it measures the object's footprint instead, which is still the
    /// right order of magnitude for where its middle is.
    static func estimatedObjectHeight(box: NormalizedRect, at worldPoint: SIMD3<Float>, snapshot: Snapshot) -> Float {
        let cameraPosition = SIMD3<Float>(
            snapshot.cameraTransform.columns.3.x,
            snapshot.cameraTransform.columns.3.y,
            snapshot.cameraTransform.columns.3.z
        )
        let distance = simd_distance(cameraPosition, worldPoint)

        // Upright vertical maps to sensor x in portrait (ImageSpace), sensor y otherwise.
        let boxHeight = Float(box.maxY - box.minY)
        let pixels: Float
        let focal: Float
        switch snapshot.uprightRotation {
        case .portrait:
            pixels = boxHeight * Float(snapshot.sensorResolution.width)
            focal = snapshot.intrinsics[0][0]
        case .landscapeRight:
            pixels = boxHeight * Float(snapshot.sensorResolution.height)
            focal = snapshot.intrinsics[1][1]
        }
        guard focal > 0 else {
            return 0
        }
        return pixels * distance / focal
    }

    /// How far to raise a table-level point so the sound sits at the object's middle:
    /// half its estimated height, clamped. Falls back to the fixed lift if unknown.
    static func centerLift(box: NormalizedRect, basePoint: SIMD3<Float>, snapshot: Snapshot) -> Float {
        let height = estimatedObjectHeight(box: box, at: basePoint, snapshot: snapshot)
        guard height.isFinite, height > 0 else {
            return Config.objectCenterLiftMeters
        }
        let half = height / 2
        let clamped = min(max(half, Config.minimumObjectCenterLiftMeters), Config.maximumObjectCenterLiftMeters)
        return clamped
    }

    // MARK: - Helpers

    /// Upright normalized -> sensor normalized -> sensor pixels.
    static func sensorPixel(for uprightPoint: NormalizedPoint, snapshot: Snapshot) -> SIMD2<Float> {
        let sensor = ImageSpace.sensorNormalized(
            fromUpright: uprightPoint,
            rotation: snapshot.uprightRotation
        )
        let px = Float(sensor.x) * Float(snapshot.sensorResolution.width)
        let py = Float(sensor.y) * Float(snapshot.sensorResolution.height)
        return SIMD2<Float>(px, py)
    }

    /// Camera-space direction with z = -1 (NOT normalized).
    /// Image y points down, camera y points up, camera looks down -Z.
    /// simd matrices are column-major: intrinsics[2][0] is column 2, row 0 = cx.
    static func cameraDirection(pixel: SIMD2<Float>, intrinsics: simd_float3x3) -> SIMD3<Float> {
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        let x = (pixel.x - cx) / fx
        let y = -(pixel.y - cy) / fy
        return SIMD3<Float>(x, y, -1)
    }

    static func percentile(_ values: [Float], _ fraction: Float) -> Float {
        let sorted = values.sorted()
        let position = Float(sorted.count - 1) * fraction
        let index = Int(position.rounded(.down))
        return sorted[index]
    }

    private static func validDepthSamples(depth: DepthSnapshot, centerX: Int, centerY: Int) -> [Float] {
        var samples: [Float] = []
        for dy in -depthPatchRadius...depthPatchRadius {
            for dx in -depthPatchRadius...depthPatchRadius {
                let x = centerX + dx
                let y = centerY + dy
                if x < 0 || y < 0 || x >= depth.width || y >= depth.height {
                    continue
                }

                let index = y * depth.width + x
                if depth.confidence[index] < minimumDepthConfidence {
                    continue
                }
                let value = depth.depthMeters[index]
                if !depthRangeMeters.contains(value) {
                    continue
                }
                samples.append(value)
            }
        }
        return samples
    }

    private static func translation(of transform: simd_float4x4) -> SIMD3<Float> {
        let column = transform.columns.3
        return SIMD3<Float>(column.x, column.y, column.z)
    }

    private static func clamp(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        return min(max(value, lower), upper)
    }
}
