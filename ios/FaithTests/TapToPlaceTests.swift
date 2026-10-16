import XCTest
import ARKit
import simd
@testable import Faith

final class TapToPlaceTests: XCTestCase {
    private let previousForward = SIMD3<Float>(0, 0, -1)

    // MARK: - Body pose

    func testBodyPoseFromIdentityCamera() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(0.1, 1.2, -0.3, 1)

        let pose = ARSessionController.bodyPose(
            fromCameraTransform: transform,
            previousForward: previousForward
        )

        XCTAssertEqual(pose.position.x, 0.1, accuracy: 1e-5)
        XCTAssertEqual(pose.position.y, 1.2, accuracy: 1e-5)
        XCTAssertEqual(pose.position.z, -0.3, accuracy: 1e-5)
        XCTAssertEqual(pose.forward.z, -1, accuracy: 1e-5)
    }

    func testBodyPoseYawedLeftFacesMinusX() {
        // +90 degrees about +Y turns the camera's -Z forward to -X (left).
        let rotation = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let transform = simd_float4x4(rotation)

        let pose = ARSessionController.bodyPose(
            fromCameraTransform: transform,
            previousForward: previousForward
        )

        XCTAssertEqual(pose.forward.x, -1, accuracy: 1e-5)
        XCTAssertEqual(pose.forward.y, 0, accuracy: 1e-5)
        XCTAssertEqual(pose.forward.z, 0, accuracy: 1e-5)
    }

    func testBodyPoseKeepsPreviousForwardWhenPointingDown() {
        let rotation = simd_quatf(angle: -Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let transform = simd_float4x4(rotation)
        let previous = SIMD3<Float>(1, 0, 0)

        let pose = ARSessionController.bodyPose(
            fromCameraTransform: transform,
            previousForward: previous
        )

        XCTAssertEqual(pose.forward, previous)
    }

    // MARK: - Tracking summary

    func testTrackingSummaryMapping() {
        XCTAssertEqual(ARSessionController.summary(from: .normal), .normal)
        XCTAssertEqual(ARSessionController.summary(from: .limited(.initializing)), .initializing)
        XCTAssertEqual(
            ARSessionController.summary(from: .limited(.excessiveMotion)),
            .limited("Moving too fast")
        )
        XCTAssertEqual(
            ARSessionController.summary(from: .notAvailable),
            .limited("Not available")
        )
    }

    // MARK: - Per-person real services

    func testApplyingRealServicesFlipsOnlyNamedFlags() {
        let flags = ServiceFlags.allMocks.applyingRealServices("perception, Audio")

        XCTAssertFalse(flags.mockPerception)
        XCTAssertFalse(flags.mockAudio)
        XCTAssertTrue(flags.mockLocator)
        XCTAssertTrue(flags.mockHeadTracking)
        XCTAssertTrue(flags.mockVoice)
        XCTAssertTrue(flags.mockTelemetry)
    }

    func testEmptyRealServicesKeepsAllMocks() {
        let flags = ServiceFlags.allMocks.applyingRealServices("")
        XCTAssertTrue(flags.mockPerception)
        XCTAssertTrue(flags.mockAudio)
    }
}
