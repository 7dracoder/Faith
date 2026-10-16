import XCTest
import simd
@testable import Faith

final class GeometryTests: XCTestCase {
    private let origin = SIMD3<Float>(0, 0, 0)
    private let forward = SIMD3<Float>(0, 0, -1)

    func testStraightAheadIsZero() {
        let angle = Geometry.signedHorizontalAngleDegrees(
            from: origin,
            forward: forward,
            to: SIMD3<Float>(0, 0, -1)
        )
        XCTAssertEqual(angle, 0, accuracy: 0.001)
    }

    func testRightIsPositive() {
        let angle = Geometry.signedHorizontalAngleDegrees(
            from: origin,
            forward: forward,
            to: SIMD3<Float>(1, 0, 0)
        )
        XCTAssertEqual(angle, 90, accuracy: 0.001)
    }

    func testLeftIsNegative() {
        let angle = Geometry.signedHorizontalAngleDegrees(
            from: origin,
            forward: forward,
            to: SIMD3<Float>(-1, 0, 0)
        )
        XCTAssertEqual(angle, -90, accuracy: 0.001)
    }

    func testBehindIsAbout180() {
        let angle = Geometry.signedHorizontalAngleDegrees(
            from: origin,
            forward: forward,
            to: SIMD3<Float>(0.001, 0, 1)
        )
        XCTAssertEqual(abs(angle), 180, accuracy: 0.5)
    }

    func testAngleIgnoresHeight() {
        let angle = Geometry.signedHorizontalAngleDegrees(
            from: origin,
            forward: forward,
            to: SIMD3<Float>(1, -5, -1)
        )
        XCTAssertEqual(angle, 45, accuracy: 0.001)
    }

    func testHorizontalDistanceIgnoresY() {
        let a = SIMD3<Float>(0, 0, 0)
        let b = SIMD3<Float>(3, 10, -4)
        XCTAssertEqual(Geometry.horizontalDistance(a, b), 5, accuracy: 0.0001)
    }

    func testHorizontalForwardFromIdentityCamera() {
        let maybeForward = Geometry.horizontalForward(fromCameraTransform: matrix_identity_float4x4)
        let result = try? XCTUnwrap(maybeForward)
        XCTAssertEqual(result?.x ?? 99, 0, accuracy: 0.0001)
        XCTAssertEqual(result?.y ?? 99, 0, accuracy: 0.0001)
        XCTAssertEqual(result?.z ?? 99, -1, accuracy: 0.0001)
    }

    func testHorizontalForwardIsNilWhenPointingStraightDown() {
        // Rotate the camera -90 degrees about X so its -Z axis points down (-Y).
        let rotation = simd_quatf(angle: -Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let transform = simd_float4x4(rotation)
        XCTAssertNil(Geometry.horizontalForward(fromCameraTransform: transform))
    }
}
