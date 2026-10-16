import XCTest
@testable import Faith

/// Locks the upright -> sensor mapping.
/// If the device corner test proves another candidate right, change ImageSpace
/// AND these expectations together.
final class ImageSpaceTests: XCTestCase {
    private func assertPoint(
        _ actual: NormalizedPoint,
        _ x: Double,
        _ y: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.y, y, accuracy: 1e-9, file: file, line: line)
    }

    private func portrait(_ x: Double, _ y: Double) -> NormalizedPoint {
        ImageSpace.sensorNormalized(fromUpright: NormalizedPoint(x: x, y: y), rotation: .portrait)
    }

    func testPortraitTopLeft() {
        assertPoint(portrait(0, 0), 0, 1)
    }

    func testPortraitTopRight() {
        assertPoint(portrait(1, 0), 0, 0)
    }

    func testPortraitBottomLeft() {
        assertPoint(portrait(0, 1), 1, 1)
    }

    func testPortraitBottomRight() {
        assertPoint(portrait(1, 1), 1, 0)
    }

    func testPortraitCenterStaysCenter() {
        assertPoint(portrait(0.5, 0.5), 0.5, 0.5)
    }

    func testLandscapeRightIsIdentity() {
        let point = NormalizedPoint(x: 0.2, y: 0.7)
        let sensor = ImageSpace.sensorNormalized(fromUpright: point, rotation: .landscapeRight)
        assertPoint(sensor, 0.2, 0.7)
    }
}
