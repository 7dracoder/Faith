import XCTest
@testable import Faith

final class HeadRotationMathTests: XCTestCase {
    private let accuracy: Float = 1e-5

    func testZeroIsIdentity() {
        let rotation = HeadRotationMath.headRotation(rawYawRadians: 0, rawPitchRadians: 0)

        XCTAssertEqual(rotation, HeadRotation.identity)
    }

    func testYawAndPitchPassThroughWithTheConfiguredSigns() {
        let rotation = HeadRotationMath.headRotation(rawYawRadians: 0.79, rawPitchRadians: 0.3)

        XCTAssertEqual(rotation.yawRadians, HeadRotationMath.yawSign * 0.79, accuracy: accuracy)
        XCTAssertEqual(rotation.pitchRadians, HeadRotationMath.pitchSign * 0.3, accuracy: accuracy)
    }

    func testPitchIsClampedToSixtyDegrees() {
        let limit = 60 * Float.pi / 180

        let up = HeadRotationMath.headRotation(rawYawRadians: 0, rawPitchRadians: 1.5)
        let down = HeadRotationMath.headRotation(rawYawRadians: 0, rawPitchRadians: -1.5)

        XCTAssertEqual(abs(up.pitchRadians), limit, accuracy: accuracy)
        XCTAssertEqual(abs(down.pitchRadians), limit, accuracy: accuracy)
        XCTAssertEqual(up.pitchRadians, -down.pitchRadians, accuracy: accuracy)
    }

    func testYawIsNotClamped() {
        let rotation = HeadRotationMath.headRotation(rawYawRadians: 3.0, rawPitchRadians: 0)

        XCTAssertEqual(abs(rotation.yawRadians), 3.0, accuracy: accuracy)
    }
}
