import XCTest
import simd
@testable import Faith

final class CueModulatorTests: XCTestCase {
    private let listener = ListenerPose(
        position: SIMD3<Float>(0, 0, 0),
        forward: SIMD3<Float>(0, 0, -1),
        up: SIMD3<Float>(0, 1, 0)
    )

    private func target(at position: SIMD3<Float>) -> AnchoredTarget {
        AnchoredTarget(
            id: UUID(),
            label: "test",
            worldPosition: position,
            placement: .manualTap,
            createdAt: Date()
        )
    }

    /// A point 1 m away at `degrees` to the right of straight ahead.
    private func position(atDegreesRight degrees: Float) -> SIMD3<Float> {
        let radians = degrees * Float.pi / 180
        return SIMD3<Float>(sin(radians), 0, -cos(radians))
    }

    func testFacingTheTargetPulsesFastestAndIsOnTarget() {
        let cue = CueModulator.parameters(listener: listener, target: target(at: SIMD3<Float>(0, 0, -1)))

        XCTAssertEqual(cue.intervalSeconds, 0.15, accuracy: 1e-6)
        XCTAssertTrue(cue.isOnTarget)
        XCTAssertEqual(cue.gain, 0.9, accuracy: 1e-6)
    }

    func testTargetAt90DegreesPulsesSlowest() {
        let cue = CueModulator.parameters(listener: listener, target: target(at: SIMD3<Float>(1, 0, 0)))

        XCTAssertEqual(cue.intervalSeconds, 0.70, accuracy: 1e-4)
        XCTAssertFalse(cue.isOnTarget)
    }

    func testTargetBehindIsClampedToSlowest() {
        let cue = CueModulator.parameters(listener: listener, target: target(at: SIMD3<Float>(0, 0, 1)))

        XCTAssertEqual(cue.intervalSeconds, 0.70, accuracy: 1e-4)
        XCTAssertFalse(cue.isOnTarget)
    }

    func testHalfwayIsHalfwayBetweenFastestAndSlowest() {
        let cue = CueModulator.parameters(listener: listener, target: target(at: position(atDegreesRight: 45)))

        XCTAssertEqual(cue.intervalSeconds, 0.425, accuracy: 1e-4)
    }

    func testLeftAndRightAreSymmetric() {
        let right = CueModulator.parameters(listener: listener, target: target(at: position(atDegreesRight: 30)))
        let left = CueModulator.parameters(listener: listener, target: target(at: position(atDegreesRight: -30)))

        XCTAssertEqual(right.intervalSeconds, left.intervalSeconds, accuracy: 1e-4)
    }

    func testOnTargetUsesTheConfigThreshold() {
        let inside = Config.onTargetThresholdDegrees - 1
        let outside = Config.onTargetThresholdDegrees + 1

        let insideCue = CueModulator.parameters(listener: listener, target: target(at: position(atDegreesRight: inside)))
        let outsideCue = CueModulator.parameters(listener: listener, target: target(at: position(atDegreesRight: -outside)))

        XCTAssertTrue(insideCue.isOnTarget)
        XCTAssertFalse(outsideCue.isOnTarget)
    }

    func testHeightDifferenceDoesNotChangeThePulse() {
        let level = CueModulator.parameters(listener: listener, target: target(at: SIMD3<Float>(0.3, 0, -0.5)))
        let below = CueModulator.parameters(listener: listener, target: target(at: SIMD3<Float>(0.3, -0.4, -0.5)))

        XCTAssertEqual(level.intervalSeconds, below.intervalSeconds, accuracy: 1e-6)
    }

    func testTurningTheHeadTowardTheTargetSpeedsUpThePulse() {
        let body = BodyPose(position: SIMD3<Float>(0, 0, 0), forward: SIMD3<Float>(0, 0, -1))
        let rig = ListenerRig.chestMount(upOffsetMeters: 0)
        let leftTarget = target(at: SIMD3<Float>(-1, 0, 0))

        let facingForward = ListenerPoseMath.compose(body: body, head: .identity, rig: rig)
        let turnedLeft = ListenerPoseMath.compose(
            body: body,
            head: HeadRotation(yawRadians: Float.pi / 2, pitchRadians: 0),
            rig: rig
        )

        let before = CueModulator.parameters(listener: facingForward, target: leftTarget)
        let after = CueModulator.parameters(listener: turnedLeft, target: leftTarget)

        XCTAssertEqual(before.intervalSeconds, 0.70, accuracy: 1e-4)
        XCTAssertEqual(after.intervalSeconds, 0.15, accuracy: 1e-4)
        XCTAssertTrue(after.isOnTarget)
    }
}
