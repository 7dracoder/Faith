import XCTest
import simd
@testable import Faith

final class RayMathTests: XCTestCase {
    // Plausible iPhone wide camera: 1920 x 1440 sensor, principal point at the center.
    private let intrinsics = simd_float3x3(
        SIMD3<Float>(1500, 0, 0),
        SIMD3<Float>(0, 1500, 0),
        SIMD3<Float>(960, 720, 1)
    )

    private func makeSnapshot(
        transform: simd_float4x4 = matrix_identity_float4x4,
        rotation: UprightRotation = .portrait,
        depth: DepthSnapshot? = nil
    ) -> Snapshot {
        Snapshot(
            id: UUID(),
            capturedAt: Date(),
            uprightJPEG: Data(),
            cameraTransform: transform,
            intrinsics: intrinsics,
            sensorResolution: CGSize(width: 1920, height: 1440),
            uprightRotation: rotation,
            depth: depth
        )
    }

    private func assertVector(
        _ actual: SIMD3<Float>?,
        _ expected: SIMD3<Float>,
        accuracy: Float = 1e-4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("expected a point, got nil", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Rays

    func testCenterPixelLooksStraightDownMinusZ() {
        let ray = RayMath.ray(through: NormalizedPoint(x: 0.5, y: 0.5), snapshot: makeSnapshot())
        assertVector(ray.origin, SIMD3<Float>(0, 0, 0))
        assertVector(ray.direction, SIMD3<Float>(0, 0, -1))
    }

    func testSensorPixelRightOfCenterPointsPlusX() {
        let snapshot = makeSnapshot(rotation: .landscapeRight)
        let ray = RayMath.ray(through: NormalizedPoint(x: 0.75, y: 0.5), snapshot: snapshot)
        XCTAssertGreaterThan(ray.direction.x, 0)
        XCTAssertEqual(ray.direction.y, 0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(ray.direction), 1, accuracy: 1e-5)
    }

    func testSensorPixelAboveCenterPointsPlusY() {
        let snapshot = makeSnapshot(rotation: .landscapeRight)
        let ray = RayMath.ray(through: NormalizedPoint(x: 0.5, y: 0.25), snapshot: snapshot)
        XCTAssertGreaterThan(ray.direction.y, 0)
        XCTAssertEqual(ray.direction.x, 0, accuracy: 1e-5)
    }

    /// Portrait: upright-right is sensor-up, i.e. camera +Y. On device the
    /// ARCamera transform turns camera +Y into the phone's right side.
    func testPortraitUprightRightIsCameraPlusY() {
        let ray = RayMath.ray(through: NormalizedPoint(x: 0.75, y: 0.5), snapshot: makeSnapshot())
        XCTAssertGreaterThan(ray.direction.y, 0)
        XCTAssertEqual(ray.direction.x, 0, accuracy: 1e-5)
    }

    func testRayUsesSnapshotCameraPose() {
        // Camera at (1, 2, 3), turned 90 degrees left: its -Z forward is world -X.
        var transform = simd_float4x4(simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(0, 1, 0)))
        transform.columns.3 = SIMD4<Float>(1, 2, 3, 1)

        let ray = RayMath.ray(through: NormalizedPoint(x: 0.5, y: 0.5), snapshot: makeSnapshot(transform: transform))

        assertVector(ray.origin, SIMD3<Float>(1, 2, 3))
        assertVector(ray.direction, SIMD3<Float>(-1, 0, 0))
    }

    func testPointAlongRay() {
        let ray = Ray(origin: SIMD3<Float>(0, 1, 0), direction: SIMD3<Float>(0, 0, -1))
        assertVector(RayMath.point(along: ray, distance: 0.6), SIMD3<Float>(0, 1, -0.6))
    }

    // MARK: - Plane intersection

    func testPlaneIntersectionAtKnownHeights() {
        let down45 = simd_normalize(SIMD3<Float>(0, -1, -1))
        let ray = Ray(origin: SIMD3<Float>(0, 1, 0), direction: down45)

        assertVector(RayMath.intersectHorizontalPlane(ray: ray, planeY: 0), SIMD3<Float>(0, 0, -1))
        assertVector(RayMath.intersectHorizontalPlane(ray: ray, planeY: 0.5), SIMD3<Float>(0, 0.5, -0.5))
    }

    func testRayParallelToPlaneIsNil() {
        let ray = Ray(origin: SIMD3<Float>(0, 1, 0), direction: SIMD3<Float>(0, 0, -1))
        XCTAssertNil(RayMath.intersectHorizontalPlane(ray: ray, planeY: 0))
    }

    func testPlaneBehindRayIsNil() {
        let up = simd_normalize(SIMD3<Float>(0, 1, -1))
        let ray = Ray(origin: SIMD3<Float>(0, 1, 0), direction: up)
        XCTAssertNil(RayMath.intersectHorizontalPlane(ray: ray, planeY: 0))
    }

    // MARK: - LiDAR depth

    private let depthWidth = 256
    private let depthHeight = 192

    /// Background at `backgroundMeters`; the rectangle [minX...maxX] x [minY...maxY]
    /// (depth pixels) at `objectMeters`.
    private func makeDepth(
        backgroundMeters: Float = 0.8,
        objectMeters: Float = 0.5,
        objectX: ClosedRange<Int> = 120...136,
        objectY: ClosedRange<Int> = 88...104,
        confidence: UInt8 = 2
    ) -> DepthSnapshot {
        var depth: [Float] = []
        for y in 0..<depthHeight {
            for x in 0..<depthWidth {
                let isObject = objectX.contains(x) && objectY.contains(y)
                depth.append(isObject ? objectMeters : backgroundMeters)
            }
        }
        let confidences = [UInt8](repeating: confidence, count: depthWidth * depthHeight)
        return DepthSnapshot(width: depthWidth, height: depthHeight, depthMeters: depth, confidence: confidences)
    }

    func testDepthObjectAtHalfMeter() {
        let snapshot = makeSnapshot(depth: makeDepth())
        let point = RayMath.worldPointFromDepth(uprightPoint: NormalizedPoint(x: 0.5, y: 0.5), snapshot: snapshot)
        assertVector(point, SIMD3<Float>(0, 0, -0.5))
    }

    /// Thin object covering only 3 of the 7 patch columns (43% of samples).
    /// The median would snap to the 0.8 m table behind it; the 30th percentile keeps it.
    func testThinObjectDoesNotSnapToTableBehind() {
        let depth = makeDepth(objectX: 129...131, objectY: 0...191)
        let snapshot = makeSnapshot(depth: depth)
        let point = RayMath.worldPointFromDepth(uprightPoint: NormalizedPoint(x: 0.5, y: 0.5), snapshot: snapshot)
        XCTAssertEqual(point?.z ?? 0, -0.5, accuracy: 1e-4)
    }

    func testDepthAllLowConfidenceIsNil() {
        let snapshot = makeSnapshot(depth: makeDepth(confidence: 0))
        XCTAssertNil(RayMath.worldPointFromDepth(uprightPoint: NormalizedPoint(x: 0.5, y: 0.5), snapshot: snapshot))
    }

    func testDepthOutOfRangeIsNil() {
        let tooFar = makeDepth(backgroundMeters: 7, objectMeters: 6)
        let snapshot = makeSnapshot(depth: tooFar)
        XCTAssertNil(RayMath.worldPointFromDepth(uprightPoint: NormalizedPoint(x: 0.5, y: 0.5), snapshot: snapshot))
    }

    /// Asked for from ~4 m away: LiDAR now measures it instead of falling back to a guess.
    func testDepthWorksOutToFourMeters() {
        let snapshot = makeSnapshot(depth: makeDepth(backgroundMeters: 4.5, objectMeters: 4.0))
        let point = RayMath.worldPointFromDepth(uprightPoint: NormalizedPoint(x: 0.5, y: 0.5), snapshot: snapshot)
        XCTAssertEqual(point?.z ?? 0, -4.0, accuracy: 1e-4)
    }

    func testNoDepthIsNil() {
        XCTAssertNil(RayMath.worldPointFromDepth(uprightPoint: NormalizedPoint(x: 0.5, y: 0.5), snapshot: makeSnapshot()))
    }

    /// Unprojection uses SENSOR pixels and the snapshot pose.
    func testDepthOffCenterUsesSensorPixelsAndPose() {
        let uniform = makeDepth(backgroundMeters: 1.0, objectMeters: 1.0)
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(0, 1, 0, 1)
        let snapshot = makeSnapshot(transform: transform, rotation: .landscapeRight, depth: uniform)

        // Sensor x = 0.75 -> px = 1440 -> (1440 - 960) / 1500 = 0.32 at 1 m.
        let point = RayMath.worldPointFromDepth(uprightPoint: NormalizedPoint(x: 0.75, y: 0.5), snapshot: snapshot)
        assertVector(point, SIMD3<Float>(0.32, 1, -1))
    }

    func testPercentile() {
        let values: [Float] = [0.9, 0.1, 0.5, 0.3, 0.7]
        XCTAssertEqual(RayMath.percentile(values, 0.0), 0.1)
        XCTAssertEqual(RayMath.percentile(values, 0.5), 0.5)
        XCTAssertEqual(RayMath.percentile(values, 1.0), 0.9)
    }
}

// MARK: - Size-aware lift

final class CenterLiftTests: XCTestCase {
    // fx = fy = 1500 px, 1920 x 1440 sensor, camera at the origin.
    private func makeSnapshot() -> Snapshot {
        Snapshot(
            id: UUID(),
            capturedAt: Date(),
            uprightJPEG: Data(),
            cameraTransform: matrix_identity_float4x4,
            intrinsics: simd_float3x3(
                SIMD3<Float>(1500, 0, 0),
                SIMD3<Float>(0, 1500, 0),
                SIMD3<Float>(960, 720, 1)
            ),
            sensorResolution: CGSize(width: 1920, height: 1440),
            uprightRotation: .portrait,
            depth: nil
        )
    }

    private func box(height: Double) -> NormalizedRect {
        NormalizedRect(minX: 0.45, minY: 0.5 - height / 2, maxX: 0.55, maxY: 0.5 + height / 2)
    }

    private let oneMeterAway = SIMD3<Float>(0, 0, -1)

    func testEstimatedHeightFromBoxAndDistance() {
        // 0.1 of the upright height = 192 sensor px; at 1 m: 192 / 1500 = 0.128 m.
        let height = RayMath.estimatedObjectHeight(box: box(height: 0.1), at: oneMeterAway, snapshot: makeSnapshot())
        XCTAssertEqual(height, 0.128, accuracy: 1e-4)
    }

    func testMugSizedObjectLiftsAboutHalfItsHeight() {
        // ~0.078 of the image at 1 m is ~10 cm tall -> ~5 cm lift.
        let lift = RayMath.centerLift(box: box(height: 0.078), basePoint: oneMeterAway, snapshot: makeSnapshot())
        XCTAssertEqual(lift, 0.05, accuracy: 0.003)
    }

    func testFlatPenGetsATinyLift() {
        let lift = RayMath.centerLift(box: box(height: 0.01), basePoint: oneMeterAway, snapshot: makeSnapshot())
        XCTAssertLessThan(lift, 0.01)
        XCTAssertGreaterThanOrEqual(lift, Config.minimumObjectCenterLiftMeters)
    }

    func testTallObjectIsCapped() {
        let lift = RayMath.centerLift(box: box(height: 0.6), basePoint: oneMeterAway, snapshot: makeSnapshot())
        XCTAssertEqual(lift, Config.maximumObjectCenterLiftMeters, accuracy: 1e-6)
    }

    func testSameBoxFartherAwayIsBigger() {
        let near = RayMath.estimatedObjectHeight(box: box(height: 0.05), at: SIMD3<Float>(0, 0, -0.5), snapshot: makeSnapshot())
        let far = RayMath.estimatedObjectHeight(box: box(height: 0.05), at: SIMD3<Float>(0, 0, -1.0), snapshot: makeSnapshot())
        XCTAssertEqual(far, near * 2, accuracy: 1e-4)
    }
}
