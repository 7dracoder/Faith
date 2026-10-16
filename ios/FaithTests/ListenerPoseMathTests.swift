import XCTest
import simd
@testable import Faith

final class ListenerPoseMathTests: XCTestCase {
    private let accuracy: Float = 1e-5
    private let body = BodyPose(
        position: SIMD3<Float>(1, 2, 3),
        forward: SIMD3<Float>(0, 0, -1)
    )
    private let noOffsetRig = ListenerRig.chestMount(upOffsetMeters: 0)

    private func radians(_ degrees: Float) -> Float {
        degrees * Float.pi / 180
    }

    private func assertEqual(
        _ actual: SIMD3<Float>,
        _ expected: SIMD3<Float>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    func testIdentityHeadReturnsBodyForwardAndWorldUp() {
        let pose = ListenerPoseMath.compose(body: body, head: .identity, rig: noOffsetRig)

        assertEqual(pose.forward, SIMD3<Float>(0, 0, -1))
        assertEqual(pose.up, SIMD3<Float>(0, 1, 0))
    }

    func testYawPlus90TurnsLeft() {
        let head = HeadRotation(yawRadians: radians(90), pitchRadians: 0)
        let pose = ListenerPoseMath.compose(body: body, head: head, rig: noOffsetRig)

        assertEqual(pose.forward, SIMD3<Float>(-1, 0, 0))
        assertEqual(pose.up, SIMD3<Float>(0, 1, 0))
    }

    func testYawMinus90TurnsRight() {
        let head = HeadRotation(yawRadians: radians(-90), pitchRadians: 0)
        let pose = ListenerPoseMath.compose(body: body, head: head, rig: noOffsetRig)

        assertEqual(pose.forward, SIMD3<Float>(1, 0, 0))
    }

    func testPitchPlus30LooksUp() {
        let head = HeadRotation(yawRadians: 0, pitchRadians: radians(30))
        let pose = ListenerPoseMath.compose(body: body, head: head, rig: noOffsetRig)

        XCTAssertEqual(pose.forward.y, 0.5, accuracy: accuracy)
        XCTAssertLessThan(pose.forward.z, 0)
        XCTAssertEqual(pose.forward.x, 0, accuracy: accuracy)
        // Looking up tips the top of the head backward (+Z).
        XCTAssertGreaterThan(pose.up.z, 0)
    }

    func testForwardAndUpStayUnitAndPerpendicular() {
        let head = HeadRotation(yawRadians: radians(40), pitchRadians: radians(-25))
        let pose = ListenerPoseMath.compose(body: body, head: head, rig: noOffsetRig)

        XCTAssertEqual(simd_length(pose.forward), 1, accuracy: accuracy)
        XCTAssertEqual(simd_length(pose.up), 1, accuracy: accuracy)
        XCTAssertEqual(simd_dot(pose.forward, pose.up), 0, accuracy: accuracy)
    }

    func testYawIsRelativeToBodyForward() {
        // Phone faces +X. Head turned 90 degrees left of that faces -Z.
        let sidewaysBody = BodyPose(
            position: SIMD3<Float>(0, 0, 0),
            forward: SIMD3<Float>(1, 0, 0)
        )
        let head = HeadRotation(yawRadians: radians(90), pitchRadians: 0)
        let pose = ListenerPoseMath.compose(body: sidewaysBody, head: head, rig: noOffsetRig)

        assertEqual(pose.forward, SIMD3<Float>(0, 0, -1))
    }

    func testStandInFrontPutsEarsBehindAndAboveThePhone() {
        let rig = ListenerRig.standInFront(backOffsetMeters: 0.35, upOffsetMeters: 0.30)
        let pose = ListenerPoseMath.compose(body: body, head: .identity, rig: rig)

        // Body forward is -Z, so "back" is +Z.
        assertEqual(pose.position, SIMD3<Float>(1, 2.30, 3.35))
    }

    func testChestMountPutsEarsAboveThePhone() {
        let rig = ListenerRig.chestMount(upOffsetMeters: 0.25)
        let pose = ListenerPoseMath.compose(body: body, head: .identity, rig: rig)

        assertEqual(pose.position, SIMD3<Float>(1, 2.25, 3))
    }

    func testHeadRotationDoesNotMoveTheEars() {
        let rig = ListenerRig.standInFront(backOffsetMeters: 0.35, upOffsetMeters: 0.30)
        let head = HeadRotation(yawRadians: radians(70), pitchRadians: radians(20))

        let turned = ListenerPoseMath.compose(body: body, head: head, rig: rig)
        let straight = ListenerPoseMath.compose(body: body, head: .identity, rig: rig)

        assertEqual(turned.position, straight.position)
    }

    func testDegenerateBodyForwardFallsBackInsteadOfNaN() {
        let brokenBody = BodyPose(
            position: SIMD3<Float>(0, 0, 0),
            forward: SIMD3<Float>(0, 0, 0)
        )
        let pose = ListenerPoseMath.compose(body: brokenBody, head: .identity, rig: noOffsetRig)

        assertEqual(pose.forward, SIMD3<Float>(0, 0, -1))
        assertEqual(pose.up, SIMD3<Float>(0, 1, 0))
    }
}
